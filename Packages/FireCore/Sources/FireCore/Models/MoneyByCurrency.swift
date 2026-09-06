import Foundation

/// An amount split by trading currency, as the holdings endpoint reports it:
///
/// ```json
/// { "krw": "38585", "usd": "22417.561095" }
/// ```
///
/// A bucket is `null` when nothing is held in that currency; on input `null` and `0` both mean zero.
/// Both sides are `Decimal` — USD sums carry six decimal places and must never round through `Double`.
public struct MoneyByCurrency: Codable, Hashable, Sendable {

    public let krw: Decimal
    public let usd: Decimal

    public init(krw: Decimal, usd: Decimal) {
        self.krw = krw
        self.usd = usd
    }

    /// `krw + usd × usdKrwRate`, rounded half-up to a whole won.
    ///
    /// The API performs no FX conversion of its own (`docs/api-notes.md` corrects README §3.3), so
    /// this is the single place the two buckets become the one number the app renders. Verified
    /// against the recorded response: `38585 + 22417.561095 × 1353.1` == `30_371_787`.
    public func totalKRW(usdKrwRate: Decimal) -> Int {
        var exact = krw + usd * usdKrwRate
        var rounded = Decimal()
        // `.plain` is round-half-away-from-zero, i.e. half-up for the non-negative amounts we see.
        NSDecimalRound(&rounded, &exact, 0, .plain)
        return Self.clampedInt(rounded)
    }

    /// `NSDecimalNumber.intValue` is undefined past `Int64`, so saturate instead of trapping on a
    /// number no portfolio will ever reach.
    private static func clampedInt(_ value: Decimal) -> Int {
        if value >= Decimal(Int.max) { return .max }
        if value <= Decimal(Int.min) { return .min }
        return NSDecimalNumber(decimal: value).intValue
    }

    private enum CodingKeys: String, CodingKey {
        case krw
        case usd
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        krw = try container.decodeDecimalIfPresent(forKey: .krw) ?? 0
        usd = try container.decodeDecimalIfPresent(forKey: .usd) ?? 0
    }

    /// Written back as decimal strings, matching the wire format and keeping the value exact through
    /// any JSON coder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeDecimalString(krw, forKey: .krw)
        try container.encodeDecimalString(usd, forKey: .usd)
    }
}
