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

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var configured = false

    func start() throws {
        guard !isRunning else { return }
        configure()
        // Common modes, not just the default one: while AppKit tracks a press (e.g. a tap in a
        // text field), the run loop is in event-tracking mode and must still hear the finger lift,
        // or AppKit waits for that mouse-up forever and every touch after it is lost.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let rc = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard rc == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            throw StartError.openFailed(rc)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        isRunning = false
    }

    private func configure() {
        guard !configured else { return }
        configured = true
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
            NSLog("EdgeDeck: touch controller attached")
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            let input = Unmanaged<TouchInput>.fromOpaque(context!).takeUnretainedValue()
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
