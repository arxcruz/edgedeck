import CryptoKit
import Foundation
import Network
import Security

// The connection between a Host and a Source (see RemoteView.swift): framed messages, encrypted
// once the two Macs are Paired.
//
// Pairing: the Host shows a 6-digit code on the Edge and the user types it on the Source. Both
// derive a key from the code and the connection's salts; the Source proves it has the code, and
// the Host sends a random secret under that key. Each Mac keeps the secret in its Keychain.
// Every later connection derives fresh keys from the secret and both sides' salts, and every
// message is sealed with ChaCha20-Poly1305 (so it's private and can't be forged or replayed).
// Someone recording the network during pairing could guess the code offline; acceptable on a
// home network.

enum RemoteWire {
    static let serviceType = "_edgedeck._tcp"
    static let version: UInt8 = 2

    enum Kind: UInt8 {
        /// Plain. Host → Source: `[version][host ID: 16][salt: 16][has secret: 1][width: 2][height: 2][name]`.
        /// Source → Host: `[version][status][salt: 16]`, see `HelloStatus`.
        case hello = 1
        /// Source → Host, sealed with the code's key: the user typed the code.
        case codeTyped
        /// Host → Source, sealed with the code's key: the 32-byte secret.
        case secret
        /// Host → Source, sealed: start streaming (proves the Host has the secret).
        case start
        /// Source → Host: the HEVC parameter sets, each `[length: 2][bytes]`.
        case format
        /// Source → Host: one encoded frame (length-prefixed NAL units).
        case frame
        /// Host → Source: `[phase][click count][x: Float32][y: Float32]`, position as a fraction of the Dashboard.
        case touch
        /// Either way, twice a second: the other side is still there.
        case ping
        /// Source → Host: `[editing]`, so the Host hides its Source pill over the Edit toolbar.
        case state
    }

    enum HelloStatus: UInt8 {
        case paired = 0
        case needsCode
        case versionMismatch
    }

    enum TouchPhase: UInt8 { case down, move, up }

    /// This Mac's name as other Macs see it. EDGEDECK_REMOTE_NAME overrides it (for running a
    /// second copy as a test Source on the same Mac).
    static var localName: String {
        ProcessInfo.processInfo.environment["EDGEDECK_REMOTE_NAME"] ?? Host.current().localizedName ?? "Mac"
    }

    /// TCP without Nagle's algorithm: a touch is a few bytes and must not wait to be batched.
    static var parameters: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// Identifies this Mac to Sources it's Paired with.
    static var localID: UUID {
        let key = "remote.hostID"
        if let saved = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) { return saved }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}

/// One Host–Source connection. Messages are `[length: 4][body]`; the body is `[kind][payload]`,
/// sealed once `seal(with:)` has been called.
final class RemoteChannel {
    var onMessage: (RemoteWire.Kind, Data) -> Void = { _, _ in }
    /// The connection failed, closed, or a message couldn't be opened.
    var onClose: () -> Void = {}

    private let connection: NWConnection
    private let lock = NSLock()
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        receive()
        connection.start(queue: .main)
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        connection.cancel()
        DispatchQueue.main.async { self.onClose() }
    }

    /// From now on, messages are sealed: `send` with `outgoing`, received ones opened with `incoming`.
    /// Counters restart, so each key's nonces are used once.
    func seal(outgoing: SymmetricKey, incoming: SymmetricKey) {
        lock.lock()
        sendKey = outgoing
        receiveKey = incoming
        sendCounter = 0
        receiveCounter = 0
        lock.unlock()
    }

    /// Thread-safe (frames are sent from the encoder's queue).
    func send(_ kind: RemoteWire.Kind, _ payload: Data = Data()) {
        var body = Data([kind.rawValue])
        body.append(payload)
        lock.lock()
        if let key = sendKey {
            guard let sealed = try? ChaChaPoly.seal(body, using: key, nonce: Self.nonce(sendCounter)).combined else { lock.unlock(); return }
            sendCounter += 1
            body = sealed
        }
        var message = UInt32(body.count).bigEndianData
        message.append(body)
        // Under the lock, so sealed messages leave in counter order.
        connection.send(content: message, completion: .contentProcessed { _ in })
        lock.unlock()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self, error == nil, let header, header.count == 4 else { self?.close(); return }
            let length = Int(header.readInteger(at: 0, as: UInt32.self))
            guard length > 0, length < 64 << 20 else { return self.close() }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                guard let self, error == nil, let body, body.count == length else { self?.close(); return }
                guard let opened = self.open(body), let kind = opened.first.flatMap(RemoteWire.Kind.init(rawValue:)) else {
                    return self.close()
                }
                self.onMessage(kind, opened.dropFirst())
                self.receive()
            }
        }
    }

    private func open(_ body: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = receiveKey else { return body }
        guard let box = try? ChaChaPoly.SealedBox(combined: body),
              box.nonce.withUnsafeBytes({ Data($0) }) == Self.nonce(receiveCounter).withUnsafeBytes({ Data($0) }),
              let opened = try? ChaChaPoly.open(box, using: key) else { return nil }
        receiveCounter += 1
        return opened
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + counter.bigEndianData)
    }

    // MARK: Keys

    /// Keys for one connection: one per direction, from the secret (or the code) and both salts.
    static func keys(from material: SymmetricKey, hostSalt: Data, sourceSalt: Data) -> (hostToSource: SymmetricKey, sourceToHost: SymmetricKey) {
        let salt = hostSalt + sourceSalt
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: Data(info.utf8), outputByteCount: 32)
        }
        return (derive("EdgeDeck host to source"), derive("EdgeDeck source to host"))
    }

    static func codeKey(_ code: String) -> SymmetricKey {
        SymmetricKey(data: Data(("EdgeDeck pairing " + code).utf8))
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }
}

/// The Pairing secrets, in the Keychain: "source:<name>" on a Host, "host:<id>" on a Source.
enum RemoteKeychain {
    private static let service = "EdgeDeck Remote view"

    static func secret(for account: String) -> SymmetricKey? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    static func store(_ secret: SymmetricKey, for account: String) {
        forget(account)
        let data = secret.withUnsafeBytes { Data($0) }
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: account, kSecValueData: data,
                                     kSecAttrLabel: "EdgeDeck Remote view (\(account))"]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func forget(_ account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
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
