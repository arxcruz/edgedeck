/// One display mode the Edge offers, as macOS lists it.
public struct DisplayModeInfo: Equatable {
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refresh: Double
    public var usable: Bool

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refresh: Double, usable: Bool) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refresh = refresh
        self.usable = usable
    }
}

/// The Edge's Native mode: 2560×720, not HiDPI, at the highest refresh rate on offer.
public enum NativeMode {
    public static let width = 2560
    public static let height = 720

    public static func isNative(_ mode: DisplayModeInfo) -> Bool {
        mode.width == width && mode.height == height && mode.pixelWidth == width && mode.pixelHeight == height
    }

    /// The index of the mode to switch to, or nil when the Edge offers no Native mode.
    public static func pick(from modes: [DisplayModeInfo]) -> Int? {
        modes.indices
            .filter { isNative(modes[$0]) && modes[$0].usable }
            .max { modes[$0].refresh < modes[$1].refresh }
    }
}

/// How many times to try restoring the Native mode before giving up, so a fight with macOS or the
/// KVM can't turn into a reconfigure loop. Our own switch raises another display change, which
/// lands here too; only reaching the Native mode (or a manual retry) refills the budget.
public struct FixAttempts {
    public static let limit = 3
    private var used = 0

    public init() {}

    public mutating func shouldTry(isNative: Bool) -> Bool {
        if isNative {
            used = 0
            return false
        }
        guard used < Self.limit else { return false }
        used += 1
        return true
    }

    public mutating func reset() { used = 0 }
}
