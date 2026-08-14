import Foundation
import IOKit.pwr_mgt

@MainActor
final class AwakeManager: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var endDate: Date?
    @Published private(set) var remainingSeconds: TimeInterval?
    @Published var allowDisplaySleep = true
    @Published var lastError: String?

    private var assertionID: IOPMAssertionID = 0
    private var endTimer: Timer?
    private var ticker: Timer?

    func start(duration: TimeInterval?) {
        stop(clearError: false)
        lastError = nil

        let assertionType: CFString = allowDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleSystemSleep
            : kIOPMAssertionTypeNoDisplaySleep

        var newAssertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "KeepAwakeMac session enabled by user" as CFString,
            &newAssertionID
        )

        guard result == kIOReturnSuccess else {
            lastError = "Could not create a macOS power assertion (error \(result))."
            return
        }

        assertionID = newAssertionID
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

        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }

        isActive = false
        if clearError { lastError = nil }
    }

    deinit {
        endTimer?.invalidate()
        ticker?.invalidate()
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }
}
