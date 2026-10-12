import AppKit
import Carbon.HIToolbox
import CryptoKit
import Network
import SwiftUI

// Grab the keyboard (see CONTEXT.md): while a Guest app is on the Edge, the Host can make a Paired
// Mac's keyboard type only on the Host, for when the user sits at that other Mac. The Host connects
// to the Paired Mac's keyboard service (RemoteWire.keyboardServiceType) with the same hello, Pairing
// secrets and sealing as Remote view; it never Pairs by itself. The Paired Mac then swallows its
// own keystrokes with an event tap and sends them over; the Host replays them into the Guest app.
// Both sides ping twice a second and release after 2 s of silence, and the Paired Mac's Take Back
// Keyboard shortcut always releases, so a dropped link can't leave a keyboard stuck.

// MARK: - Host: grabbing another Mac's keyboard

final class KeyboardGrabber: ObservableObject {
    /// Paired Macs offering their keyboard right now, by name.
    @Published private(set) var lenders: [String] = []
    /// The Mac whose keyboard types here (or is being grabbed).
    @Published private(set) var grabbed: String?
    /// Its keys are paused: a password field is in use over there.
    @Published private(set) var paused = false
    /// The other Mac is asking its user something (a password prompt) before lending.
    @Published private(set) var waiting = false
    /// The keyboard was released on its own (or couldn't be grabbed); the reason, for the Edge.
    var onProblem: (String) -> Void = { _ in }
    /// The keyboard now types here: bring the Guest app forward so the keys reach it.
    var onGrabbed: () -> Void = {}
    /// Runs before connecting: the app explains macOS's password prompt first when needed.
    var beforeConnect: (_ name: String, _ proceed: @escaping () -> Void) -> Void = { $1() }

    private var browser: NWBrowser?
    private var found: [String] = []
    private var channel: RemoteChannel?
    private var salt = Data()
    private var lastHeard = Date()
    private var timer: Timer?
    private let source = CGEventSource(stateID: .hidSystemState)
    /// The other Mac confirmed: its keys type here.
    private var lent = false

    func start() {
        let browser = NWBrowser(for: .bonjour(type: RemoteWire.keyboardServiceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case let .service(name, _, _, _) = result.endpoint, name != RemoteWire.localName { return name }
                return nil
            }
            DispatchQueue.main.async {
                self?.found = Array(Set(names)).sorted()
                self?.refreshLenders()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        // Pairing can happen at any time (from Remote view): look again now and then.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshLenders() }
    }

    private func refreshLenders() {
        let paired = found.filter { RemoteKeychain.has("source:" + $0) }
        if paired != lenders { lenders = paired }
    }

    func grab(_ name: String) {
        beforeConnect(name) { [weak self] in self?.connect(name) }
    }

    private func connect(_ name: String) {
        stop()
        let channel = RemoteChannel(NWConnection(to: .service(name: name, type: RemoteWire.keyboardServiceType, domain: "local.", interface: nil),
                                                 using: RemoteWire.parameters))
        self.channel = channel
        grabbed = name
        lastHeard = Date()
        salt = RemoteChannel.randomBytes(16)
        channel.onMessage = { [weak self, weak channel] kind, payload in
            DispatchQueue.main.async { if let channel, self?.channel === channel { self?.received(kind, payload) } }
        }
        channel.onClose = { [weak self, weak channel] in
            guard let self, let channel, self.channel === channel else { return }
            self.lose("Lost \(name): its keyboard is released")
        }
        channel.start()
        var hello = Data([RemoteWire.version])
        hello.append(withUnsafeBytes(of: RemoteWire.localID.uuid) { Data($0) })
        hello.append(salt)
        hello.append(RemoteKeychain.has("source:" + name) ? 1 : 0)
        hello.append(UInt16(0).bigEndianData)
        hello.append(UInt16(0).bigEndianData)
        hello.append(Data(RemoteWire.localName.utf8))
        channel.send(.hello, hello)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Hands the keyboard back. Quietly: the user asked, or the Guest app went.
    func release() {
        channel?.send(.release)
        stop()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        let channel = self.channel
        self.channel = nil
        channel?.close()
        if grabbed != nil { grabbed = nil }
        if paused { paused = false }
        lent = false
        readingSecret = false
        if waiting { waiting = false }
    }

    private func lose(_ reason: String) {
        stop()
        onProblem(reason)
    }

    private func tick() {
        channel?.send(.ping)
        guard !readingSecret, let name = grabbed else { return }
        if waiting, Date().timeIntervalSince(lastHeard) > 120 {
            lose("\(name) is still asking for a password: answer it there, then grab again")
        } else if !waiting, Date().timeIntervalSince(lastHeard) > 2 {
            lose(lent ? "Lost \(name): its keyboard is released"
                 : "Couldn't reach \(name): is EdgeDeck running there? If it's asking for a password, answer it and try again")
        }
    }

    /// Waiting for macOS's password prompt to read the Pairing secret: no timeout meanwhile.
    private var readingSecret = false

    private func received(_ kind: RemoteWire.Kind, _ payload: Data) {
        guard let channel, let name = grabbed else { return }
        lastHeard = Date()
        if kind != .ping, waiting != (kind == .waiting) { waiting = kind == .waiting }
        switch kind {
        case .hello:
            guard payload.count >= 18, payload[payload.startIndex] == RemoteWire.version,
                  let status = RemoteWire.HelloStatus(rawValue: payload[payload.startIndex + 1]), status != .versionMismatch else {
                return lose("\(name) runs a different EdgeDeck version: update both Macs")
            }
            guard status == .paired else {
                return lose("Pair with \(name) first: send the app back, tap the pill at the bottom right and choose \(name)")
            }
            let sourceSalt = payload.subdata(in: payload.startIndex + 2 ..< payload.startIndex + 18)
            // May show macOS's password prompt; pings keep the link alive meanwhile.
            readingSecret = true
            RemoteKeychain.read("source:" + name) { [weak self, weak channel] secret in
                guard let self, let channel, self.channel === channel else { return }
                self.readingSecret = false
                self.lastHeard = Date()
                guard let secret else {
                    RemoteKeychain.forget("source:" + name)
                    return self.lose("EdgeDeck couldn't use its Pairing with \(name): Pair again from the pill at the bottom right")
                }
                let keys = RemoteChannel.keys(from: secret, hostSalt: self.salt, sourceSalt: sourceSalt)
                channel.seal(outgoing: keys.hostToSource, incoming: keys.sourceToHost)
                channel.send(.grab)
            }
        case .lending:
            guard let status = payload.first.flatMap(RemoteWire.LendStatus.init(rawValue:)) else { return }
            switch status {
            case .lent, .paused:
                paused = status == .paused
                if !lent { lent = true; onGrabbed() }
            case .locked: lose("\(name) is locked")
            case .notAllowed: lose("\(name) doesn't allow grabbing its keyboard")
            case .noPermission: lose("EdgeDeck on \(name) needs the Accessibility permission")
            case .takenBack: lose("\(name) took its keyboard back")
            }
        case .key:
            replay(payload)
        case .release:
            lose("\(name) took its keyboard back")
        default:
            break
        }
    }

    /// One key from the other Mac, posted like a real one, to whatever app is in front (the Guest app).
    private func replay(_ payload: Data) {
        guard payload.count >= 8, let type = RemoteWire.KeyType(rawValue: payload[payload.startIndex]) else { return }
        let keyCode = payload.readInteger(at: 1, as: UInt16.self)
        let flags = CGEventFlags(rawValue: UInt64(payload.readInteger(at: 3, as: UInt32.self)))
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: type != .up) else { return }
        if type == .flagsChanged { event.type = .flagsChanged }
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: payload[payload.startIndex + 7] == 1 ? 1 : 0)
        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Paired Mac: lending this Mac's keyboard

/// A key combination: a key code and ⌘⌥⌃⇧.
struct KeyShortcut: Equatable {
    static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    /// ⌃⌥⌘K.
    static let standard = KeyShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option, .command], key: "K")

    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    /// The key's name as typed, e.g. "K".
    var key: String

    var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let pressed = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)).intersection(Self.modifierMask)
        return keyCode == self.keyCode && pressed == modifiers.intersection(Self.modifierMask)
    }

    /// From a key press, if it uses ⌘, ⌥ or ⌃ (a plain key would be lost to typing).
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.modifierMask)
        guard !modifiers.intersection([.command, .option, .control]).isEmpty,
              let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: modifiers, key: key)
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

final class KeyboardLender: ObservableObject {
    /// The Mac this keyboard types on right now.
    @Published private(set) var lentTo: String?
    /// A password field is in use here: macOS hides the keys, so nothing reaches the other Mac.
    @Published private(set) var paused = false
    /// Other Macs may grab this keyboard (Paired ones only).
    @Published var allowed: Bool = UserDefaults.standard.object(forKey: "keyboard.allowGrab") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(allowed, forKey: "keyboard.allowGrab")
            if !allowed, lentTo != nil { takeBack() }
        }
    }
    /// Before reading a Pairing secret: the app may explain macOS's password prompt, or offer to
    /// Pair again instead (`answer(true)`; Pairing itself happens in Remote view).
    var beforeReading: (_ hostName: String, _ answer: @escaping (_ pairAgain: Bool) -> Void) -> Void = { $1(false) }
    /// Always releases the keyboard, even while every other key goes to the other Mac.
    @Published var shortcut: KeyShortcut = KeyboardLender.savedShortcut() {
        didSet {
            let defaults = UserDefaults.standard
            defaults.set(Int(shortcut.keyCode), forKey: "keyboard.takeBack.keyCode")
            defaults.set(Int(shortcut.modifiers.rawValue), forKey: "keyboard.takeBack.modifiers")
            defaults.set(shortcut.key, forKey: "keyboard.takeBack.key")
        }
    }

    private var listener: NWListener?
    private var channel: RemoteChannel?
    private var hostID = ""
    private var hostName = ""
    private var hostSalt = Data()
    private var salt = Data()
    private var lastHeard = Date()
    private var timer: Timer?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Asking this Mac's user something before lending: the Host is told to wait.
    private var asking = false

    private static func savedShortcut() -> KeyShortcut {
        let defaults = UserDefaults.standard
        guard let key = defaults.string(forKey: "keyboard.takeBack.key") else { return .standard }
        return KeyShortcut(keyCode: UInt16(defaults.integer(forKey: "keyboard.takeBack.keyCode")),
                           modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "keyboard.takeBack.modifiers"))), key: key)
    }

    func start() {
        do {
            let listener = try NWListener(using: RemoteWire.parameters)
            listener.service = NWListener.Service(name: RemoteWire.localName, type: RemoteWire.keyboardServiceType)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state { NSLog("EdgeDeck: keyboard listener failed: \(error)") }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("EdgeDeck: keyboard listener: \(error)")
        }
    }

    /// The Take Back Keyboard shortcut, the menu bar, or switching grabbing off.
    func takeBack() {
        channel?.send(.lending, Data([RemoteWire.LendStatus.takenBack.rawValue]))
        stop()
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
        // Common modes: keeps pinging while a dialog (the explanation, macOS's prompt) is up.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
            hostName = String(decoding: payload.dropFirst(38), as: UTF8.self)
            // Pairing happens only in Remote view; unpaired Macs are just told so.
            let account = "host:" + hostID
            let notPaired = { channel.send(.hello, Data([RemoteWire.version, RemoteWire.HelloStatus.needsCode.rawValue]) + self.salt) }
            guard payload[payload.startIndex + 33] == 1, RemoteKeychain.has(account) else { return notPaired() }
            asking = RemoteKeychain.peek(account) == .needsPassword
            RemoteKeychain.explainFirst(account, hostName, beforeReading) { [weak self, weak channel] pairAgain in
                guard let self, let channel, self.channel === channel else { return }
                if pairAgain { self.asking = false; RemoteKeychain.forget(account); return notPaired() }
                RemoteKeychain.read(account) { [weak self, weak channel] secret in
                    guard let self, let channel, self.channel === channel else { return }
                    self.asking = false
                    guard let secret else { return notPaired() }
                    channel.send(.hello, Data([RemoteWire.version, RemoteWire.HelloStatus.paired.rawValue]) + self.salt)
                    let keys = RemoteChannel.keys(from: secret, hostSalt: self.hostSalt, sourceSalt: self.salt)
                    channel.seal(outgoing: keys.sourceToHost, incoming: keys.hostToSource)
                }
            }
        case .grab:
            guard allowed else { return refuse(.notAllowed) }
            guard !Self.screenLocked else { return refuse(.locked) }
            guard startTap() else { return refuse(.noPermission) }
            lentTo = hostName
            paused = IsSecureEventInputEnabled()
            channel.send(.lending, Data([(paused ? RemoteWire.LendStatus.paused : .lent).rawValue]))
        case .release:
            stop()
        default:
            break
        }
    }

    private func refuse(_ status: RemoteWire.LendStatus) {
        channel?.send(.lending, Data([status.rawValue]))
        stop()
    }

    private func tick() {
        channel?.send(asking ? .waiting : .ping)
        if Date().timeIntervalSince(lastHeard) > 2 { return stop() }
        guard lentTo != nil else { return }
        let secure = IsSecureEventInputEnabled()
        if secure != paused {
            paused = secure
            channel?.send(.lending, Data([(secure ? RemoteWire.LendStatus.paused : .lent).rawValue]))
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        stopTap()
        let channel = self.channel
        self.channel = nil
        channel?.close()
        if lentTo != nil { lentTo = nil }
        if paused { paused = false }
        asking = false
    }

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: Event tap

    private func startTap() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let lender = Unmanaged<KeyboardLender>.fromOpaque(refcon).takeUnretainedValue()
            return lender.handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// On the main thread. Every key goes to the other Mac and none stays here, except the
    /// Take Back Keyboard shortcut.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let channel, lentTo != nil else { return Unmanaged.passUnretained(event) }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown, shortcut.matches(keyCode: keyCode, flags: event.flags) {
            DispatchQueue.main.async { self.takeBack() }
            return nil
        }
        let kind: RemoteWire.KeyType = switch type {
        case .keyDown: .down
        case .keyUp: .up
        default: .flagsChanged
        }
        var payload = Data([kind.rawValue])
        payload.append(keyCode.bigEndianData)
        payload.append(UInt32(truncatingIfNeeded: event.flags.rawValue).bigEndianData)
        payload.append(event.getIntegerValueField(.keyboardEventAutorepeat) != 0 ? 1 : 0)
        payload.append(Data(count: 4))   // no characters: the Host replays key codes
        channel.send(.key, payload)
        return nil
    }
}

/// On the lending Mac's main screen while its keyboard types on another Mac.
struct KeyboardLentLabel: View {
    @ObservedObject var lender: KeyboardLender

    var body: some View {
        if let name = lender.lentTo {
            Label(lender.paused ? "Paused: a password field is active on this Mac"
                  : "Typing on \(name) · \(lender.shortcut.description) to take back",
                  systemImage: lender.paused ? "pause.circle.fill" : "keyboard")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background((lender.paused ? Color(hex: "#FF9F0A") : Color(hex: "#0A84FF")).opacity(0.92), in: Capsule())
                .shadow(color: .black.opacity(0.4), radius: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
