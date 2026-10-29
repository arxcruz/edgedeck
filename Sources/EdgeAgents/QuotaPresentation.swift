import Foundation

/// How the AI Agents widget shows quotas: with the sessions, on separate buttons, or on the back of a flip.
public enum AIQuotaPresentation: String, Codable, Hashable, Sendable {
    case inline
    case split
    case tapToFlip

    /// An unknown value falls back to `inline`; `"flip"`, an earlier name for the separate buttons, is `split`.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "flip" ? .split : (AIQuotaPresentation(rawValue: value) ?? .inline)
    }
}
