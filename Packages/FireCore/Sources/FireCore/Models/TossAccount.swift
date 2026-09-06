import Foundation

/// One row of `GET /api/v1/accounts`.
///
/// ```json
/// { "accountNo": "1300*******", "accountSeq": 1, "accountType": "BROKERAGE" }
/// ```
///
/// `accountSeq` is what feeds the `X-Tossinvest-Account` header on every per-account request.
public struct TossAccount: Codable, Hashable, Sendable, Identifiable {

    public let accountNo: String
    public let accountSeq: Int
    public let accountType: AccountType

    public init(accountNo: String, accountSeq: Int, accountType: AccountType) {
        self.accountNo = accountNo
        self.accountSeq = accountSeq
        self.accountType = accountType
    }

    public var id: Int { accountSeq }

    /// `"13001057376"` -> `"1300*******"`. The only form of the number the UI ever shows.
    ///
    /// Idempotent: an already-masked number from the API masks to itself. Numbers of four digits or
    /// fewer are left alone — there is nothing left to hide once the visible prefix is removed.
    public var maskedAccountNo: String {
        let visiblePrefixLength = 4
        guard accountNo.count > visiblePrefixLength else { return accountNo }
        let prefix = accountNo.prefix(visiblePrefixLength)
        return prefix + String(repeating: "*", count: accountNo.count - visiblePrefixLength)
    }
}
