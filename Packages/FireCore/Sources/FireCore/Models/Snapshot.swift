import Foundation

/// How the last refresh went. Drives the banner in README §2.6.
public enum FetchStatus: String, Codable, Sendable, Hashable {
    /// The numbers are from a successful fetch.
    case ok
    /// Network or server failure — the previous numbers are being shown.
    case staleNetwork
    /// 401 that survived a token re-issue: "API 키를 확인해주세요".
    case authFailed
    /// 403 — the caller's IP is not on the WTS allow-list.
    case ipBlocked
}

/// The result of one refresh, persisted to the App Group container. Every screen and every widget
/// renders from this plus `Settings`; nothing else calls the API (README §4.1).
public struct Snapshot: Codable, Sendable, Equatable {

    /// Won, already FX-converted. The number the whole app renders.
    public var currentAssets: Int

    /// `accountSeq` -> that account's KRW-converted 평가금액.
    public var perAccount: [Int: Int]

    /// Summed `marketValue.amount.krw` across the selected accounts, unconverted.
    public var krwAmount: Decimal

    /// Summed `marketValue.amount.usd` across the selected accounts, unconverted.
    public var usdAmount: Decimal

    /// The USD->KRW rate used for `currentAssets`. Kept so the widget can explain an offline number.
    public var usdKrwRate: Decimal

    /// Cash buying power folded into `currentAssets`; `nil` unless `Settings.includeCash` was on.
    public var cashKRW: Int?

    /// When the numbers were actually fetched. A failed refresh keeps the previous value — README
    /// §2.6 shows "마지막 갱신" of the last *successful* fetch.
    public var fetchedAt: Date

    public var status: FetchStatus

    public init(
        currentAssets: Int,
        perAccount: [Int: Int],
        krwAmount: Decimal,
        usdAmount: Decimal,
        usdKrwRate: Decimal,
        cashKRW: Int?,
        fetchedAt: Date,
        status: FetchStatus
    ) {
        self.currentAssets = currentAssets
        self.perAccount = perAccount
        self.krwAmount = krwAmount
        self.usdAmount = usdAmount
        self.usdKrwRate = usdKrwRate
        self.cashKRW = cashKRW
        self.fetchedAt = fetchedAt
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case currentAssets
        case perAccount
        case krwAmount
        case usdAmount
        case usdKrwRate
        case cashKRW
        case fetchedAt
        case status
    }

    /// Hand-written for two reasons: the `Decimal` amounts are stored as strings so they survive any
    /// JSON coder exactly, and a payload from an older build decodes with defaults rather than
    /// throwing away the user's last known numbers.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentAssets = try container.decodeIfPresent(Int.self, forKey: .currentAssets) ?? 0
        perAccount = try container.decodeIfPresent([Int: Int].self, forKey: .perAccount) ?? [:]
        krwAmount = try container.decodeDecimalIfPresent(forKey: .krwAmount) ?? 0
        usdAmount = try container.decodeDecimalIfPresent(forKey: .usdAmount) ?? 0
        usdKrwRate = try container.decodeDecimalIfPresent(forKey: .usdKrwRate) ?? 0
        cashKRW = try container.decodeIfPresent(Int.self, forKey: .cashKRW)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        let storedStatus = try container.decodeIfPresent(String.self, forKey: .status)
        status = storedStatus.flatMap(FetchStatus.init(rawValue:)) ?? .ok
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentAssets, forKey: .currentAssets)
        try container.encode(perAccount, forKey: .perAccount)
        try container.encodeDecimalString(krwAmount, forKey: .krwAmount)
        try container.encodeDecimalString(usdAmount, forKey: .usdAmount)
        try container.encodeDecimalString(usdKrwRate, forKey: .usdKrwRate)
        try container.encodeIfPresent(cashKRW, forKey: .cashKRW)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(status.rawValue, forKey: .status)
    }
}
