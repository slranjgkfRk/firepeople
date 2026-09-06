import Foundation

/// The parts of `GET /api/v1/holdings` this app uses — the portfolio totals, nothing per-ticker.
///
/// Wire shape (`Fixtures/holdings.json`):
///
/// ```json
/// { "result": {
///     "totalPurchaseAmount": { "krw": "38115", "usd": "20821.471188" },
///     "marketValue": {
///       "amount":          { "krw": "38585", "usd": "22417.561095" },
///       "amountAfterCost": { "krw": "38580", "usd": "22375.101095" } },
///     "items": [ … ] } }
/// ```
///
/// The app's `currentAssets` comes from `marketValue` (pre-cost), which is what the Toss app shows
/// as 평가금액. `marketValueAfterCost` is carried for completeness and is not rendered anywhere.
public struct HoldingsOverview: Codable, Hashable, Sendable {

    public let totalPurchaseAmount: MoneyByCurrency
    /// `result.marketValue.amount`
    public let marketValue: MoneyByCurrency
    /// `result.marketValue.amountAfterCost`
    public let marketValueAfterCost: MoneyByCurrency
    /// `result.items.count` — how many positions the account holds. The items themselves are not kept.
    public let itemCount: Int

    public init(
        totalPurchaseAmount: MoneyByCurrency,
        marketValue: MoneyByCurrency,
        marketValueAfterCost: MoneyByCurrency,
        itemCount: Int
    ) {
        self.totalPurchaseAmount = totalPurchaseAmount
        self.marketValue = marketValue
        self.marketValueAfterCost = marketValueAfterCost
        self.itemCount = itemCount
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case totalPurchaseAmount
        case marketValue
        case items
        case itemCount
    }

    private enum MarketValueKeys: String, CodingKey {
        case amount
        case amountAfterCost
    }

    /// Decodes an item without keeping any of it — only the count matters here.
    private struct IgnoredItem: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        // Accepts either the unwrapped `result` object (what `TossClient` hands over) or the whole
        // response envelope (what a test decoding the raw fixture hands over).
        let container: KeyedDecodingContainer<CodingKeys>
        if root.contains(.result),
           let nested = try? root.nestedContainer(keyedBy: CodingKeys.self, forKey: .result) {
            container = nested
        } else {
            container = root
        }

        totalPurchaseAmount = try container.decodeIfPresent(MoneyByCurrency.self, forKey: .totalPurchaseAmount)
            ?? MoneyByCurrency(krw: 0, usd: 0)

        let marketValueContainer = try container.nestedContainer(
            keyedBy: MarketValueKeys.self,
            forKey: .marketValue
        )
        let amount = try marketValueContainer.decode(MoneyByCurrency.self, forKey: .amount)
        marketValue = amount
        marketValueAfterCost = try marketValueContainer.decodeIfPresent(
            MoneyByCurrency.self,
            forKey: .amountAfterCost
        ) ?? amount

        if let items = try container.decodeIfPresent([IgnoredItem].self, forKey: .items) {
            itemCount = items.count
        } else {
            // Re-decoding something this type encoded itself, which stores the count directly.
            itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalPurchaseAmount, forKey: .totalPurchaseAmount)
        var marketValueContainer = container.nestedContainer(
            keyedBy: MarketValueKeys.self,
            forKey: .marketValue
        )
        try marketValueContainer.encode(marketValue, forKey: .amount)
        try marketValueContainer.encode(marketValueAfterCost, forKey: .amountAfterCost)
        try container.encode(itemCount, forKey: .itemCount)
    }
}
