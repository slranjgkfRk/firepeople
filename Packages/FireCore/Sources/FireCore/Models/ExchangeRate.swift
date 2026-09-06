import Foundation

/// `GET /api/v1/exchange-rate` — the reference rate used to convert the USD bucket of a holdings
/// response into won.
///
/// ```json
/// { "result": { "baseCurrency": "USD", "quoteCurrency": "KRW", "rate": "1353.1",
///               "validUntil": "2026-09-06T17:51:58.000+09:00" } }
/// ```
///
/// Only `rate` is used for the total; `validUntil` is informational (the rate refreshes about once a
/// minute) and is stored with the snapshot so the widget can re-render offline.
public struct ExchangeRate: Codable, Hashable, Sendable {

    public let baseCurrency: Currency
    public let quoteCurrency: Currency
    public let rate: Decimal
    /// `nil` when the field is absent or in a format we cannot read — never a reason to fail a refresh.
    public let validUntil: Date?

    public init(baseCurrency: Currency, quoteCurrency: Currency, rate: Decimal, validUntil: Date?) {
        self.baseCurrency = baseCurrency
        self.quoteCurrency = quoteCurrency
        self.rate = rate
        self.validUntil = validUntil
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case baseCurrency
        case quoteCurrency
        case rate
        case validUntil
    }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        // Same tolerance as `HoldingsOverview`: accept the unwrapped `result` object or the envelope.
        let container: KeyedDecodingContainer<CodingKeys>
        if root.contains(.result),
           let nested = try? root.nestedContainer(keyedBy: CodingKeys.self, forKey: .result) {
            container = nested
        } else {
            container = root
        }

        baseCurrency = try container.decode(Currency.self, forKey: .baseCurrency)
        quoteCurrency = try container.decode(Currency.self, forKey: .quoteCurrency)
        rate = try container.decodeDecimal(forKey: .rate)

        if let raw = try container.decodeIfPresent(String.self, forKey: .validUntil) {
            validUntil = DateParsing.date(from: raw)
        } else {
            validUntil = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseCurrency, forKey: .baseCurrency)
        try container.encode(quoteCurrency, forKey: .quoteCurrency)
        try container.encodeDecimalString(rate, forKey: .rate)
        if let validUntil {
            try container.encode(DateParsing.string(from: validUntil), forKey: .validUntil)
        } else {
            try container.encodeNil(forKey: .validUntil)
        }
    }

    /// The API stamps these with fractional seconds and a `+09:00` offset
    /// (`"2026-09-06T17:51:58.000+09:00"`). Formatters are built per call rather than cached: they
    /// are reference types, this runs at most twice per refresh, and it keeps the type `Sendable`
    /// without an unchecked escape hatch.
    private enum DateParsing {
        static func date(from string: String) -> Date? {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: string) { return date }

            let withoutFraction = ISO8601DateFormatter()
            withoutFraction.formatOptions = [.withInternetDateTime]
            return withoutFraction.date(from: string)
        }

        static func string(from date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }
    }
}
