import Foundation

/// The two currencies this app deals with. The API splits every holding by trading currency
/// (`docs/api-notes.md` § holdings) and takes these as `baseCurrency` / `quoteCurrency` query values.
public enum Currency: String, Codable, Sendable, CaseIterable, Hashable {
    case krw = "KRW"
    case usd = "USD"

    /// Decodes case-insensitively so a `"usd"` from anywhere still lands on `.usd`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Currency(rawValue: raw.uppercased()) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unsupported currency."
                )
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
