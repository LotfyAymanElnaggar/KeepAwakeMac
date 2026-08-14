import Foundation
import IOKit
import IOKit.pwr_mgt

extension Notification.Name {
    static let keepAwakeSystemPoweredOn = Notification.Name("KeepAwakeMac.SystemPoweredOn")
    static let keepAwakeSleepVetoed = Notification.Name("KeepAwakeMac.SleepVetoed")
}

// IORegisterForSystemPower delivers idle-sleep permission requests separately
// from ordinary IOPM assertions. While a KeepAwakeMac session is active, cancel
// kIOMessageCanSystemSleep as an independent guard. Forced sleeps (shutdown,
// thermal emergency, critical battery, etc.) still have to be acknowledged.
private let kIOMessageCanSystemSleepRaw: UInt32 = 0xE0000270
private let kIOMessageSystemWillSleepRaw: UInt32 = 0xE0000280
private let kIOMessageSystemHasPoweredOnRaw: UInt32 = 0xE0000300

private let keepAwakePowerCallback: IOServiceInterestCallback = { refCon, _, messageType, argument in
    guard let refCon else { return }
    let guardObject = Unmanaged<SystemPowerVeto>.fromOpaque(refCon).takeUnretainedValue()
    guardObject.handle(messageType: messageType, argument: argument)
}

final class SystemPowerVeto {
    private let lock = NSLock()
    private var enabled = false

    private var rootPowerPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notifyPort: IONotificationPortRef?

    init() {
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        rootPowerPort = IORegisterForSystemPower(
            refCon,
            &notifyPort,
            keepAwakePowerCallback,
            &notifier
        )

        if rootPowerPort != 0, let notifyPort {
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                CFRunLoopMode.defaultMode
            )
        }
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }

    fileprivate func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        lock.lock()
        let shouldVeto = enabled
        lock.unlock()

        let notificationID = Int(bitPattern: argument)

        switch messageType {
        case kIOMessageCanSystemSleepRaw:
            if shouldVeto {
                IOCancelPowerChange(rootPowerPort, notificationID)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .keepAwakeSleepVetoed, object: nil)
                }
            } else {
                IOAllowPowerChange(rootPowerPort, notificationID)
            }

        case kIOMessageSystemWillSleepRaw:
            // This notification is mandatory-ack. We cannot veto emergency or
            // other forced sleep here, so acknowledge it as required by IOKit.
            IOAllowPowerChange(rootPowerPort, notificationID)

        case kIOMessageSystemHasPoweredOnRaw:
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .keepAwakeSystemPoweredOn, object: nil)
            }

        default:
            break
        }
    }

    deinit {
        setEnabled(false)
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
        if rootPowerPort != 0 {
            IOServiceClose(rootPowerPort)
            rootPowerPort = 0
        }
    }
}
