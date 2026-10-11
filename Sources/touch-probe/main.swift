import Foundation
import IOKit.hid

// Probe: dumps the HID report descriptor and live raw reports of the
// Xeneon Edge "TouchScreen" device(s). Pass --seize to take exclusive
// ownership (stops macOS moving the cursor).

let vendorID = 0x27C0
let seize = CommandLine.arguments.contains("--seize")
// --input-mode=N sets the Win8-style "Input Mode" feature (report 0x21) on the digitizer interface.
// Per Microsoft's Win8 touch spec (Device Mode, usage 0x52): 0 = mouse,
// 1 = single-input, 2 = multi-input.
let inputMode: UInt8? = CommandLine.arguments.compactMap { a -> UInt8? in
    a.hasPrefix("--input-mode=") ? UInt8(a.dropFirst("--input-mode=".count)) : nil
}.first

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID] as CFDictionary)

func prop(_ d: IOHIDDevice, _ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }

let inputCallback: IOHIDReportCallback = { _, _, sender, _, reportID, report, length in
    let bytes = UnsafeBufferPointer(start: report, count: length)
    let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    print("[\(sender.map { String(UInt(bitPattern: $0), radix: 16) } ?? "?")] id=\(reportID) len=\(length): \(hex)")
}

let attach: IOHIDDeviceCallback = { ctx, _, _, device in
    let pid = prop(device, kIOHIDProductIDKey) ?? "?"
    let page = prop(device, kIOHIDPrimaryUsagePageKey) ?? "?"
    let usage = prop(device, kIOHIDPrimaryUsageKey) ?? "?"
    print("== attached pid=\(pid) page=\(page) usage=\(usage)")
    if let desc = prop(device, kIOHIDReportDescriptorKey) as? Data {
        print("   descriptor (\(desc.count) bytes): " + desc.map { String(format: "%02x", $0) }.joined(separator: " "))
    }
    if let mode = inputMode, (page as? Int) == 0x0D {
        var out: [UInt8] = [0x21, mode, 0x00]
        let rc = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x21, &out, out.count)
        print("   set feature 0x21 mode=\(mode): 0x\(String(UInt32(bitPattern: rc), radix: 16))")
        var rb = [UInt8](repeating: 0, count: 8)
        var rbLen = rb.count
        let rr = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x21, &rb, &rbLen)
        print("   readback feature 0x21: rc=0x\(String(UInt32(bitPattern: rr), radix: 16)) \(rb.prefix(rbLen))")
        var maxC = [UInt8](repeating: 0, count: 8)
        var len = maxC.count
        let gc = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x0A, &maxC, &len)
        print("   get feature 0x0a (max contacts): rc=0x\(String(UInt32(bitPattern: gc), radix: 16)) \(maxC.prefix(len))")
    }
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256) // lives for process lifetime
    IOHIDDeviceRegisterInputReportCallback(device, buf, 256, inputCallback, nil)
}

IOHIDManagerRegisterDeviceMatchingCallback(manager, attach, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(manager, IOOptionBits(seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
if r != kIOReturnSuccess {
    fputs("IOHIDManagerOpen failed: 0x\(String(UInt32(bitPattern: r), radix: 16)) (grant Input Monitoring to your terminal?)\n", stderr)
    exit(1)
}
print("Listening (seize=\(seize)). Touch the screen; Ctrl-C to quit.")
CFRunLoopRun()
