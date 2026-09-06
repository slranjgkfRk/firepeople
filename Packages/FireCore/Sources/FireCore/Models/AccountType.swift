import Foundation

/// The account kind reported by `GET /api/v1/accounts`.
///
/// String-backed rather than an `enum` on purpose: `docs/api-notes.md` requires that an enum value
/// the server adds later decodes instead of throwing, which would otherwise fail the whole account
/// list and lock the user out of onboarding.
public struct AccountType: RawRepresentable, Codable, Hashable, Sendable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    /// 종합매매 — the only type the live API returns today.
    public static let brokerage = AccountType(rawValue: "BROKERAGE")
    /// 해외파생
    public static let overseasDerivatives = AccountType(rawValue: "OVERSEAS_DERIVATIVES")
    /// 연금저축
    public static let pensionSavings = AccountType(rawValue: "PENSION_SAVINGS")
    /// RIA (Reshoring Investment Account)
    public static let reshoringInvestment = AccountType(rawValue: "RESHORING_INVESTMENT")

    /// Korean label for the account-selection rows. An unknown type falls back to its raw value so
    /// the user still sees something identifiable rather than an empty cell.
    public var displayNameKo: String {
        switch self {
        case .brokerage: return "종합매매"
        case .overseasDerivatives: return "해외파생"
        case .pensionSavings: return "연금저축"
        case .reshoringInvestment: return "RIA"
        default: return rawValue
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
