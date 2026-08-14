import Foundation
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
        do {
            try process.run()
        } catch {
            // The app still keeps its own cleanup path. Failure to start the
            // watchdog is surfaced through diagnostics rather than crashing.
        }
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

    private let ownershipKey = "KeepAwakeMac.ownsSleepDisabled"
    private let sudoersPath = "/etc/sudoers.d/keepawakemac"

    private var systemAssertionID: IOPMAssertionID = 0
    private var idleSystemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var activityToken: NSObjectProtocol?

    private var endTimer: Timer?
    private var ticker: Timer?
    private var safetyTimer: Timer?
    private var heartbeatTimer: Timer?
    private var watchdogTokenPath: String?
    private var ownsSleepDisabled = false
    private var prepared = false

    func prepareOnLaunch() async {
        guard !prepared else { return }
        prepared = true

        await refreshLidAuthorizationStatus()
        await refreshSleepDisabledState()
        await refreshBatteryState()

        if UserDefaults.standard.bool(forKey: ownershipKey), sleepDisabledReadback {
            if lidAuthorizationInstalled {
                let result = await setGlobalSleepDisabled(false)
                if result {
                    UserDefaults.standard.set(false, forKey: ownershipKey)
                    removeWatchdogToken()
                    lidStatusMessage = "Recovered normal sleep after an interrupted previous session."
                } else {
                    lastError = "A previous lid-closed session may still have SleepDisabled enabled. Use Diagnostics or run: sudo pmset -a disablesleep 0"
                }
            } else {
                lastError = "A previous lid-closed session may still have SleepDisabled enabled, but authorization is missing. Run: sudo pmset -a disablesleep 0"
            }
        } else if !sleepDisabledReadback {
            UserDefaults.standard.set(false, forKey: ownershipKey)
        }
    }

    func start(duration: TimeInterval?) {
        stopCore(clearError: false, disarmLid: false)
        lastError = nil

        let reason = "KeepAwakeMac session enabled by user"

        let systemResult = createAssertion(
            type: kIOPMAssertionTypePreventSystemSleep,
            reason: reason,
            id: &systemAssertionID
        )
        guard systemResult == kIOReturnSuccess else {
            rollbackAssertions()
            lastError = "Could not create the system-sleep assertion (error \(systemResult))."
            return
        }

        let idleResult = createAssertion(
            type: kIOPMAssertionTypePreventUserIdleSystemSleep,
            reason: reason,
            id: &idleSystemAssertionID
        )
        guard idleResult == kIOReturnSuccess else {
            rollbackAssertions()
            lastError = "Could not create the idle-sleep assertion (error \(idleResult))."
            return
        }

        if !allowDisplaySleep {
            let displayResult = createAssertion(
                type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
                reason: reason,
                id: &displayAssertionID
            )
            guard displayResult == kIOReturnSuccess else {
                rollbackAssertions()
                lastError = "Could not create the display-sleep assertion (error \(displayResult))."
                return
            }
        }

        var activityOptions: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if !allowDisplaySleep {
            activityOptions.insert(.idleDisplaySleepDisabled)
        }
        activityToken = ProcessInfo.processInfo.beginActivity(options: activityOptions, reason: reason)
        isActive = true

        if let duration {
            let safeDuration = max(1, duration)
            let deadline = Date().addingTimeInterval(safeDuration)
            endDate = deadline
            remainingSeconds = safeDuration

            endTimer = Timer.scheduledTimer(withTimeInterval: safeDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    await self?.stopAndRestoreSleep()
                }
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
    }

    func stop() {
        stopCore(clearError: true, disarmLid: true)
    }

    func stopAndRestoreSleep() async {
        let shouldDisarm = lidClosedModeEnabled || ownsSleepDisabled || UserDefaults.standard.bool(forKey: ownershipKey)
        stopCore(clearError: true, disarmLid: false)
        if shouldDisarm {
            await disableLidClosedModeIfOwned()
        }
    }

    func installLidAuthorization() async {
        guard !lidChanging else { return }
        lidChanging = true
        defer { lidChanging = false }
        lastError = nil

        let username = NSUserName()
        let allowed = username.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        guard allowed else {
            lastError = "Your macOS username contains characters this installer does not support."
            return
        }

        let rule = "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        let safeRule = rule.replacingOccurrences(of: "'", with: "'\\''")
        let tempPath = "/tmp/keepawakemac.sudoers.\(getpid())"
        let command = "umask 077; printf '%s\\n' '\(safeRule)' > '\(tempPath)' && /usr/sbin/visudo -cf '\(tempPath)' && /usr/sbin/chown root:wheel '\(tempPath)' && /bin/chmod 0440 '\(tempPath)' && /bin/mkdir -p /etc/sudoers.d && /bin/mv '\(tempPath)' '\(sudoersPath)' && /usr/sbin/visudo -c"

        let result = await ShellRunner.runAdministratorCommand(command)
        await refreshLidAuthorizationStatus()

        if result.succeeded && lidAuthorizationInstalled {
            lidStatusMessage = "Authorization installed. It permits only pmset disablesleep 1 and 0."
        } else {
            lastError = "Could not install lid authorization. \(cleanError(result))"
        }
    }

    func removeLidAuthorization() async {
        guard !lidChanging else { return }
        lidChanging = true
        defer { lidChanging = false }
        lastError = nil

        if lidClosedModeEnabled || ownsSleepDisabled || UserDefaults.standard.bool(forKey: ownershipKey) {
            await disableLidClosedModeIfOwned()
        }

        let result = await ShellRunner.runAdministratorCommand("/bin/rm -f '\(sudoersPath)' && /usr/sbin/visudo -c")
        await refreshLidAuthorizationStatus()
        if result.succeeded && !lidAuthorizationInstalled {
            lidStatusMessage = "Lid authorization removed."
        } else {
            lastError = "Could not remove lid authorization. \(cleanError(result))"
        }
    }

    func refreshLidAuthorizationStatus() async {
        let one = await ShellRunner.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        let zero = await ShellRunner.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        lidAuthorizationInstalled = one.succeeded && zero.succeeded
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
        guard lidAuthorizationInstalled else {
            lastError = "Install Lid Authorization first."
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
                    lastError = "macOS did not confirm SleepDisabled=1. Lid-closed mode was not armed."
                    return
                }
                ownsSleepDisabled = true
                UserDefaults.standard.set(true, forKey: ownershipKey)
                lidClosedModeEnabled = true
                installWatchdog()
                lidStatusMessage = "SleepDisabled=1 verified. Lid-closed mode is armed."
            }
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
            let number = text[match].dropLast()
            batteryPercent = Int(number)
        } else {
            batteryPercent = nil
        }
    }

    func diagnostics() async -> String {
        await refreshLidAuthorizationStatus()
        await refreshSleepDisabledState()
        await refreshBatteryState()

        async let settings = ShellRunner.run("/usr/bin/pmset", ["-g"])
        async let assertions = ShellRunner.run("/usr/bin/pmset", ["-g", "assertions"])
        async let battery = ShellRunner.run("/usr/bin/pmset", ["-g", "batt"])
        let (settingsResult, assertionsResult, batteryResult) = await (settings, assertions, battery)

        return """
        KeepAwakeMac diagnostics
        Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        Session active: \(isActive)
        Lid authorization installed: \(lidAuthorizationInstalled)
        Lid mode enabled in app: \(lidClosedModeEnabled)
        App owns SleepDisabled: \(ownsSleepDisabled)
        SleepDisabled readback: \(sleepDisabledReadback)
        Battery: \(batteryPercent.map(String.init) ?? "unknown")% / on battery: \(onBatteryPower)
        Low battery cutoff: \(lowBatteryCutoff)%

        --- pmset -g ---
        \(settingsResult.stdout)
        \(settingsResult.stderr)

        --- pmset -g assertions ---
        \(assertionsResult.stdout)
        \(assertionsResult.stderr)

        --- pmset -g batt ---
        \(batteryResult.stdout)
        \(batteryResult.stderr)
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

    private func disableLidClosedModeIfOwned() async {
        lidClosedModeEnabled = false
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
                await self.enforceLowBatterySafetyIfNeeded()
            }
        }
    }

    private func enforceLowBatterySafetyIfNeeded() async {
        guard lidClosedModeEnabled, ownsSleepDisabled, onBatteryPower, let batteryPercent else { return }
        guard batteryPercent <= max(5, lowBatteryCutoff) else { return }

        lastError = "Lid-closed mode stopped at \(batteryPercent)% battery to avoid draining the Mac while sleep is disabled."
        let error = lastError
        await stopAndRestoreSleep()
        lastError = error
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
                guard let self, let path = self.watchdogTokenPath else { return }
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
            }

            ShellRunner.launchWatchdog(parentPID: getpid(), token: token, tokenPath: tokenPath.path)
        } catch {
            lastError = "Lid mode is active, but the crash watchdog could not be created: \(error.localizedDescription)"
        }
    }

    private func removeWatchdogToken() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if let watchdogTokenPath {
            try? FileManager.default.removeItem(atPath: watchdogTokenPath)
        }
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
            Task { @MainActor [weak self] in
                await self?.disableLidClosedModeIfOwned()
            }
        }

        if clearError {
            lastError = nil
        }
    }

    private func createAssertion(type: String, reason: String, id: inout IOPMAssertionID) -> IOReturn {
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as NSString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as NSString,
            &newID
        )
        if result == kIOReturnSuccess {
            id = newID
        }
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
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("sleepdisabled") || lower.contains("disablesleep") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if let last = parts.last {
                    return last == "1"
                }
            }
        }
        return false
    }

    private func cleanError(_ result: ShellResult) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "exit status \(result.status)" : output
    }

    deinit {
        endTimer?.invalidate()
        ticker?.invalidate()
        safetyTimer?.invalidate()
        heartbeatTimer?.invalidate()

        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
        if displayAssertionID != 0 { IOPMAssertionRelease(displayAssertionID) }
        if idleSystemAssertionID != 0 { IOPMAssertionRelease(idleSystemAssertionID) }
        if systemAssertionID != 0 { IOPMAssertionRelease(systemAssertionID) }
    }
}
