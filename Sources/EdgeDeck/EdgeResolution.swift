import CoreGraphics
import EdgeDisplay

/// Keeps the Edge in its Native mode: macOS sometimes drops it to 1080p (after a replug, wake or
/// KVM switch), which the user otherwise fixes by hand in System Settings.
final class EdgeResolution {
    enum Outcome { case native, fixed, couldNotFix, gaveUp }

    private var attempts = FixAttempts()
    /// Shown in the menu while the Edge is stuck in the wrong mode.
    private(set) var stuck = false

    /// Puts `display` in the Native mode if it isn't. A manual run starts the attempt count again.
    @discardableResult
    func check(_ display: CGDirectDisplayID, manual: Bool = false) -> Outcome {
        if manual { attempts.reset() }
        guard let current = CGDisplayCopyDisplayMode(display) else { return .couldNotFix }
        if NativeMode.isNative(Self.info(current)) {
            stuck = false
            _ = attempts.shouldTry(isNative: true)
            return .native
        }
        guard attempts.shouldTry(isNative: false) else {
            stuck = true
            return .gaveUp
        }
        guard restoreNative(on: display) else {
            stuck = true
            return .couldNotFix
        }
        return .fixed
    }

    /// The private mode list first, since only it has the Edge's 2560×720; the public one if that's unavailable.
    private func restoreNative(on display: CGDirectDisplayID) -> Bool {
        let hidden = PrivateDisplayModes.modes(of: display)
        if let index = NativeMode.pick(from: hidden.map(\.info)) {
            return PrivateDisplayModes.apply(hidden[index], to: display)
        }
        let modes = Self.modes(of: display)
        guard let index = NativeMode.pick(from: modes.map(Self.info)) else { return false }
        return apply(modes[index], to: display)
    }

    private func apply(_ mode: CGDisplayMode, to display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        // Permanently: the same as picking it in System Settings, so macOS remembers it.
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    private static func modes(of display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
    }

    private static func info(_ mode: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                        refresh: mode.refreshRate, usable: mode.isUsableForDesktopGUI())
    }
}
