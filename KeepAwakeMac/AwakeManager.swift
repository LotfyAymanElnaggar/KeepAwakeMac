import Foundation
import CoreGraphics
import IOKit
import IOKit.pwr_mgt
import Darwin

private struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { status == 0 }
}

private enum ShellRunner {
    static func run(_ executable: String, _ arguments: [String]) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let error = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = error
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: ShellResult(status: process.terminationStatus, stdout: stdout, stderr: stderr))
                } catch {
                    continuation.resume(returning: ShellResult(status: -1, stdout: "", stderr: error.localizedDescription))
                }
            }
        }
    }

    static func runAdministratorCommand(_ command: String) async -> ShellResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return await run("/usr/bin/osascript", ["-e", script])
    }
}

private typealias DSGetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
private let kPMSetClamshellSleepStateSelector: UInt32 = 12

@MainActor
final class AwakeManager: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var endDate: Date?
    @Published private(set) var remainingSeconds: TimeInterval?
    @Published var allowDisplaySleep = true
    @Published var lowBatteryCutoff = 15
    @Published var lastError: String?

    @Published private(set) var lidAuthorizationInstalled = false
    @Published private(set) var lidClosedModeEnabled = false
    @Published private(set) var lidChanging = false
    @Published private(set) var sleepDisabledReadback = false
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var onBatteryPower = false
    @Published private(set) var lidStatusMessage: String?
    @Published private(set) var sudoConfigurationWarning: String?

    @Published private(set) var lidIsClosed = false
    @Published private(set) var hasExternalDisplay = false
    @Published private(set) var displaySleepStatus: String?

    // v1.3 kernel-level clamshell guard + backlight state.
    @Published private(set) var kernelLidGuardActive = false
    @Published private(set) var appleClamshellCausesSleep: Bool?
    @Published private(set) var kernelSelectorStatus: String = "not armed"
    @Published private(set) var backlightDimmed = false
    @Published private(set) var savedBacklightBrightness: Float?
    @Published private(set) var lastSleepVetoAt: Date?
    @Published private(set) var lastSystemWakeAt: Date?

    private let ownershipKey = "KeepAwakeMac.ownsSleepDisabled"
    private let sudoersPath = "/etc/sudoers.d/keepawakemac"

    private var pmsetPrivilegeAvailable = false
    private var ownsSleepDisabled = false
    private var prepared = false

    private var systemAssertionID: IOPMAssertionID = 0
    private var idleSystemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var activityToken: NSObjectProtocol?
    private let systemPowerVeto = SystemPowerVeto()

    private var endTimer: Timer?
    private var ticker: Timer?
    private var safetyTimer: Timer?
    private var lidMonitorTimer: Timer?
    private var kernelHeartbeatTimer: Timer?

    private var rootDomainService: io_service_t = 0
    private var rootDomainConnection: io_connect_t = 0
    private var lastKernelSelectorResult: IOReturn = kIOReturnSuccess

    private var displayServicesHandle: UnsafeMutableRawPointer?
    private var dsGetBrightness: DSGetBrightnessFn?
    private var dsSetBrightness: DSSetBrightnessFn?
    private var builtinDisplayID: CGDirectDisplayID?

    private var watchdogTokenPath: String?
    private var watchdogBrightnessPath: String?
    private var watchdogProcess: Process?

    private var wakeObserver: NSObjectProtocol?
    private var vetoObserver: NSObjectProtocol?

    func prepareOnLaunch() async {
        guard !prepared else { return }
        prepared = true

        loadDisplayServices()
        findBuiltinDisplay()
        refreshRootDomainState()
        refreshLidAndDisplayState(forceBacklightAction: false)
        installPowerNotifications()

        await refreshLidAuthorizationStatus()
        await refreshSleepDisabledState()
        await refreshBatteryState()

        // Recover only state that KeepAwakeMac previously marked as its own.
        // Do not disturb another utility's global pmset state.
        if UserDefaults.standard.bool(forKey: ownershipKey) {
            _ = setKernelClamshellSleepDisabled(false)
            if sleepDisabledReadback, pmsetPrivilegeAvailable {
                if await setGlobalSleepDisabled(false) {
                    UserDefaults.standard.set(false, forKey: ownershipKey)
                    lidStatusMessage = "Recovered normal sleep after an interrupted previous session."
                } else {
                    lastError = "A previous session may still have SleepDisabled enabled. Run: sudo pmset -a disablesleep 0"
                }
            } else if !sleepDisabledReadback {
                UserDefaults.standard.set(false, forKey: ownershipKey)
            }
        }
    }

    func start(duration: TimeInterval?) {
        stopCore(clearError: false, disarmLid: false)
        lastError = nil

        guard acquirePowerAssertions() else { return }

        let reason = "KeepAwakeMac session enabled by user"
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if !allowDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
        activityToken = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        systemPowerVeto.setEnabled(true)
        isActive = true

        if let duration {
            let safeDuration = max(1, duration)
            endDate = Date().addingTimeInterval(safeDuration)
            remainingSeconds = safeDuration

            endTimer = Timer.scheduledTimer(withTimeInterval: safeDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in await self?.stopAndRestoreSleep() }
            }
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let endDate = self.endDate else { return }
                    self.remainingSeconds = max(0, endDate.timeIntervalSinceNow)
                }
            }
        } else {
            endDate = nil
            remainingSeconds = nil
        }

        if lidClosedModeEnabled {
            _ = setKernelClamshellSleepDisabled(true)
            startLidMonitor()
            startKernelHeartbeat()
            refreshLidAndDisplayState(forceBacklightAction: true)
        }

        startSafetyTimer()
    }

    func restartForDisplayPreferenceChange(duration: TimeInterval?) {
        guard isActive else { return }
        let remaining = endDate.map { max(1, $0.timeIntervalSinceNow) } ?? duration
        start(duration: remaining)
        refreshLidAndDisplayState(forceBacklightAction: true)
    }

    func stop() {
        stopCore(clearError: true, disarmLid: true)
    }

    func stopAndRestoreSleep() async {
        let shouldDisarm = lidClosedModeEnabled || kernelLidGuardActive || ownsSleepDisabled || UserDefaults.standard.bool(forKey: ownershipKey)
        stopCore(clearError: true, disarmLid: false)
        if shouldDisarm { await disableLidClosedModeIfOwned() }
    }

    // MARK: - Authorization

    func installLidAuthorization() async {
        guard !lidChanging else { return }
        lidChanging = true
        defer { lidChanging = false }
        lastError = nil
        lidStatusMessage = nil

        let username = NSUserName()
        guard username.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            lastError = "Your macOS username contains characters this installer does not support."
            return
        }

        let rule = "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        let safeRule = rule.replacingOccurrences(of: "'", with: "'\\''")
        let tempPath = "/tmp/keepawakemac.sudoers.\(getpid())"
        let command = "umask 077; printf '%s\\n' '\(safeRule)' > '\(tempPath)' && /usr/sbin/visudo -cf '\(tempPath)' && /usr/sbin/chown root:wheel '\(tempPath)' && /bin/chmod 0440 '\(tempPath)' && /bin/mkdir -p /etc/sudoers.d && /bin/mv '\(tempPath)' '\(sudoersPath)' && /usr/sbin/visudo -cf '\(sudoersPath)'"

        let result = await ShellRunner.runAdministratorCommand(command)
        await refreshLidAuthorizationStatus()

        if result.succeeded && lidAuthorizationInstalled && pmsetPrivilegeAvailable {
            lidStatusMessage = "KeepAwakeMac authorization installed. It permits only pmset disablesleep 1 and 0."
        } else if result.succeeded && lidAuthorizationInstalled {
            lastError = "The KeepAwakeMac rule was installed, but sudo did not make the two pmset commands available."
        } else {
            lastError = "Could not install lid authorization. \(cleanError(result))"
        }
    }

    func removeLidAuthorization() async {
        guard !lidChanging else { return }
        lidChanging = true
        defer { lidChanging = false }
        lastError = nil
        lidStatusMessage = nil

        if lidClosedModeEnabled || kernelLidGuardActive || ownsSleepDisabled || UserDefaults.standard.bool(forKey: ownershipKey) {
            await disableLidClosedModeIfOwned()
        }

        let result = await ShellRunner.runAdministratorCommand("/bin/rm -f '\(sudoersPath)'")
        await refreshLidAuthorizationStatus()

        if result.succeeded && !lidAuthorizationInstalled {
            lidStatusMessage = pmsetPrivilegeAvailable
                ? "KeepAwakeMac authorization removed. Another sudoers rule still provides compatible pmset access."
                : "KeepAwakeMac lid authorization removed."
        } else {
            lastError = "Could not remove KeepAwakeMac's lid authorization. \(cleanError(result))"
        }
    }

    func refreshLidAuthorizationStatus() async {
        lidAuthorizationInstalled = FileManager.default.fileExists(atPath: sudoersPath)

        let one = await ShellRunner.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        let zero = await ShellRunner.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        pmsetPrivilegeAvailable = one.succeeded && zero.succeeded

        let warnings = [one.stderr, zero.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sudoConfigurationWarning = warnings.localizedCaseInsensitiveContains("bad permissions") ? warnings : nil
    }

    // MARK: - Lid mode

    func setLidClosedMode(_ enabled: Bool) async {
        guard !lidChanging else { return }
        guard isActive || !enabled else {
            lastError = "Start a Keep Awake session before enabling lid-closed mode."
            return
        }

        lidChanging = true
        defer { lidChanging = false }
        lastError = nil

        if !enabled {
            await disableLidClosedModeIfOwned()
            return
        }

        await refreshLidAuthorizationStatus()
        guard pmsetPrivilegeAvailable else {
            lastError = lidAuthorizationInstalled
                ? "KeepAwakeMac's authorization exists, but sudo is not accepting the pmset command."
                : "Install Lid Authorization first."
            return
        }

        await refreshSleepDisabledState()
        var enabledPMSetThisTime = false

        if sleepDisabledReadback {
            ownsSleepDisabled = UserDefaults.standard.bool(forKey: ownershipKey)
        } else {
            guard await setGlobalSleepDisabled(true) else {
                lastError = lastError ?? "macOS did not confirm SleepDisabled=1."
                return
            }
            ownsSleepDisabled = true
            enabledPMSetThisTime = true
            UserDefaults.standard.set(true, forKey: ownershipKey)
        }

        guard setKernelClamshellSleepDisabled(true) else {
            if enabledPMSetThisTime {
                _ = await setGlobalSleepDisabled(false)
                ownsSleepDisabled = false
                UserDefaults.standard.set(false, forKey: ownershipKey)
            }
            lastError = "The macOS kernel rejected the direct clamshell-sleep override (selector 12). Lid mode was not armed."
            return
        }

        lidClosedModeEnabled = true
        loadDisplayServices()
        findBuiltinDisplay()
        installWatchdog()
        startLidMonitor()
        startKernelHeartbeat()
        refreshLidAndDisplayState(forceBacklightAction: true)
        await refreshBatteryState()
        await enforceLowBatterySafetyIfNeeded()

        if appleClamshellCausesSleep == false {
            lidStatusMessage = "Kernel lid guard active + SleepDisabled=1 verified."
        } else {
            lidStatusMessage = "Kernel lid guard accepted (selector 12) + SleepDisabled=1. Clamshell policy is being re-applied continuously."
        }
    }

    func refreshSleepDisabledState() async {
        let result = await ShellRunner.run("/usr/bin/pmset", ["-g"])
        sleepDisabledReadback = parseSleepDisabled(result.stdout)
    }

    func refreshBatteryState() async {
        let result = await ShellRunner.run("/usr/bin/pmset", ["-g", "batt"])
        let text = result.stdout
        onBatteryPower = text.localizedCaseInsensitiveContains("Battery Power")
        if let match = text.range(of: #"\b(\d{1,3})%"#, options: .regularExpression) {
            batteryPercent = Int(text[match].dropLast())
        } else {
            batteryPercent = nil
        }
    }

    // MARK: - Kernel clamshell override

    private func ensureRootDomainConnection() -> Bool {
        if rootDomainConnection != 0 { return true }

        rootDomainService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomainService != 0 else {
            kernelSelectorStatus = "IOPMrootDomain unavailable"
            return false
        }

        let result = IOServiceOpen(rootDomainService, mach_task_self_, 0, &rootDomainConnection)
        guard result == KERN_SUCCESS else {
            kernelSelectorStatus = "IOServiceOpen failed: 0x\(String(result, radix: 16))"
            IOObjectRelease(rootDomainService)
            rootDomainService = 0
            rootDomainConnection = 0
            return false
        }
        return true
    }

    @discardableResult
    private func setKernelClamshellSleepDisabled(_ disabled: Bool) -> Bool {
        guard ensureRootDomainConnection() else {
            kernelLidGuardActive = false
            return false
        }

        var input: UInt64 = disabled ? 1 : 0
        let result = IOConnectCallScalarMethod(
            rootDomainConnection,
            kPMSetClamshellSleepStateSelector,
            &input,
            1,
            nil,
            nil
        )
        lastKernelSelectorResult = result
        refreshRootDomainState()

        if result == kIOReturnSuccess {
            kernelLidGuardActive = disabled
            kernelSelectorStatus = disabled ? "selector 12 accepted" : "selector 12 released"
            return true
        }

        kernelLidGuardActive = false
        kernelSelectorStatus = "selector 12 failed: 0x\(String(result, radix: 16))"
        return false
    }

    private func closeRootDomainConnection() {
        if rootDomainConnection != 0 {
            IOServiceClose(rootDomainConnection)
            rootDomainConnection = 0
        }
        if rootDomainService != 0 {
            IOObjectRelease(rootDomainService)
            rootDomainService = 0
        }
    }

    private func refreshRootDomainState() {
        lidIsClosed = readRootDomainBoolProperty("AppleClamshellState") ?? lidIsClosed
        appleClamshellCausesSleep = readRootDomainBoolProperty("AppleClamshellCausesSleep")
    }

    private func readRootDomainBoolProperty(_ key: String) -> Bool? {
        let service: io_service_t
        let shouldRelease: Bool
        if rootDomainService != 0 {
            service = rootDomainService
            shouldRelease = false
        } else {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            shouldRelease = true
        }
        guard service != 0 else { return nil }
        defer { if shouldRelease { IOObjectRelease(service) } }

        guard let value = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return nil }

        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func startKernelHeartbeat() {
        kernelHeartbeatTimer?.invalidate()
        kernelHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lidClosedModeEnabled else { return }
                _ = self.setKernelClamshellSleepDisabled(true)
                self.touchWatchdogToken()
            }
        }
    }

    private func stopKernelHeartbeat() {
        kernelHeartbeatTimer?.invalidate()
        kernelHeartbeatTimer = nil
    }

    // MARK: - Physical lid + backlight

    private func startLidMonitor() {
        lidMonitorTimer?.invalidate()
        lidMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLidAndDisplayState(forceBacklightAction: false)
            }
        }
        lidMonitorTimer?.tolerance = 0.05
    }

    private func stopLidMonitor() {
        lidMonitorTimer?.invalidate()
        lidMonitorTimer = nil
    }

    private func refreshLidAndDisplayState(forceBacklightAction: Bool) {
        let previousClosed = lidIsClosed
        refreshRootDomainState()
        hasExternalDisplay = detectExternalDisplay()

        let changedToClosed = lidIsClosed && !previousClosed
        let changedToOpen = !lidIsClosed && previousClosed

        if lidClosedModeEnabled, changedToClosed {
            // Re-assert immediately on the physical edge, in addition to the
            // periodic heartbeat and pmset layer.
            _ = setKernelClamshellSleepDisabled(true)
        }

        if changedToOpen || !lidIsClosed {
            if backlightDimmed { restoreBuiltinBacklight() }
            if !lidIsClosed { displaySleepStatus = nil }
            return
        }

        guard lidClosedModeEnabled else { return }

        if hasExternalDisplay {
            if backlightDimmed { restoreBuiltinBacklight() }
            displaySleepStatus = "Lid closed · external display detected; backlight override skipped."
            return
        }

        guard allowDisplaySleep else {
            if backlightDimmed { restoreBuiltinBacklight() }
            displaySleepStatus = "Lid closed · display brightness left unchanged by preference."
            return
        }

        if changedToClosed || forceBacklightAction || !backlightDimmed {
            dimBuiltinBacklight()
        }
    }

    private func loadDisplayServices() {
        guard dsGetBrightness == nil || dsSetBrightness == nil else { return }
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            displaySleepStatus = "Backlight API unavailable on this macOS build."
            return
        }
        guard let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") else {
            dlclose(handle)
            displaySleepStatus = "Backlight symbols unavailable on this macOS build."
            return
        }

        displayServicesHandle = handle
        dsGetBrightness = unsafeBitCast(getSymbol, to: DSGetBrightnessFn.self)
        dsSetBrightness = unsafeBitCast(setSymbol, to: DSSetBrightnessFn.self)
    }

    private func findBuiltinDisplay() {
        guard builtinDisplayID == nil else { return }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return }
        builtinDisplayID = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 })
    }

    private func dimBuiltinBacklight() {
        loadDisplayServices()
        findBuiltinDisplay()
        guard !backlightDimmed,
              let id = builtinDisplayID,
              let getBrightness = dsGetBrightness,
              let setBrightness = dsSetBrightness else {
            displaySleepStatus = "Lid closed · backlight control unavailable; display sleep was not forced so macOS will not be deliberately locked by this app."
            return
        }

        var current: Float = 0
        guard getBrightness(id, &current) == 0 else {
            displaySleepStatus = "Lid closed · could not read built-in display brightness."
            return
        }

        let clamped = max(0.0, min(1.0, current))
        savedBacklightBrightness = clamped
        if let path = watchdogBrightnessPath {
            try? "\(clamped)\n".write(toFile: path, atomically: true, encoding: .utf8)
        }

        let result = setBrightness(id, 0.0)
        if result == 0 {
            backlightDimmed = true
            displaySleepStatus = "Lid closed · built-in backlight set to 0 without starting display sleep/lock."
        } else {
            savedBacklightBrightness = nil
            if let path = watchdogBrightnessPath { try? FileManager.default.removeItem(atPath: path) }
            displaySleepStatus = "Lid closed · macOS rejected the backlight request (\(result))."
        }
    }

    private func restoreBuiltinBacklight() {
        guard backlightDimmed else { return }
        loadDisplayServices()
        findBuiltinDisplay()

        var target = savedBacklightBrightness
        if target == nil, let path = watchdogBrightnessPath,
           let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            target = Float(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let id = builtinDisplayID, let setBrightness = dsSetBrightness, let target {
            _ = setBrightness(id, max(0.05, min(1.0, target)))
        }

        backlightDimmed = false
        savedBacklightBrightness = nil
        if let path = watchdogBrightnessPath { try? FileManager.default.removeItem(atPath: path) }
    }

    private func detectExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains(where: { CGDisplayIsBuiltin($0) == 0 })
    }

    // MARK: - Crash watchdog

    private func installWatchdog() {
        removeWatchdogToken()

        let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/KeepAwakeMac", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let tokenURL = cacheDirectory.appendingPathComponent("lid-watchdog.token")
            let brightnessURL = cacheDirectory.appendingPathComponent("lid-watchdog.brightness")
            let token = UUID().uuidString
            try token.write(to: tokenURL, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: brightnessURL)

            watchdogTokenPath = tokenURL.path
            watchdogBrightnessPath = brightnessURL.path

            guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() else {
                lastError = "Kernel lid mode is active, but the watchdog executable directory could not be located."
                return
            }
            let helperURL = executableDirectory.appendingPathComponent("KeepAwakeLidWatchdog")
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                lastError = "Kernel lid mode is active, but KeepAwakeLidWatchdog is missing from this build."
                return
            }

            let process = Process()
            process.executableURL = helperURL
            process.arguments = [
                "\(getpid())",
                tokenURL.path,
                token,
                brightnessURL.path,
                "\(builtinDisplayID ?? 0)",
                ownsSleepDisabled ? "1" : "0"
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            watchdogProcess = process
        } catch {
            lastError = "Lid mode is active, but the crash watchdog could not be started: \(error.localizedDescription)"
        }
    }

    private func touchWatchdogToken() {
        guard let path = watchdogTokenPath else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    }

    private func removeWatchdogToken() {
        if let path = watchdogTokenPath { try? FileManager.default.removeItem(atPath: path) }
        watchdogTokenPath = nil
        watchdogProcess = nil
    }

    // MARK: - Safety + system power events

    private func installPowerNotifications() {
        guard wakeObserver == nil, vetoObserver == nil else { return }

        wakeObserver = NotificationCenter.default.addObserver(
            forName: .keepAwakeSystemPoweredOn,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastSystemWakeAt = Date()
                guard self.isActive else { return }
                if self.lidClosedModeEnabled {
                    _ = self.setKernelClamshellSleepDisabled(true)
                    await self.refreshSleepDisabledState()
                    if self.ownsSleepDisabled && !self.sleepDisabledReadback {
                        _ = await self.setGlobalSleepDisabled(true)
                    }
                    self.refreshLidAndDisplayState(forceBacklightAction: true)
                }
            }
        }

        vetoObserver = NotificationCenter.default.addObserver(
            forName: .keepAwakeSleepVetoed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastSleepVetoAt = Date()
            }
        }
    }

    private func startSafetyTimer() {
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshBatteryState()
                await self.refreshSleepDisabledState()

                if self.lidClosedModeEnabled {
                    _ = self.setKernelClamshellSleepDisabled(true)
                    if self.ownsSleepDisabled && !self.sleepDisabledReadback {
                        _ = await self.setGlobalSleepDisabled(true)
                    }
                    self.refreshLidAndDisplayState(forceBacklightAction: false)
                }
                await self.enforceLowBatterySafetyIfNeeded()
            }
        }
    }

    private func enforceLowBatterySafetyIfNeeded() async {
        guard lidClosedModeEnabled, ownsSleepDisabled, onBatteryPower, let batteryPercent else { return }
        guard batteryPercent <= max(5, lowBatteryCutoff) else { return }
        let message = "Lid-closed mode stopped at \(batteryPercent)% battery to avoid draining the Mac while system sleep is disabled."
        await stopAndRestoreSleep()
        lastError = message
    }

    private func setGlobalSleepDisabled(_ enabled: Bool) async -> Bool {
        let value = enabled ? "1" : "0"
        let result = await ShellRunner.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value])
        guard result.succeeded else {
            lastError = "pmset failed. \(cleanError(result))"
            return false
        }
        await refreshSleepDisabledState()
        return sleepDisabledReadback == enabled
    }

    private func disableLidClosedModeIfOwned() async {
        lidClosedModeEnabled = false
        restoreBuiltinBacklight()
        _ = setKernelClamshellSleepDisabled(false)
        kernelLidGuardActive = false
        stopLidMonitor()
        stopKernelHeartbeat()
        removeWatchdogToken()

        let markerOwned = UserDefaults.standard.bool(forKey: ownershipKey)
        if ownsSleepDisabled || markerOwned {
            if await setGlobalSleepDisabled(false) {
                ownsSleepDisabled = false
                UserDefaults.standard.set(false, forKey: ownershipKey)
                lidStatusMessage = "Normal macOS system sleep restored; kernel lid guard released."
            } else {
                lastError = "Could not restore SleepDisabled=0. Run: sudo pmset -a disablesleep 0"
            }
        } else {
            await refreshSleepDisabledState()
            lidStatusMessage = sleepDisabledReadback
                ? "Kernel lid guard released. SleepDisabled remains ON because KeepAwakeMac did not enable it."
                : "Normal macOS system sleep is active."
        }

        closeRootDomainConnection()
    }

    // MARK: - Diagnostics

    func diagnostics() async -> String {
        await refreshLidAuthorizationStatus()
        await refreshSleepDisabledState()
        await refreshBatteryState()
        refreshRootDomainState()
        refreshLidAndDisplayState(forceBacklightAction: false)

        async let settings = ShellRunner.run("/usr/bin/pmset", ["-g"])
        async let assertions = ShellRunner.run("/usr/bin/pmset", ["-g", "assertions"])
        async let battery = ShellRunner.run("/usr/bin/pmset", ["-g", "batt"])
        async let clamshell = ShellRunner.run("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "4"])
        async let sleepLog = ShellRunner.run("/bin/sh", ["-c", "/usr/bin/pmset -g log | /usr/bin/tail -n 80"])
        let (settingsResult, assertionsResult, batteryResult, clamshellResult, sleepLogResult) = await (settings, assertions, battery, clamshell, sleepLog)

        return """
        KeepAwakeMac diagnostics
        Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        Session active: \(isActive)
        KeepAwakeMac authorization file installed: \(lidAuthorizationInstalled)
        pmset privilege available: \(pmsetPrivilegeAvailable)
        Lid mode enabled in app: \(lidClosedModeEnabled)
        Physical lid closed: \(lidIsClosed)
        External display detected: \(hasExternalDisplay)
        Kernel lid guard active: \(kernelLidGuardActive)
        Kernel selector status: \(kernelSelectorStatus)
        Kernel selector return: 0x\(String(UInt32(bitPattern: lastKernelSelectorResult), radix: 16))
        AppleClamshellCausesSleep readback: \(appleClamshellCausesSleep.map(String.init) ?? "unknown")
        Display/backlight preference: \(allowDisplaySleep)
        Backlight dimmed by app: \(backlightDimmed)
        Saved backlight brightness: \(savedBacklightBrightness.map(String.init) ?? "none")
        Display/backlight status: \(displaySleepStatus ?? "none")
        Last idle-sleep veto: \(timestamp(lastSleepVetoAt))
        Last system wake notification: \(timestamp(lastSystemWakeAt))
        App owns SleepDisabled: \(ownsSleepDisabled)
        SleepDisabled readback: \(sleepDisabledReadback)
        Battery: \(batteryPercent.map(String.init) ?? "unknown")% / on battery: \(onBatteryPower)
        Low battery cutoff: \(lowBatteryCutoff)%
        Sudo configuration warning: \(sudoConfigurationWarning ?? "none")

        --- pmset -g ---
        \(settingsResult.stdout)
        \(settingsResult.stderr)

        --- pmset -g assertions ---
        \(assertionsResult.stdout)
        \(assertionsResult.stderr)

        --- pmset -g batt ---
        \(batteryResult.stdout)
        \(batteryResult.stderr)

        --- ioreg clamshell ---
        \(clamshellResult.stdout)
        \(clamshellResult.stderr)

        --- recent pmset sleep/wake log (last 80 lines) ---
        \(sleepLogResult.stdout)
        \(sleepLogResult.stderr)
        """
    }

    private func timestamp(_ date: Date?) -> String {
        guard let date else { return "none" }
        return ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Core assertion lifecycle

    private func acquirePowerAssertions() -> Bool {
        rollbackAssertions()
        let reason = "KeepAwakeMac session enabled by user"

        let systemResult = createAssertion(type: kIOPMAssertionTypePreventSystemSleep, reason: reason, id: &systemAssertionID)
        guard systemResult == kIOReturnSuccess else {
            lastError = "Could not create the system-sleep assertion (error \(systemResult))."
            return false
        }

        let idleResult = createAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: reason, id: &idleSystemAssertionID)
        guard idleResult == kIOReturnSuccess else {
            rollbackAssertions()
            lastError = "Could not create the idle-sleep assertion (error \(idleResult))."
            return false
        }

        if !allowDisplaySleep {
            let displayResult = createAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: reason, id: &displayAssertionID)
            guard displayResult == kIOReturnSuccess else {
                rollbackAssertions()
                lastError = "Could not create the display-sleep assertion (error \(displayResult))."
                return false
            }
        }
        return true
    }

    private func stopCore(clearError: Bool, disarmLid: Bool) {
        endTimer?.invalidate()
        ticker?.invalidate()
        safetyTimer?.invalidate()
        endTimer = nil
        ticker = nil
        safetyTimer = nil
        endDate = nil
        remainingSeconds = nil

        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
        systemPowerVeto.setEnabled(false)
        rollbackAssertions()
        isActive = false

        if disarmLid, lidClosedModeEnabled || kernelLidGuardActive || ownsSleepDisabled || UserDefaults.standard.bool(forKey: ownershipKey) {
            Task { @MainActor [weak self] in await self?.disableLidClosedModeIfOwned() }
        } else if !lidClosedModeEnabled {
            stopLidMonitor()
            stopKernelHeartbeat()
        }
        if clearError { lastError = nil }
    }

    private func createAssertion(type: String, reason: String, id: inout IOPMAssertionID) -> IOReturn {
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as NSString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as NSString,
            &newID
        )
        if result == kIOReturnSuccess { id = newID }
        return result
    }

    private func rollbackAssertions() {
        releaseAssertion(&displayAssertionID)
        releaseAssertion(&idleSystemAssertionID)
        releaseAssertion(&systemAssertionID)
    }

    private func releaseAssertion(_ id: inout IOPMAssertionID) {
        if id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }

    private func parseSleepDisabled(_ text: String) -> Bool {
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.contains("sleepdisabled") || lower.contains("disablesleep") {
                if let last = line.split(whereSeparator: { $0.isWhitespace }).last { return last == "1" }
            }
        }
        return false
    }

    private func cleanError(_ result: ShellResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? "exit status \(result.status)" : stdout
    }

    deinit {
        endTimer?.invalidate()
        ticker?.invalidate()
        safetyTimer?.invalidate()
        lidMonitorTimer?.invalidate()
        kernelHeartbeatTimer?.invalidate()
        systemPowerVeto.setEnabled(false)

        if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
        if let vetoObserver { NotificationCenter.default.removeObserver(vetoObserver) }

        if let activityToken { ProcessInfo.processInfo.endActivity(activityToken) }
        if displayAssertionID != 0 { IOPMAssertionRelease(displayAssertionID) }
        if idleSystemAssertionID != 0 { IOPMAssertionRelease(idleSystemAssertionID) }
        if systemAssertionID != 0 { IOPMAssertionRelease(systemAssertionID) }

        // Normal termination should use stopAndRestoreSleep(). These direct calls
        // are a last in-process cleanup layer; the companion watchdog covers crash.
        if rootDomainConnection != 0 {
            var input: UInt64 = 0
            _ = IOConnectCallScalarMethod(rootDomainConnection, kPMSetClamshellSleepStateSelector, &input, 1, nil, nil)
            IOServiceClose(rootDomainConnection)
        }
        if rootDomainService != 0 { IOObjectRelease(rootDomainService) }
        if let handle = displayServicesHandle { dlclose(handle) }
    }
}
