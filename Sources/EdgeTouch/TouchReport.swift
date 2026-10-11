/// A decoded report from the touch controller's absolute-mouse interface
/// (wch.cn, VID 0x27C0 / PID 0x0859, HID report ID 7).
///
/// Layout: `[id, buttons, x lo, x hi, y lo, y hi, wheel]`. Bit 0 of `buttons`
/// is "finger on glass". The multitouch digitizer interface stays silent on
/// this firmware, so only a single contact is visible.
public struct TouchReport: Equatable {
    public static let reportID: UInt8 = 7
    public static let maxX: Double = 0x3FFF
    public static let maxY: Double = 0x257F

    public let down: Bool
    public let x: UInt16
    public let y: UInt16

    public init(down: Bool, x: UInt16, y: UInt16) {
        self.down = down
        self.x = x
        self.y = y
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 6, bytes[0] == TouchReport.reportID else { return nil }
        down = bytes[1] & 1 != 0
        x = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        y = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
    }

    /// Position as a fraction of the panel, clamped to 0...1.
    public var normalized: (x: Double, y: Double) {
        (min(max(Double(x) / TouchReport.maxX, 0), 1), min(max(Double(y) / TouchReport.maxY, 0), 1))
    }
}
