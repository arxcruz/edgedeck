import Foundation
import IOKit.hid
import EdgeTouch

/// Seizes the Edge's touch-controller mouse interface so macOS stops moving the
/// cursor on its own, and forwards the decoded reports. `stop()` hands the device
/// back to macOS. (From Edgetap.)
final class TouchInput {
    static let vendorID = 0x27C0

    var onReport: ((TouchReport) -> Void)?
    var onRemoved: (() -> Void)?
    private(set) var isRunning = false
    /// Touch controllers currently attached and seized. Zero while running means the Edge's
    /// touchscreen hasn't (re)appeared to this manager.
    private(set) var attachedCount = 0

    // A new manager per start: one that was closed doesn't reliably deliver attach callbacks
    // again, which left touch dead after the Edge was replugged or Touch Support toggled.
    private var manager: IOHIDManager?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    func start() throws {
        guard !isRunning else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        configure(manager)
        // Common modes, not just the default one: while AppKit tracks a press (e.g. a tap in a
        // text field), the run loop is in event-tracking mode and must still hear the finger lift,
        // or AppKit waits for that mouse-up forever and every touch after it is lost.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let rc = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard rc == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            throw StartError.openFailed(rc)
        }
        self.manager = manager
        attachedCount = 0
        isRunning = true
    }

    func stop() {
        guard isRunning, let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = nil
        attachedCount = 0
        isRunning = false
    }

    private func configure(_ manager: IOHIDManager) {
        let match: [String: Any] = [
            kIOHIDVendorIDKey: TouchInput.vendorID,
            kIOHIDPrimaryUsagePageKey: 0x01,
            kIOHIDPrimaryUsageKey: 0x02,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let input = Unmanaged<TouchInput>.fromOpaque(context!).takeUnretainedValue()
            IOHIDDeviceRegisterInputReportCallback(device, input.buffer, 64, { context, _, _, _, _, report, length in
                let input = Unmanaged<TouchInput>.fromOpaque(context!).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                if let parsed = TouchReport(bytes: bytes) { input.onReport?(parsed) }
            }, context)
            input.attachedCount += 1
            NSLog("EdgeDeck: touch controller attached")
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            let input = Unmanaged<TouchInput>.fromOpaque(context!).takeUnretainedValue()
            input.attachedCount = max(0, input.attachedCount - 1)
            NSLog("EdgeDeck: touch controller removed")
            input.onRemoved?()
        }, context)
    }

    enum StartError: Error {
        case openFailed(IOReturn)

        /// Another process (Edgetap, the probe) already has the device seized.
        var isBusy: Bool {
            if case let .openFailed(rc) = self { return rc == kIOReturnExclusiveAccess }
            return false
        }
    }
}
