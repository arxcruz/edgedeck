import AppKit
import AVFoundation
import CoreMedia
import IOKit.pwr_mgt
import Network
import ScreenCaptureKit
import VideoToolbox

// Remote view: the Edge shows another Mac's Dashboard. The Host (the Mac the Edge is plugged
// into) connects to the Source, which draws its Dashboard in its usual panel (hidden behind the
// wallpaper when it has no Edge) and streams it as HEVC video; the Host sends touches back as
// mouse events for that panel. Pixels, not Widget data: see docs/adr/0001.

/// The messages between Host and Source: `[kind: 1 byte][length: 4 bytes, big-endian][payload]`.
enum RemoteWire {
    static let serviceType = "_edgedeck._tcp"
    static let version: UInt8 = 1

    enum Kind: UInt8 {
        /// Host → Source: version, Dashboard width and height (points). Source → Host: version.
        case hello = 1
        /// Source → Host: the HEVC parameter sets, each `[length: 2][bytes]`.
        case format
        /// Source → Host: one encoded frame (length-prefixed NAL units).
        case frame
        /// Host → Source: `[phase][click count][x: Float32][y: Float32]`, position as a fraction of the Dashboard.
        case touch
        /// Either way, twice a second: the other side is still there.
        case ping
    }

    enum TouchPhase: UInt8 { case down, move, up }

    static func message(_ kind: Kind, _ payload: Data = Data()) -> Data {
        var data = Data([kind.rawValue])
        data.append(UInt32(payload.count).bigEndianData)
        data.append(payload)
        return data
    }

    /// Reads messages off `connection` one at a time, until it fails or closes.
    static func receive(on connection: NWConnection, _ handle: @escaping (Kind, Data) -> Void) {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { header, _, _, error in
            guard error == nil, let header, header.count == 5 else { return }
            let kind = Kind(rawValue: header[header.startIndex])
            let length = Int(header.dropFirst().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let next = { (payload: Data) in
                if let kind { handle(kind, payload) }
                receive(on: connection, handle)
            }
            if length == 0 { return next(Data()) }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { payload, _, _, error in
                guard error == nil, let payload, payload.count == length else { return }
                next(payload)
            }
        }
    }

    /// This Mac's name as other Macs see it. EDGEDECK_REMOTE_NAME overrides it (for running a
    /// second copy as a test Source on the same Mac).
    static var localName: String {
        ProcessInfo.processInfo.environment["EDGEDECK_REMOTE_NAME"] ?? Host.current().localizedName ?? "Mac"
    }
}

extension FixedWidthInteger {
    var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}

extension Data {
    func readInteger<T: FixedWidthInteger>(at offset: Int, as: T.Type = T.self) -> T {
        var value = T.zero
        for i in 0..<MemoryLayout<T>.size { value = value << 8 | T(self[startIndex + offset + i]) }
        return value
    }
}

// MARK: - Host

/// The Host side: finds Sources on the network and shows the chosen one's Dashboard.
final class RemoteHost: ObservableObject {
    /// Sources found on the network (other Macs running EdgeDeck), by name.
    @Published private(set) var sources: [String] = []
    /// The Source on the Edge; nil = this Mac's own Dashboard.
    @Published private(set) var current: String?
    /// Set when a Remote view ends on its own (the Source went away), for a Toast.
    var onLost: (String) -> Void = { _ in }
    /// The Dashboard size the Source should draw at.
    var dashboardSize = CGSize(width: 2560, height: 690)

    let display = AVSampleBufferDisplayLayer()
    private var browser: NWBrowser?
    private var connection: NWConnection?
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

    /// Shows `name`'s Dashboard on the Edge.
    func show(_ name: String) {
        end()
        let connection = NWConnection(to: .service(name: name, type: RemoteWire.serviceType, domain: "local.", interface: nil), using: .tcp)
        self.connection = connection
        current = name
        lastHeard = Date()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state { DispatchQueue.main.async { if self?.connection === connection { self?.lose() } } }
        }
        RemoteWire.receive(on: connection) { [weak self] kind, payload in
            DispatchQueue.main.async { self?.received(kind, payload, from: connection) }
        }
        connection.start(queue: .main)
        var hello = Data([RemoteWire.version])
        hello.append(UInt16(dashboardSize.width).bigEndianData)
        hello.append(UInt16(dashboardSize.height).bigEndianData)
        connection.send(content: RemoteWire.message(.hello, hello), completion: .contentProcessed { _ in })
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Back to this Mac's own Dashboard.
    func end() {
        timer?.invalidate()
        timer = nil
        connection?.cancel()
        connection = nil
        format = nil
        display.sampleBufferRenderer.flush(removingDisplayedImage: true) {}
        if current != nil { current = nil }
    }

    func sendTouch(_ phase: RemoteWire.TouchPhase, at point: CGPoint, clickCount: Int) {
        var payload = Data([phase.rawValue, UInt8(clamping: clickCount)])
        payload.append(Float32(point.x).bitPattern.bigEndianData)
        payload.append(Float32(point.y).bitPattern.bigEndianData)
        connection?.send(content: RemoteWire.message(.touch, payload), completion: .contentProcessed { _ in })
    }

    private func tick() {
        connection?.send(content: RemoteWire.message(.ping), completion: .contentProcessed { _ in })
        if Date().timeIntervalSince(lastHeard) > 2 { lose() }
    }

    private func lose() {
        guard let name = current else { return }
        end()
        onLost(name)
    }

    private func received(_ kind: RemoteWire.Kind, _ payload: Data, from connection: NWConnection) {
        guard connection === self.connection else { return }
        lastHeard = Date()
        switch kind {
        case .format:
            if format == nil { NSLog("EdgeDeck: Remote view: first key frame from \(current ?? "?")") }
            format = Self.formatDescription(payload)
        case .frame: if let format, let sample = Self.sampleBuffer(payload, format: format) { enqueue(sample) }
        default: break
        }
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

/// Shows the Source's Dashboard on the Host and sends touches on it back to the Source.
/// Touches on the Edge reach it as mouse events, like any EdgeDeck window.
final class RemoteStreamView: NSView {
    private let host: RemoteHost

    init(host: RemoteHost) {
        self.host = host
        super.init(frame: .zero)
        layer = host.display
        wantsLayer = true
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

// MARK: - Source

/// The Source side: offers this Mac's Dashboard to Hosts and streams it while one is watching.
final class RemoteSource {
    /// A Host started watching at this Dashboard size (nil = nobody watching). The app delegate
    /// places the Dashboard panel and returns it, for capture.
    var onWatch: (CGSize?) -> NSWindow? = { _ in nil }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var stream: SCStream?
    private var output: StreamOutput?
    private var encoder: VTCompressionSession?
    private weak var window: NSWindow?
    private var size = CGSize.zero
    private var forceKeyFrame = true
    private var lastHeard = Date()
    private var timer: Timer?
    private var awake: IOPMAssertionID = 0

    func start() {
        do {
            let listener = try NWListener(using: .tcp)
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
        self.connection = connection
        lastHeard = Date()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled: DispatchQueue.main.async { if self?.connection === connection { self?.stop() } }
            default: break
            }
        }
        RemoteWire.receive(on: connection) { [weak self] kind, payload in
            DispatchQueue.main.async { self?.received(kind, payload, from: connection) }
        }
        connection.start(queue: .main)
    }

    private func received(_ kind: RemoteWire.Kind, _ payload: Data, from connection: NWConnection) {
        guard connection === self.connection else { return }
        lastHeard = Date()
        switch kind {
        case .hello:
            guard payload.count >= 5, payload[payload.startIndex] == RemoteWire.version else { return stop() }
            size = CGSize(width: Int(payload.readInteger(at: 1, as: UInt16.self)), height: Int(payload.readInteger(at: 3, as: UInt16.self)))
            connection.send(content: RemoteWire.message(.hello, Data([RemoteWire.version])), completion: .contentProcessed { _ in })
            beginStreaming()
        case .touch:
            guard payload.count >= 10, let phase = RemoteWire.TouchPhase(rawValue: payload[payload.startIndex]) else { return }
            let x = CGFloat(Float32(bitPattern: payload.readInteger(at: 2, as: UInt32.self)))
            let y = CGFloat(Float32(bitPattern: payload.readInteger(at: 6, as: UInt32.self)))
            touch(phase, x: x, y: y, clickCount: Int(payload[payload.startIndex + 1]))
        default: break
        }
    }

    private func beginStreaming() {
        guard let window = onWatch(size) else { return stop() }
        self.window = window
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
        connection?.send(content: RemoteWire.message(.ping), completion: .contentProcessed { _ in })
        if Date().timeIntervalSince(lastHeard) > 2 { stop() }
        // Nothing changing means no new frames; a key frame now and then lets a Host recover from a glitch.
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        connection?.cancel()
        connection = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        output = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        if awake != 0 { IOPMAssertionRelease(awake); awake = 0 }
        if window != nil { _ = onWatch(nil) }
        window = nil
    }

    @MainActor
    private func startCapture(windowID: CGWindowID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard connection != nil, let target = content.windows.first(where: { $0.windowID == windowID }) else {
                NSLog("EdgeDeck: Remote view: Dashboard window not capturable")
                return stop()
            }
            let width = Int(size.width), height = Int(size.height)
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = false
            config.queueDepth = 4
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
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { return false }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
            kVTCompressionPropertyKey_AverageBitRate: 12_000_000,
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
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer),
                                        duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.send(sample)
        }
    }

    private func send(_ sample: CMSampleBuffer) {
        guard let connection, let data = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
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
            connection.send(content: RemoteWire.message(.format, sets), completion: .contentProcessed { _ in })
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let bytes = Data(bytes: pointer, count: length)
        connection.send(content: RemoteWire.message(.frame, bytes), completion: .contentProcessed { _ in })
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
