import AppKit
import CoreImage

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String?
    var album: String?
    var duration: Double?
    var elapsed: Double
    var rate: Double
    var timestamp: Date
    var playing: Bool
    var pid: pid_t

    /// Playback position extrapolated from the last report.
    func position(at date: Date) -> Double {
        var position = elapsed
        if playing { position += date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1) }
        if let duration, duration > 0 { position = min(position, duration) }
        return max(position, 0)
    }

    /// True when the media is playing in a WebKit view (EdgeDeck's Edge player).
    var isWebKitPlayer: Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.hasPrefix("com.apple.WebKit") == true
    }

    /// The app playing the media. Helper processes (e.g. a browser's media
    /// helper) are mapped back to the app bundle that contains them.
    var mediaSource: NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        guard let path = app.bundleURL?.path, app.activationPolicy != .regular,
              let range = path.range(of: ".app/") else { return app }
        let outer = String(path[..<range.lowerBound]) + ".app"
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == outer } ?? app
    }
}

/// Runs the EdgeDeckMedia helper inside /usr/bin/perl (see Helpers/EdgeDeckMedia.m)
/// and mirrors what macOS reports as Now Playing.
final class NowPlayingModel: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var artwork: NSImage?
    /// Pre-blurred copy of the artwork for the widget background.
    @Published private(set) var backdrop: NSImage?
    @Published private(set) var unavailableReason: String?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var artworkKey: String?
    private var artworkByTitle: [String: NSImage] = [:]
    private var recentFailures: [Date] = []

    private static let launcher = """
        use DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $sym = DynaLoader::dl_find_symbol($lib, "edgedeck_media_run") or die "symbol missing";
        DynaLoader::dl_install_xsub("main::run", $sym);
        run();
        """

    func start() {
        guard process == nil else { return }
        guard let helper = Bundle.main.url(forResource: "EdgeDeckMedia", withExtension: "dylib") else {
            unavailableReason = "Media helper missing from the app bundle"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.launcher, helper.path]
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.helperExited() }
        }

        do {
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
        } catch {
            unavailableReason = "Couldn't start media helper: \(error.localizedDescription)"
        }
    }

    private func helperExited() {
        process = nil
        input = nil
        buffer.removeAll()
        // Restart, but give up if it keeps dying (e.g. a future macOS blocks it).
        recentFailures = recentFailures.filter { $0 > Date().addingTimeInterval(-60) } + [Date()]
        if recentFailures.count >= 5 {
            unavailableReason = "Now Playing isn't available on this macOS version"
            info = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(object) }
        }
    }

    private func apply(_ json: [String: Any]) {
        unavailableReason = nil
        guard let title = json["title"] as? String, !title.isEmpty else {
            info = nil
            artwork = nil
            backdrop = nil
            artworkKey = nil
            return
        }
        let timestamp = (json["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        info = NowPlayingInfo(
            title: title,
            artist: json["artist"] as? String,
            album: json["album"] as? String,
            duration: json["duration"] as? Double,
            elapsed: json["elapsedtime"] as? Double ?? 0,
            rate: json["playbackrate"] as? Double ?? 0,
            timestamp: timestamp,
            playing: json["playing"] as? Bool ?? false,
            pid: pid_t(json["pid"] as? Int ?? 0))

        // Decode artwork only when it changes.
        let encoded = json["artwork"] as? String
        let key = (json["artworkidentifier"] as? String) ?? encoded.map { "\($0.count):\($0.suffix(32))" }
        if key != artworkKey {
            artworkKey = key
            if let image = encoded.flatMap({ Data(base64Encoded: $0) }).flatMap({ NSImage(data: $0) }) {
                artwork = image
                artworkByTitle[title] = image
                if artworkByTitle.count > 20 { artworkByTitle.removeValue(forKey: artworkByTitle.keys.first!) }
            } else {
                // The same item handed to a player that reports no artwork (EdgeDeck's
                // own Edge player, for instance) keeps the artwork seen earlier.
                artwork = artworkByTitle[title]
            }
            backdrop = artwork.flatMap(Self.blurred)
        }
    }

    /// Blurs into the bitmap itself rather than with a SwiftUI effect, so the
    /// backdrop looks the same however the view is rendered.
    private static func blurred(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let radius = max(input.extent.width, input.extent.height) / 12
        guard let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4, kCIInputBrightnessKey: -0.25])
            .cropped(to: input.extent) as CIImage?,
            let result = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
    }

    // MARK: Controls

    private func send(_ command: String) {
        input?.write(Data((command + "\n").utf8))
    }

    func togglePlayPause() {
        // Update optimistically so the button responds instantly; the helper's report follows.
        if var current = info {
            current.elapsed = current.position(at: Date())
            current.timestamp = Date()
            current.playing.toggle()
            info = current
        }
        send("toggle")
    }

    func play() { send("play") }
    func pause() { send("pause") }
    func next() { send("next") }
    func previous() { send("previous") }

    func seek(to seconds: Double) {
        if var current = info {
            current.elapsed = seconds
            current.timestamp = Date()
            info = current
        }
        send("seek \(seconds)")
    }

    func bringSourceToFront() {
        guard let app = info?.mediaSource else { return }
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            app.activate()
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
    }
}
