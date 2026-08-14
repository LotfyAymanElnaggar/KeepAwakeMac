import Foundation
import CoreGraphics
import IOKit.pwr_mgt

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

    static func launchWatchdog(parentPID: Int32, token: String, tokenPath: String) {
        let quotedToken = shellQuote(token)
        let quotedPath = shellQuote(tokenPath)
        let script = """
        while true; do
          /bin/sleep 15
          if [ ! -f \(quotedPath) ]; then exit 0; fi
          if [ \"$(/bin/cat \(quotedPath) 2>/dev/null)\" != \(quotedToken) ]; then exit 0; fi
          if ! /bin/kill -0 \(parentPID) 2>/dev/null; then
            /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || true
            /bin/rm -f \(quotedPath)
            exit 0
          fi
          now=$(/bin/date +%s)
          modified=$(/usr/bin/stat -f %m \(quotedPath) 2>/dev/null || echo 0)
          if [ $((now - modified)) -gt 60 ]; then
            /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || true
            /bin/rm -f \(quotedPath)
            exit 0
          fi
        done
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/bin/sh", "-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

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

    // v1.2: physical lid + display-power state.
    @Published private(set) var lidIsClosed = false
    @Published private(set) var hasExternalDisplay = false
    @Published private(set) var displaySleepStatus: String?

    private let ownershipKey = "KeepAwakeMac.ownsSleepDisabled"
    private let sudoersPath = "/etc/sudoers.d/keepawakemac"

    private var pmsetPrivilegeAvailable = false
    private var systemAssertionID: IOPMAssertionID = 0
    private var idleSystemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var activityToken: NSObjectProtocol?

    private var endTimer: Timer?
    private var ticker: Timer?
    private var safetyTimer: Timer?
    private var heartbeatTimer: Timer?
    private var lidMonitorTimer: Timer?
    private var watchdogTokenPath: String?
    private var ownsSleepDisabled = false
    private var prepared = false
    private var lastDisplaySleepRequestAt: Date?

    func prepareOnLaunch() async {
        guard !prepared else { return }
        prepared = true

        await refreshLidAuthorizationStatus()
        await refreshSleepDisabledState()
        await refreshBatteryState()
        await refreshLidAndDisplayState(forceDisplaySleep: false)

        if UserDefaults.standard.bool(forKey: ownershipKey), sleepDisabledReadback {
            if pmsetPrivilegeAvailable {
                if await setGlobalSleepDisabled(false) {
                    UserDefaults.standard.set(false, forKey: ownershipKey)
                    removeWatchdogToken()
                    lidStatusMessage = "Recovered normal sleep after an interrupted previous session."
                } else {
                    lastError = "A previous lid-closed session may still have SleepDisabled enabled. Run: sudo pmset -a disablesleep 0"
                }
            } else {
                lastError = "A previous lid-closed session may still have SleepDisabled enabled, but pmset authorization is unavailable. Run: sudo pmset -a disablesleep 0"
            }
        } else if !sleepDisabledReadback {
            UserDefaults.standard.set(false, forKey: ownershipKey)
        }
    }

    func start(duration: TimeInterval?) {
        stopCore(clearError: false, disarmLid: false)
        lastError = nil

        let reason = "KeepAwakeMac session enabled by user"
        let systemResult = createAssertion(type: kIOPMAssertionTypePreventSystemSleep, reason: reason, id: &systemAssertionID)
        guard systemResult == kIOReturnSuccess else {
            rollbackAssertions()
            lastError = "Could not create the system-sleep assertion (error \(systemResult))."
            return
        }

        let idleResult = createAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: reason, id: &idleSystemAssertionID)
        guard idleResult == kIOReturnSuccess else {
            rollbackAssertions()
            lastError = "Could not create the idle-sleep assertion (error \(idleResult))."
            return
        }

        if !allowDisplaySleep {
            let displayResult = createAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: reason, id: &displayAssertionID)
            guard displayResult == kIOReturnSuccess else {
                rollbackAssertions()
                lastError = "Could not create the display-sleep assertion (error \(displayResult))."
                return
            }
        }

        var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if !allowDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
        activityToken = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
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

        startSafetyTimer()
    }

    func restartForDisplayPreferenceChange(duration: TimeInterval?) {
        guard isActive else { return }
        let remaining = endDate.map { max(1, $0.timeIntervalSinceNow) } ?? duration
        start(duration: remaining)

        if lidClosedModeEnabled {
            startLidMonitor()
            Task { @MainActor [weak self] in
                await self?.refreshLidAndDisplayState(forceDisplaySleep: true)
            }
        }
    }

    func stop() {
        stopCore(clearError: true, disarmLid: true)
    }

    func stopAndRestoreSleep() async {
        let shouldDisarm = lidClosedModeEnabled || ownsSleepDisabled || UserDefaults.standard.bool(forKey: ownershipKey)
        stopCore(clearError: true, disarmLid: false)
        if shouldDisarm { await disableLidClosedModeIfOwned() }
    }

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
            lastError = "The KeepAwakeMac rule was installed, but sudo did not make the two pmset commands available. Another sudoers configuration problem may be interfering."
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

        if lidClosedModeEnabled || ownsSleepDisabled || UserDefaults.standard.bool(forKey: ownershipKey) {
            await disableLidClosedModeIfOwned()
        }

        let result = await ShellRunner.runAdministratorCommand("/bin/rm -f '\(sudoersPath)'")
        await refreshLidAuthorizationStatus()

        if result.succeeded && !lidAuthorizationInstalled {
            if pmsetPrivilegeAvailable {
                lidStatusMessage = "KeepAwakeMac authorization removed. A compatible pmset permission is still being provided by another sudoers rule."
            } else {
                lidStatusMessage = "KeepAwakeMac lid authorization removed."
            }
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

    func setLidClosedMode(_ enabled: Bool) async {
        guard !lidChanging else { return }
        guard isActive || !enabled else {
            lastError = "Start a Keep Awake session before enabling lid-closed mode."
            return
        }

        lidChanging = true
        defer { lidChanging = false }
        lastError = nil

        await refreshLidAuthorizationStatus()
        guard pmsetPrivilegeAvailable else {
            lastError = lidAuthorizationInstalled
                ? "KeepAwakeMac's authorization exists, but sudo is not accepting the pmset command. Check the sudo configuration warning in Diagnostics."
                : "Install Lid Authorization first."
            lidClosedModeEnabled = false
            return
        }

        await refreshSleepDisabledState()
        if enabled {
            if sleepDisabledReadback {
                ownsSleepDisabled = UserDefaults.standard.bool(forKey: ownershipKey)
                lidClosedModeEnabled = true
                lidStatusMessage = ownsSleepDisabled
                    ? "SleepDisabled is verified ON."
                    : "SleepDisabled was already ON outside KeepAwakeMac; it will not be turned off automatically."
            } else {
                guard await setGlobalSleepDisabled(true) else {
                    lidClosedModeEnabled = false
                    if lastError == nil { lastError = "macOS did not confirm SleepDisabled=1. Lid-closed mode was not armed." }
                    return
                }
                ownsSleepDisabled = true
                UserDefaults.standard.set(true, forKey: ownershipKey)
                lidClosedModeEnabled = true
                installWatchdog()
                lidStatusMessage = "SleepDisabled=1 verified. Lid-closed mode is armed."
            }

            startLidMonitor()
            await refreshLidAndDisplayState(forceDisplaySleep: true)
            await refreshBatteryState()
            await enforceLowBatterySafetyIfNeeded()
        } else {
            await disableLidClosedModeIfOwned()
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

    func diagnostics() async -> String {
        await refreshLidAuthorizationStatus()
        await refreshSleepDisabledState()
        await refreshBatteryState()
        await refreshLidAndDisplayState(forceDisplaySleep: false)

        async let settings = ShellRunner.run("/usr/bin/pmset", ["-g"])
        async let assertions = ShellRunner.run("/usr/bin/pmset", ["-g", "assertions"])
        async let battery = ShellRunner.run("/usr/bin/pmset", ["-g", "batt"])
        async let clamshell = ShellRunner.run("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "4"])
        let (settingsResult, assertionsResult, batteryResult, clamshellResult) = await (settings, assertions, battery, clamshell)

        return """
        KeepAwakeMac diagnostics
        Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        Session active: \(isActive)
        KeepAwakeMac authorization file installed: \(lidAuthorizationInstalled)
        pmset privilege available: \(pmsetPrivilegeAvailable)
        Lid mode enabled in app: \(lidClosedModeEnabled)
        Physical lid closed: \(lidIsClosed)
        External display detected: \(hasExternalDisplay)
        Display sleep preference: \(allowDisplaySleep)
        Display sleep status: \(displaySleepStatus ?? "none")
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
        """
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

    // MARK: - Closed-lid display power

    private func startLidMonitor() {
        lidMonitorTimer?.invalidate()
        lidMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshLidAndDisplayState(forceDisplaySleep: false)
            }
        }
    }

    private func stopLidMonitor() {
        lidMonitorTimer?.invalidate()
        lidMonitorTimer = nil
        lastDisplaySleepRequestAt = nil
        displaySleepStatus = nil
    }

    private func refreshLidAndDisplayState(forceDisplaySleep: Bool) async {
        let result = await ShellRunner.run("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "4"])
        let newClosedState = parseClamshellClosed(result.stdout)
        let changedToClosed = newClosedState && !lidIsClosed
        lidIsClosed = newClosedState
        hasExternalDisplay = detectExternalDisplay()

        guard lidClosedModeEnabled, allowDisplaySleep, lidIsClosed else {
            if !lidIsClosed {
                lastDisplaySleepRequestAt = nil
                displaySleepStatus = nil
            }
            return
        }

        if hasExternalDisplay {
            displaySleepStatus = "Lid closed · external display detected, so display sleep was not forced."
            return
        }

        let stale = lastDisplaySleepRequestAt.map { Date().timeIntervalSince($0) >= 20 } ?? true
        if forceDisplaySleep || changedToClosed || stale {
            await requestDisplaySleepNow()
        }
    }

    private func requestDisplaySleepNow() async {
        // `pmset displaysleepnow` sleeps the display without sleeping the Mac.
        // It does not require the privileged disablesleep sudo rule.
        let result = await ShellRunner.run("/usr/bin/pmset", ["displaysleepnow"])
        if result.succeeded {
            lastDisplaySleepRequestAt = Date()
            displaySleepStatus = "Lid closed · display sleep requested while the Mac remains awake."
        } else {
            displaySleepStatus = "Lid closed · display sleep command failed."
            lastError = "The Mac is staying awake, but macOS rejected the display-sleep request: \(cleanError(result))"
        }
    }

    private func detectExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }

        for display in displays.prefix(Int(count)) {
            if CGDisplayIsBuiltin(display) == 0 {
                return true
            }
        }
        return false
    }

    private func parseClamshellClosed(_ text: String) -> Bool {
        for line in text.components(separatedBy: .newlines) {
            guard line.localizedCaseInsensitiveContains("AppleClamshellState") else { continue }
            return line.localizedCaseInsensitiveContains("Yes")
        }
        return false
    }

    private func disableLidClosedModeIfOwned() async {
        lidClosedModeEnabled = false
        stopLidMonitor()
        removeWatchdogToken()

        let markerOwned = UserDefaults.standard.bool(forKey: ownershipKey)
        if ownsSleepDisabled || markerOwned {
            if await setGlobalSleepDisabled(false) {
                ownsSleepDisabled = false
                UserDefaults.standard.set(false, forKey: ownershipKey)
                lidStatusMessage = "Normal macOS sleep restored (SleepDisabled=0)."
            } else {
                lastError = "Could not restore SleepDisabled=0. Run: sudo pmset -a disablesleep 0"
            }
        } else {
            await refreshSleepDisabledState()
            lidStatusMessage = sleepDisabledReadback
                ? "SleepDisabled is still ON because KeepAwakeMac did not enable it."
                : "Normal macOS sleep is active."
        }
    }

    private func startSafetyTimer() {
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshBatteryState()
                await self.refreshSleepDisabledState()
                await self.refreshLidAndDisplayState(forceDisplaySleep: false)
                await self.enforceLowBatterySafetyIfNeeded()
            }
        }
    }

    private func enforceLowBatterySafetyIfNeeded() async {
        guard lidClosedModeEnabled, ownsSleepDisabled, onBatteryPower, let batteryPercent else { return }
        guard batteryPercent <= max(5, lowBatteryCutoff) else { return }
        let message = "Lid-closed mode stopped at \(batteryPercent)% battery to avoid draining the Mac while sleep is disabled."
        await stopAndRestoreSleep()
        lastError = message
    }

    private func installWatchdog() {
        removeWatchdogToken()
        let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/KeepAwakeMac", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let tokenPath = cacheDirectory.appendingPathComponent("lid-watchdog.token")
            let token = UUID().uuidString
            try token.write(to: tokenPath, atomically: true, encoding: .utf8)
            watchdogTokenPath = tokenPath.path

            heartbeatTimer?.invalidate()
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let path = self.watchdogTokenPath else { return }
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
                }
            }
            ShellRunner.launchWatchdog(parentPID: getpid(), token: token, tokenPath: tokenPath.path)
        } catch {
            lastError = "Lid mode is active, but the crash watchdog could not be created: \(error.localizedDescription)"
        }
    }

    private func removeWatchdogToken() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if let watchdogTokenPath { try? FileManager.default.removeItem(atPath: watchdogTokenPath) }
        watchdogTokenPath = nil
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
        rollbackAssertions()
        isActive = false

        if disarmLid, lidClosedModeEnabled || ownsSleepDisabled || UserDefaults.standard.bool(forKey: ownershipKey) {
            Task { @MainActor [weak self] in await self?.disableLidClosedModeIfOwned() }
        } else if !lidClosedModeEnabled {
            stopLidMonitor()
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
        heartbeatTimer?.invalidate()
        lidMonitorTimer?.invalidate()
        if let activityToken { ProcessInfo.processInfo.endActivity(activityToken) }
        if displayAssertionID != 0 { IOPMAssertionRelease(displayAssertionID) }
        if idleSystemAssertionID != 0 { IOPMAssertionRelease(idleSystemAssertionID) }
        if systemAssertionID != 0 { IOPMAssertionRelease(systemAssertionID) }
    }
}
