import Foundation
import IOKit.pwr_mgt

@MainActor
final class AwakeManager: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var endDate: Date?
    @Published private(set) var remainingSeconds: TimeInterval?
    @Published var allowDisplaySleep = true
    @Published var lastError: String?

    private var systemAssertionID: IOPMAssertionID = 0
    private var idleSystemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var activityToken: NSObjectProtocol?

    private var endTimer: Timer?
    private var ticker: Timer?

    func start(duration: TimeInterval?) {
        stop(clearError: false)
        lastError = nil

        let reason = "KeepAwakeMac session enabled by user"

        // Hold a PreventSystemSleep assertion in addition to the idle-sleep
        // assertion. The former asks macOS to remain awake (or in Dark Wake)
        // instead of entering full system sleep, while the latter explicitly
        // blocks ordinary idle sleep.
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

        // Also use Foundation's activity API. This gives macOS a second,
        // high-level signal that this is a user-requested activity which must
        // not be interrupted by idle sleep.
        var activityOptions: ProcessInfo.ActivityOptions = [
            .userInitiated,
            .idleSystemSleepDisabled
        ]
        if !allowDisplaySleep {
            activityOptions.insert(.idleDisplaySleepDisabled)
        }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: activityOptions,
            reason: reason
        )

        isActive = true

        if let duration {
            let safeDuration = max(1, duration)
            let deadline = Date().addingTimeInterval(safeDuration)
            endDate = deadline
            remainingSeconds = safeDuration

            endTimer = Timer.scheduledTimer(withTimeInterval: safeDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.stop()
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
    }

    func restartForDisplayPreferenceChange(duration: TimeInterval?) {
        guard isActive else { return }

        let remaining: TimeInterval?
        if let endDate {
            remaining = max(1, endDate.timeIntervalSinceNow)
        } else {
            remaining = duration
        }
        start(duration: remaining)
    }

    func stop(clearError: Bool = true) {
        endTimer?.invalidate()
        ticker?.invalidate()
        endTimer = nil
        ticker = nil
        endDate = nil
        remainingSeconds = nil

        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }

        rollbackAssertions()
        isActive = false

        if clearError {
            lastError = nil
        }
    }

    private func createAssertion(
        type: String,
        reason: String,
        id: inout IOPMAssertionID
    ) -> IOReturn {
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

    deinit {
        endTimer?.invalidate()
        ticker?.invalidate()

        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }

        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
        }
        if idleSystemAssertionID != 0 {
            IOPMAssertionRelease(idleSystemAssertionID)
        }
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
        }
    }
}
