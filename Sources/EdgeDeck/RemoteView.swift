import AppKit
import AVFoundation
import CoreMedia
import CryptoKit
import IOKit.pwr_mgt
import Network
import ScreenCaptureKit
import SwiftUI
import VideoToolbox

// Remote view: the Edge shows another Mac's Dashboard. The Host (the Mac the Edge is plugged
// into) connects to the Source, which draws its Dashboard in its usual panel (hidden under the
// wallpaper when it has no Edge) and streams it as HEVC video; the Host sends touches back as
// mouse events for that panel. Pixels, not Widget data: see docs/adr/0001. The connection
// (framing, Pairing, encryption) is in RemoteChannel.swift.

// MARK: - Host

/// The Host side: finds Sources on the network and shows the chosen one's Dashboard.
final class RemoteHost: ObservableObject {
    /// Sources found on the network (other Macs running EdgeDeck), by name.
    @Published private(set) var sources: [String] = []
    /// The Source on the Edge (or being connected to or Paired with); nil = this Mac's own Dashboard.
    @Published private(set) var current: String?
    /// While Pairing: the code to type on the Source.
    @Published private(set) var pairingCode: String?
    /// The list of Macs to show on the Edge is open (from the Source pill).
    @Published var chooserOpen = false
    /// The Source is in Edit mode: its toolbar is where the Source pill would be.
    @Published private(set) var sourceEditing = false
    /// A Remote view ended on its own; the reason, for a Toast.
    var onProblem: (String) -> Void = { NSLog("EdgeDeck: Remote view: \($0)") }
    /// The Dashboard size the Source should draw at.
    var dashboardSize = CGSize(width: 2560, height: 690)

    let display = AVSampleBufferDisplayLayer()
    private var browser: NWBrowser?
    private var channel: RemoteChannel?
    private var salt = Data()
    private var streaming = false
    private var format: CMVideoFormatDescription?
    private var lastHeard = Date()
    private var timer: Timer?

    func start() {
        let browser = NWBrowser(for: .bonjour(type: RemoteWire.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case let .service(name, _, _, _) = result.endpoint, name != RemoteWire.localName { return name }
                return nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.sources = Array(Set(names)).sorted()
                // Debug aid: EDGEDECK_REMOTE_SHOW=<name> switches to that Source as soon as it's found.
                if self.current == nil, let wanted = ProcessInfo.processInfo.environment["EDGEDECK_REMOTE_SHOW"],
                   self.sources.contains(wanted) { self.show(wanted) }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
    }

    /// Shows `name`'s Dashboard on the Edge, Pairing first if needed.
    func show(_ name: String) {
        end()
        let channel = RemoteChannel(NWConnection(to: .service(name: name, type: RemoteWire.serviceType, domain: "local.", interface: nil), using: RemoteWire.parameters))
        self.channel = channel
        current = name
        lastHeard = Date()
        salt = RemoteChannel.randomBytes(16)
        channel.onMessage = { [weak self, weak channel] kind, payload in
            DispatchQueue.main.async { if let channel, self?.channel === channel { self?.received(kind, payload) } }
        }
        channel.onClose = { [weak self, weak channel] in
            guard let self, let channel, self.channel === channel else { return }
            self.lose(self.pairingCode != nil ? "Wrong code, or Pairing was cancelled on \(name)" : "\(name) went away")
        }
        channel.start()
        let secret = RemoteKeychain.secret(for: "source:" + name)
        var hello = Data([RemoteWire.version])
        hello.append(withUnsafeBytes(of: RemoteWire.localID.uuid) { Data($0) })
        hello.append(salt)
        hello.append(secret == nil ? 0 : 1)
        hello.append(UInt16(dashboardSize.width).bigEndianData)
        hello.append(UInt16(dashboardSize.height).bigEndianData)
        hello.append(Data(RemoteWire.localName.utf8))
        channel.send(.hello, hello)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Back to this Mac's own Dashboard.
    func end() {
        timer?.invalidate()
        timer = nil
        let channel = self.channel
        self.channel = nil
        channel?.close()
        streaming = false
        format = nil
        display.sampleBufferRenderer.flush(removingDisplayedImage: true) {}
        if pairingCode != nil { pairingCode = nil }
        if sourceEditing { sourceEditing = false }
        if current != nil { current = nil }
    }

    func sendTouch(_ phase: RemoteWire.TouchPhase, at point: CGPoint, clickCount: Int) {
        guard streaming else { return }
        var payload = Data([phase.rawValue, UInt8(clamping: clickCount)])
        payload.append(Float32(point.x).bitPattern.bigEndianData)
        payload.append(Float32(point.y).bitPattern.bigEndianData)
        channel?.send(.touch, payload)
    }

    private func tick() {
        if streaming {
            channel?.send(.ping)
            if Date().timeIntervalSince(lastHeard) > 2, let name = current { lose("\(name) went away") }
        } else if Date().timeIntervalSince(lastHeard) > (pairingCode != nil ? 120 : 5), let name = current {
            lose(pairingCode != nil ? "Pairing with \(name) timed out" : "Couldn't reach \(name)")
        }
    }

    private func lose(_ reason: String) {
        end()
        onProblem(reason)
    }

    private func received(_ kind: RemoteWire.Kind, _ payload: Data) {
        guard let channel, let name = current else { return }
        lastHeard = Date()
        switch kind {
        case .hello:
            guard payload.count >= 18, payload[payload.startIndex] == RemoteWire.version,
                  let status = RemoteWire.HelloStatus(rawValue: payload[payload.startIndex + 1]), status != .versionMismatch else {
                return lose("\(name) runs a different EdgeDeck version: update both Macs")
            }
            let sourceSalt = payload.subdata(in: payload.startIndex + 2 ..< payload.startIndex + 18)
            if status == .paired, let secret = RemoteKeychain.secret(for: "source:" + name) {
                beginStreaming(secret: secret, sourceSalt: sourceSalt)
            } else {
                // Pairing: the user types this code on the Source.
                let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
                let keys = RemoteChannel.keys(from: RemoteChannel.codeKey(code), hostSalt: salt, sourceSalt: sourceSalt)
                channel.seal(outgoing: keys.hostToSource, incoming: keys.sourceToHost)
                pairingCode = code
                self.sourceSalt = sourceSalt
            }
        case .codeTyped:
            // It opened with the code's key, so the right code was typed.
            let secret = SymmetricKey(size: .bits256)
            channel.send(.secret, secret.withUnsafeBytes { Data($0) })
            RemoteKeychain.store(secret, for: "source:" + name)
            pairingCode = nil
            beginStreaming(secret: secret, sourceSalt: sourceSalt)
        case .format:
            format = Self.formatDescription(payload)
        case .frame:
            if let format, let sample = Self.sampleBuffer(payload, format: format) { enqueue(sample) }
        case .state:
            sourceEditing = payload.first == 1
        default:
            break
        }
    }

    private var sourceSalt = Data()

    private func beginStreaming(secret: SymmetricKey, sourceSalt: Data) {
        let keys = RemoteChannel.keys(from: secret, hostSalt: salt, sourceSalt: sourceSalt)
        channel?.seal(outgoing: keys.hostToSource, incoming: keys.sourceToHost)
        channel?.send(.start)
        streaming = true
    }

    private func enqueue(_ sample: CMSampleBuffer) {
        let renderer = display.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    private static func formatDescription(_ payload: Data) -> CMVideoFormatDescription? {
        var sets: [Data] = []
        var offset = 0
        while offset + 2 <= payload.count {
            let length = Int(payload.readInteger(at: offset, as: UInt16.self))
            offset += 2
            guard offset + length <= payload.count else { return nil }
            sets.append(payload.subdata(in: payload.startIndex + offset ..< payload.startIndex + offset + length))
            offset += length
        }
        guard !sets.isEmpty else { return nil }
        var format: CMVideoFormatDescription?
        let pointers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { pointers.forEach { $0.deallocate() } }
        let status = pointers.map { UnsafePointer($0) }.withUnsafeBufferPointer { ptrs in
            sets.map(\.count).withUnsafeBufferPointer { sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                    parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: sizes.baseAddress!,
                                                                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    private static func sampleBuffer(_ payload: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}

/// The Host's panel during a Remote view: the Source's Dashboard, and over it the Pairing code
/// while Pairing. Touches on the Edge reach it as mouse events, like any EdgeDeck window, and go
/// on to the Source.
final class RemoteStreamView: NSView {
    private let host: RemoteHost

    init(host: RemoteHost) {
        self.host = host
        super.init(frame: .zero)
        layer = host.display
        wantsLayer = true
        let overlay = PassThroughHostingView(rootView: RemoteOverlay().environmentObject(host))
        overlay.passesThrough = { [weak host, weak self] point in
            guard let host, let self else { return true }
            if host.pairingCode != nil || host.chooserOpen { return false }
            // Only the Source pill, bottom right, is ours; the rest goes to the Source.
            return host.sourceEditing || !SourcePill.frame(in: self.bounds).contains(point)
        }
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { send(.down, event) }
    override func mouseDragged(with event: NSEvent) { send(.move, event) }
    override func mouseUp(with event: NSEvent) { send(.up, event) }

    private func send(_ phase: RemoteWire.TouchPhase, _ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // The video keeps its aspect ratio: map into the picture, top-left origin.
        let video = AVMakeRect(aspectRatio: host.dashboardSize, insideRect: bounds)
        let x = (p.x - video.minX) / video.width, y = (video.maxY - p.y) / video.height
        host.sendTouch(phase, at: CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)), clickCount: event.clickCount)
    }
}

/// Lets clicks through to the view below unless `passesThrough` says otherwise.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    /// Given the point in the superview's coordinates (bottom-left origin; this view is flipped).
    var passesThrough: (NSPoint) -> Bool = { _ in true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        passesThrough(point) ? nil : super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct RemoteOverlay: View {
    @EnvironmentObject var host: RemoteHost

    var body: some View {
        if let code = host.pairingCode, let name = host.current {
            ZStack {
                Theme.background.opacity(0.94)
                VStack(spacing: 18) {
                    Text("Pair with \(name)").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Type this code on \(name):").font(.system(size: 20, design: .rounded)).foregroundStyle(.secondary)
                    Text(code.prefix(3) + " " + code.suffix(3))
                        .font(.system(size: 76, weight: .heavy, design: .monospaced))
                        .tracking(6)
                    Button { host.end() } label: {
                        Text("Cancel").font(.system(size: 20, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 36).frame(height: 60)
                            .background(Theme.tileRaised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white)
            }
        } else if host.current != nil {
            ZStack {
                if !host.sourceEditing {
                    SourcePill().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                if host.chooserOpen { SourceChooser() }
            }
        }
    }
}

// MARK: - Source

/// The Source side: offers this Mac's Dashboard to Hosts and streams it while one is watching.
final class RemoteSource: ObservableObject {
    /// A Host started watching at this Dashboard size (nil = nobody watching). The app delegate
    /// places the Dashboard panel and returns it, for capture.
    var onWatch: (CGSize?) -> NSWindow? = { _ in nil }
    /// A Host wants to Pair: ask for the code shown on its Edge (nil = cancelled).
    var onPairRequest: (_ hostName: String, _ answer: @escaping (String?) -> Void) -> Void = { $1(nil) }

    private var listener: NWListener?
    private var channel: RemoteChannel?
    private var stream: SCStream?
    private var output: StreamOutput?
    private var encoder: VTCompressionSession?
    private weak var window: NSWindow?
    private var size = CGSize.zero
    private var hostID = ""
    private var hostSalt = Data()
    private var salt = Data()
    private var forceKeyFrame = true
    private var lastHeard = Date()
    private var timer: Timer?
    private var awake: IOPMAssertionID = 0
    private let stats = StreamStats()

    /// Whether a Host is watching (Takeovers are offered only when not).
    @Published private(set) var isWatched = false
    /// This Mac's Dashboard is in Edit mode; the Host is told while it watches.
    var editing = false {
        didSet { if editing != oldValue, window != nil { channel?.send(.state, Data([editing ? 1 : 0])) } }
    }

    func start() {
        do {
            let listener = try NWListener(using: RemoteWire.parameters)
            listener.service = NWListener.Service(name: RemoteWire.localName, type: RemoteWire.serviceType)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state { NSLog("EdgeDeck: Remote view listener failed: \(error)") }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("EdgeDeck: Remote view listener: \(error)")
        }
    }

    /// One Host at a time: a new one replaces the last.
    private func accept(_ connection: NWConnection) {
        stop()
        let channel = RemoteChannel(connection)
        self.channel = channel
        lastHeard = Date()
        channel.onMessage = { [weak self, weak channel] kind, payload in
            DispatchQueue.main.async { if let channel, self?.channel === channel { self?.received(kind, payload) } }
        }
        channel.onClose = { [weak self, weak channel] in
            if let channel, self?.channel === channel { self?.stop() }
        }
        channel.start()
    }

    private func received(_ kind: RemoteWire.Kind, _ payload: Data) {
        guard let channel else { return }
        lastHeard = Date()
        switch kind {
        case .hello:
            salt = RemoteChannel.randomBytes(16)
            guard payload.count >= 38, payload[payload.startIndex] == RemoteWire.version else {
                channel.send(.hello, Data([RemoteWire.version, RemoteWire.HelloStatus.versionMismatch.rawValue]) + salt)
                return
            }
            let id = payload.subdata(in: payload.startIndex + 1 ..< payload.startIndex + 17)
            hostID = UUID(uuid: id.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }).uuidString
            hostSalt = payload.subdata(in: payload.startIndex + 17 ..< payload.startIndex + 33)
            let hostHasSecret = payload[payload.startIndex + 33] == 1
            size = CGSize(width: Int(payload.readInteger(at: 34, as: UInt16.self)), height: Int(payload.readInteger(at: 36, as: UInt16.self)))
            let hostName = String(decoding: payload.dropFirst(38), as: UTF8.self)
            if hostHasSecret, let secret = RemoteKeychain.secret(for: "host:" + hostID) {
                channel.send(.hello, Data([RemoteWire.version, RemoteWire.HelloStatus.paired.rawValue]) + salt)
                seal(with: secret)
            } else {
                channel.send(.hello, Data([RemoteWire.version, RemoteWire.HelloStatus.needsCode.rawValue]) + salt)
                onPairRequest(hostName) { [weak self, weak channel] code in
                    guard let self, let channel, self.channel === channel else { return }
                    guard let code else { return self.stop() }
                    let keys = RemoteChannel.keys(from: RemoteChannel.codeKey(code), hostSalt: self.hostSalt, sourceSalt: self.salt)
                    channel.seal(outgoing: keys.sourceToHost, incoming: keys.hostToSource)
                    channel.send(.codeTyped)
                }
            }
        case .secret:
            // Arrived sealed with the code's key: Paired.
            guard payload.count == 32 else { return stop() }
            let secret = SymmetricKey(data: payload)
            RemoteKeychain.store(secret, for: "host:" + hostID)
            seal(with: secret)
        case .start:
            beginStreaming()
        case .touch:
            guard window != nil, payload.count >= 10, let phase = RemoteWire.TouchPhase(rawValue: payload[payload.startIndex]) else { return }
            let x = CGFloat(Float32(bitPattern: payload.readInteger(at: 2, as: UInt32.self)))
            let y = CGFloat(Float32(bitPattern: payload.readInteger(at: 6, as: UInt32.self)))
            touch(phase, x: x, y: y, clickCount: Int(payload[payload.startIndex + 1]))
        default:
            break
        }
    }

    private func seal(with secret: SymmetricKey) {
        let keys = RemoteChannel.keys(from: secret, hostSalt: hostSalt, sourceSalt: salt)
        channel?.seal(outgoing: keys.sourceToHost, incoming: keys.hostToSource)
    }

    private func beginStreaming() {
        guard window == nil else { return }
        guard let window = onWatch(size) else { return stop() }
        self.window = window
        isWatched = true
        channel?.send(.state, Data([editing ? 1 : 0]))
        // A sleeping display stops the capture, so keep it awake while watched.
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "EdgeDeck Remote view" as CFString, &awake)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        forceKeyFrame = true
        // Give the window server a moment to show the panel before looking for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            Task { await self?.startCapture(windowID: CGWindowID(window.windowNumber)) }
        }
    }

    private func tick() {
        channel?.send(.ping)
        if Date().timeIntervalSince(lastHeard) > 2 { stop() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        let channel = self.channel
        self.channel = nil
        channel?.close()
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        output = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        if awake != 0 { IOPMAssertionRelease(awake); awake = 0 }
        if window != nil { _ = onWatch(nil) }
        window = nil
        if isWatched { isWatched = false }
    }

    @MainActor
    private func startCapture(windowID: CGWindowID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard channel != nil, let target = content.windows.first(where: { $0.windowID == windowID }) else {
                NSLog("EdgeDeck: Remote view: Dashboard window not capturable")
                return stop()
            }
            let width = Int(size.width), height = Int(size.height)
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = false
            config.queueDepth = 3
            guard makeEncoder(width: width, height: height) else { return stop() }
            let output = StreamOutput { [weak self] buffer in self?.encode(buffer) }
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "EdgeDeck.remote.capture"))
            try await stream.startCapture()
            self.stream = stream
            self.output = output
        } catch {
            NSLog("EdgeDeck: Remote view capture failed: \(error)")
            stop()
        }
    }

    private func makeEncoder(width: Int, height: Int) -> Bool {
        var session: VTCompressionSession?
        // Low-latency rate control: no frames held back for look-ahead. Fall back if the Mac's encoder lacks it.
        for specification in [[kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary, nil] {
            let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                                                    encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                    outputCallback: nil, refcon: nil, compressionSessionOut: &session)
            if status == noErr { break }
            NSLog("EdgeDeck: Remote view encoder (low latency \(specification != nil)) failed: \(status)")
        }
        guard let session else { return false }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_AverageBitRate: 16_000_000,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 5,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
        ]
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        return true
    }

    /// On the capture queue.
    private func encode(_ buffer: CMSampleBuffer) {
        guard let encoder, let image = CMSampleBufferGetImageBuffer(buffer) else { return }
        var options: CFDictionary?
        if forceKeyFrame {
            forceKeyFrame = false
            options = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let started = CACurrentMediaTime()
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer),
                                        duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.send(sample)
            self?.stats.add(encode: CACurrentMediaTime() - started, bytes: CMSampleBufferGetTotalSampleSize(sample))
        }
    }

    private func send(_ sample: CMSampleBuffer) {
        guard let channel, let data = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if keyFrame {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            var sets = Data()
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var length = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard let pointer else { continue }
                sets.append(UInt16(length).bigEndianData)
                sets.append(pointer, count: length)
            }
            channel.send(.format, sets)
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        channel.send(.frame, Data(bytes: pointer, count: length))
    }

    /// A touch from the Host, as a mouse event for the Dashboard panel (the cursor never moves).
    private func touch(_ phase: RemoteWire.TouchPhase, x: CGFloat, y: CGFloat, clickCount: Int) {
        guard let window, let view = window.contentView else { return }
        // Window coordinates (bottom-left origin); the content view fills the window.
        let point = NSPoint(x: x * view.frame.width, y: (1 - y) * view.frame.height)
        let type: NSEvent.EventType = switch phase {
        case .down: .leftMouseDown
        case .move: .leftMouseDragged
        case .up: .leftMouseUp
        }
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: max(clickCount, 1),
                                             pressure: phase == .up ? 0 : 1) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}

private final class StreamOutput: NSObject, SCStreamOutput {
    let handle: (CMSampleBuffer) -> Void
    init(_ handle: @escaping (CMSampleBuffer) -> Void) { self.handle = handle }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        handle(buffer)
    }
}

// MARK: - Source pill

/// Bottom right of the Edge: which Mac's Dashboard is showing. Tap to choose another.
struct SourcePill: View {
    @EnvironmentObject var host: RemoteHost
    static let size = CGSize(width: 250, height: 68)

    /// Where it sits in a view of `bounds` (AppKit coordinates, bottom-left origin).
    static func frame(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.maxX - size.width, y: bounds.minY, width: size.width, height: size.height)
    }

    var body: some View {
        Button { host.chooserOpen = true } label: {
            Label(host.current ?? "This Mac", systemImage: host.current == nil ? "display" : "display.2")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(maxWidth: Self.size.width - 56)
                .fixedSize()
                .padding(.horizontal, 18)
                .frame(height: 48)
                .background(Theme.tileRaised.opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 8)
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .frame(width: Self.size.width, height: Self.size.height, alignment: .trailing)
    }
}

/// The Macs whose Dashboard the Edge can show: this one and every Source found.
struct SourceChooser: View {
    @EnvironmentObject var host: RemoteHost

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .contentShape(Rectangle())
                .onTapGesture { host.chooserOpen = false }
            VStack(spacing: 18) {
                Text("Show on the Edge").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                HStack(spacing: 16) {
                    choice(RemoteWire.localName + " (this Mac)", symbol: "display", selected: host.current == nil) { host.end() }
                    ForEach(host.sources, id: \.self) { name in
                        choice(name, symbol: "display.2", selected: host.current == name) { host.show(name) }
                    }
                }
            }
        }
    }

    private func choice(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            host.chooserOpen = false
            if !selected { action() }
        } label: {
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 40, weight: .semibold))
                Text(title).font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: 260, height: 160)
            .background(selected ? Color(hex: "#0A84FF").opacity(0.45) : Theme.tileRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.6 : 0.15), lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Debug aid: EDGEDECK_REMOTE_STATS=1 logs frames per second, encode time and bit rate every 2 s.
private final class StreamStats {
    private let enabled = ProcessInfo.processInfo.environment["EDGEDECK_REMOTE_STATS"] == "1"
    private let lock = NSLock()
    private var frames = 0, bytes = 0, encode = 0.0, since = CACurrentMediaTime()

    func add(encode seconds: Double, bytes size: Int) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        frames += 1; bytes += size; encode += seconds
        let elapsed = CACurrentMediaTime() - since
        guard elapsed >= 2 else { return }
        NSLog("EdgeDeck: Remote view stats: %.0f fps, encode %.1f ms, %.1f Mbit/s",
              Double(frames) / elapsed, encode / Double(frames) * 1000, Double(bytes) * 8 / elapsed / 1_000_000)
        frames = 0; bytes = 0; encode = 0; since = CACurrentMediaTime()
    }
}
