import CoreGraphics
import Foundation
import EdgeDisplay

/// The Edge's 2560×720 mode is missing from CGDisplayCopyAllDisplayModes (even while it is the
/// current mode), but System Settings lists it under "Show all resolutions". This reads and
/// switches to it through CoreGraphics's private CGS calls, looked up by name at run time.
///
/// Private API: this whole file is the only place that uses it. Deleting it (and the call in
/// EdgeResolution) leaves a build that falls back to the public mode list, as the Mac App Store
/// would require. Every lookup can fail; callers treat that as "no such mode".
enum PrivateDisplayModes {
    struct Mode {
        let number: Int32
        let info: DisplayModeInfo
    }

    private typealias CountFn = @convention(c) (UInt32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias DescribeFn = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer, Int32) -> Int32
    private typealias ConfigureFn = @convention(c) (CGDisplayConfigRef?, UInt32, Int32) -> CGError

    // CGSDisplayMode: modeNumber, flags, width, height, depth (UInt32 each), 170 unknown bytes,
    // refresh (UInt16), 16 unknown bytes, density (Float).
    private static let size = 212
    private static let refreshOffset = 190
    private static let densityOffset = 208

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(dlopen(nil, RTLD_NOW), name).map { unsafeBitCast($0, to: type) }
    }

    static func modes(of display: CGDirectDisplayID) -> [Mode] {
        guard let count = symbol("CGSGetNumberOfDisplayModes", as: CountFn.self),
              let describe = symbol("CGSGetDisplayModeDescriptionOfLength", as: DescribeFn.self) else { return [] }
        var n: Int32 = 0
        guard count(display, &n) == 0, n > 0 else { return [] }
        return (0..<n).compactMap { index in
            var buffer = [UInt8](repeating: 0, count: size)
            let status = buffer.withUnsafeMutableBytes { describe(display, index, $0.baseAddress!, Int32(size)) }
            guard status == 0 else { return nil }
            return buffer.withUnsafeBytes { raw in
                let width = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
                let height = Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                let density = Double(raw.loadUnaligned(fromByteOffset: densityOffset, as: Float.self))
                let info = DisplayModeInfo(
                    width: width, height: height,
                    pixelWidth: Int((Double(width) * density).rounded()), pixelHeight: Int((Double(height) * density).rounded()),
                    refresh: Double(raw.loadUnaligned(fromByteOffset: refreshOffset, as: UInt16.self)), usable: true)
                return Mode(number: Int32(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)), info: info)
            }
        }
    }

    static func apply(_ mode: Mode, to display: CGDirectDisplayID) -> Bool {
        guard let configure = symbol("CGSConfigureDisplayMode", as: ConfigureFn.self) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard configure(config, display, mode.number) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}
