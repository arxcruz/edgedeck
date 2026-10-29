import Foundation

/// Why a connection to another Mac never got going, from the system error (errno) it reported.
/// Discovery uses multicast and can work while the connection itself is blocked, so the Edge says which.
public enum ConnectFailure: Equatable, Sendable {
    /// No route to the Mac: Wi-Fi that keeps devices apart, another network, or a VPN in the way.
    case unreachable
    /// The Mac answered and said no: EdgeDeck isn't listening, or a firewall rejects it.
    case refused
    /// Nothing came back: usually a firewall dropping the connection.
    case timedOut
    case other

    public init(errno code: Int32) {
        switch code {
        case EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN: self = .unreachable
        case ECONNREFUSED: self = .refused
        case ETIMEDOUT: self = .timedOut
        default: self = .other
        }
    }

    /// What to tell the user about the Mac `name`. Nil for errors with nothing useful to add.
    public func message(for name: String) -> String? {
        switch self {
        case .unreachable:
            "Can't connect to \(name) over the network. Wi-Fi may keep devices apart, or a VPN or firewall on either Mac is in the way"
        case .refused:
            "\(name) refused the connection: is EdgeDeck running there, and does its firewall allow it?"
        case .timedOut:
            "\(name) didn't answer: a firewall or VPN may be blocking the connection"
        case .other:
            nil
        }
    }
}
