//
//  ModelDecodingTests.swift
//  FireCoreTests
//
//  Every file in `Fixtures/` is a real response recorded from the live API on 2026-09-06
//  (docs/api-notes.md). This suite decodes each of them into the model that consumes it and asserts
//  the real values.
//
//  Every money assertion compares against `Decimal(string:)`, never against a `Double` literal, so
//  a model that routed a value through binary floating point fails here instead of silently losing
//  won. `22417.561095` is not representable as a `Double`.
//

import XCTest
import FireCore

final class ModelDecodingTests: XCTestCase {

    // Recorded values, docs/api-notes.md § "Live verification, 2026-09-06 17:51 KST".
    private let marketValueKRW = Decimal(string: "38585")!
    private let marketValueUSD = Decimal(string: "22417.561095")!
    private let usdKrwRate = Decimal(string: "1353.1")!

    // MARK: - Coverage

    func testEveryFixtureIsCovered() {
        let present = FixtureLoader.presentNames()
        XCTAssertFalse(present.isEmpty, "Bundle.module has no fixtures — check `.copy(\"Fixtures\")`")
        XCTAssertEqual(
            Set(present), Set(FixtureLoader.Name.all),
            "A fixture was added or removed without a decoding test. Present: \(present)"
        )
    }

    // MARK: - accounts.json

    func testAccountsDecodesTheRecordedAccount() throws {
        let accounts = try FixtureLoader.result([TossAccount].self, from: FixtureLoader.Name.accounts)

        XCTAssertEqual(accounts.count, 1, "the live account only has one BROKERAGE account")
        let account = try XCTUnwrap(accounts.first)
        XCTAssertEqual(account.accountNo, "1300*******")
        XCTAssertEqual(account.accountSeq, 1)
        XCTAssertEqual(account.accountType, .brokerage)
        XCTAssertEqual(account.accountType.rawValue, "BROKERAGE")
        XCTAssertEqual(account.id, 1, "Identifiable.id is accountSeq — it feeds X-Tossinvest-Account")
        XCTAssertEqual(account.maskedAccountNo, "1300*******",
                       "an already-masked number masks to itself")
    }

    func testAccountsEmptyDecodesToAnEmptyList() throws {
        let accounts = try FixtureLoader.result([TossAccount].self, from: FixtureLoader.Name.accountsEmpty)
        XCTAssertEqual(accounts, [])
    }

    func testMaskedAccountNoHidesEverythingAfterTheFirstFourDigits() {
        // The unmasked form documented in the contract; the fixture ships it already masked.
        let account = TossAccount(accountNo: "13001057376", accountSeq: 1, accountType: .brokerage)
        XCTAssertEqual(account.maskedAccountNo, "1300*******")
        XCTAssertEqual(account.maskedAccountNo.count, "13001057376".count)
    }

    func testUnknownAccountTypeDecodesInsteadOfThrowing() throws {
        // api-notes: "Decode unknown values without failing" — a new server enum must not lock the
        // user out of onboarding. Built by corrupting the recorded bytes, not by inventing a payload.
        let data = try FixtureLoader.corruptedData(FixtureLoader.Name.accounts,
                                                   replacing: "\"BROKERAGE\"",
                                                   with: "\"FUTURE_ACCOUNT_KIND\"")
        let accounts = try FixtureLoader.makeDecoder().decode(FixtureEnvelope<[TossAccount]>.self, from: data).result

        XCTAssertEqual(accounts.first?.accountType.rawValue, "FUTURE_ACCOUNT_KIND")
        XCTAssertEqual(accounts.first?.accountType.displayNameKo, "FUTURE_ACCOUNT_KIND")
    }

    // MARK: - holdings.json

    func testHoldingsDecodesTheRecordedTotals() throws {
        let holdings = try FixtureLoader.result(HoldingsOverview.self, from: FixtureLoader.Name.holdings)

        XCTAssertEqual(holdings.marketValue.krw, marketValueKRW)
        XCTAssertEqual(holdings.marketValue.usd, marketValueUSD)

        XCTAssertEqual(holdings.totalPurchaseAmount.krw, Decimal(string: "38115")!)
        XCTAssertEqual(holdings.totalPurchaseAmount.usd, Decimal(string: "20821.471188")!)

        XCTAssertEqual(holdings.marketValueAfterCost.krw, Decimal(string: "38580")!)
        XCTAssertEqual(holdings.marketValueAfterCost.usd, Decimal(string: "22375.101095")!)

        XCTAssertEqual(holdings.itemCount, 6, "418660, BOXX, JAAA, QLD, QNDX, VOO")
    }

    func testHoldingsKeepsEverySignificantDigitOfTheUsdSum() throws {
        let holdings = try FixtureLoader.result(HoldingsOverview.self, from: FixtureLoader.Name.holdings)

        // A `Double` round trip turns this into 22417.561094999998…; `Decimal` keeps it exact.
        XCTAssertEqual(holdings.marketValue.usd.description, "22417.561095")
        XCTAssertEqual(holdings.totalPurchaseAmount.usd.description, "20821.471188")
    }

    func testHoldingsDecodesTheWholeEnvelopeToo() throws {
        // The model tolerates both the `{"result": …}` envelope and the unwrapped object, so the
        // client and a raw-fixture test read the same bytes the same way.
        let unwrapped = try FixtureLoader.result(HoldingsOverview.self, from: FixtureLoader.Name.holdings)
        let enveloped = try FixtureLoader.decode(HoldingsOverview.self, from: FixtureLoader.Name.holdings)
        XCTAssertEqual(unwrapped, enveloped)
    }

    func testHoldingsEmptyDecodesANullCurrencyBucketAsZero() throws {
        // api-notes: "A currency bucket is `null` when nothing is held in it."
        let holdings = try FixtureLoader.result(HoldingsOverview.self, from: FixtureLoader.Name.holdingsEmpty)

        XCTAssertEqual(holdings.marketValue.krw, 0)
        XCTAssertEqual(holdings.marketValue.usd, 0, "a null USD bucket is zero, not a decode failure")
        XCTAssertEqual(holdings.totalPurchaseAmount.usd, 0)
        XCTAssertEqual(holdings.marketValueAfterCost.usd, 0)
        XCTAssertEqual(holdings.itemCount, 0)
        XCTAssertEqual(holdings.marketValue.totalKRW(usdKrwRate: usdKrwRate), 0)
    }

    func testMalformedDecimalStringIsRejected() throws {
        // A thousands separator is not a decimal literal. Built by corrupting the recorded bytes.
        let data = try FixtureLoader.corruptedData(FixtureLoader.Name.holdings,
                                                   replacing: "\"krw\": \"38585\"",
                                                   with: "\"krw\": \"38,585\"")

        XCTAssertThrowsError(
            try FixtureLoader.makeDecoder().decode(FixtureEnvelope<HoldingsOverview>.self, from: data)
        ) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected DecodingError.dataCorrupted, got \(error)")
            }
        }
    }

    // MARK: - The number the whole app renders

    func testTotalKRWMatchesTheRecordedCurrentAssets() throws {
        // docs/api-notes.md: 38585 + 22417.561095 × 1353.1 == 30_371_787 KRW.
        let holdings = try FixtureLoader.result(HoldingsOverview.self, from: FixtureLoader.Name.holdings)
        let rate = try FixtureLoader.result(ExchangeRate.self, from: FixtureLoader.Name.exchangeRate)

        XCTAssertEqual(holdings.marketValue.totalKRW(usdKrwRate: rate.rate), 30_371_787)
        XCTAssertEqual(MoneyByCurrency(krw: marketValueKRW, usd: marketValueUSD)
            .totalKRW(usdKrwRate: usdKrwRate), 30_371_787)
    }

    func testTotalKRWRoundsHalfUpToAWholeWon() {
        XCTAssertEqual(MoneyByCurrency(krw: 0, usd: Decimal(string: "0.5")!).totalKRW(usdKrwRate: 1), 1)
        XCTAssertEqual(MoneyByCurrency(krw: 0, usd: Decimal(string: "0.4999")!).totalKRW(usdKrwRate: 1), 0)
        XCTAssertEqual(MoneyByCurrency(krw: 1, usd: Decimal(string: "1.5")!).totalKRW(usdKrwRate: 1), 3)
        XCTAssertEqual(MoneyByCurrency(krw: 10, usd: 0).totalKRW(usdKrwRate: usdKrwRate), 10,
                       "a zero USD bucket must not drag the KRW side through a conversion")
    }

    func testMoneyByCurrencyRoundTripsThroughJSONAsDecimalStrings() throws {
        let original = MoneyByCurrency(krw: marketValueKRW, usd: marketValueUSD)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(MoneyByCurrency.self, from: data)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.usd.description, "22417.561095")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"22417.561095\""),
                      "amounts must go back out as decimal strings, not as JSON numbers")
    }

    // MARK: - exchange_rate.json

    func testExchangeRateDecodesTheRecordedRate() throws {
        let rate = try FixtureLoader.result(ExchangeRate.self, from: FixtureLoader.Name.exchangeRate)

        XCTAssertEqual(rate.baseCurrency, .usd)
        XCTAssertEqual(rate.quoteCurrency, .krw)
        XCTAssertEqual(rate.rate, usdKrwRate)
        XCTAssertEqual(rate.rate.description, "1353.1")
        XCTAssertEqual(rate.validUntil, TestDate.iso("2026-09-06T17:56:56.000+09:00"),
                       "the API stamps fractional seconds and a +09:00 offset")
    }

    func testCurrencyRawValuesAreTheQueryParameterValues() {
        XCTAssertEqual(Currency.krw.rawValue, "KRW")
        XCTAssertEqual(Currency.usd.rawValue, "USD")
        XCTAssertEqual(Set(Currency.allCases), [.krw, .usd])
    }

    // MARK: - buying_power_krw.json

    func testBuyingPowerDecodesAsADecimalString() throws {
        let raw = try FixtureLoader.result(RawBuyingPower.self, from: FixtureLoader.Name.buyingPowerKRW)
        XCTAssertEqual(raw.currency, "KRW")
        XCTAssertEqual(Decimal(string: raw.cashBuyingPower), Decimal(50))
    }

    // MARK: - token.json

    func testTokenResponseUsesTheOAuth2ShapeAndA24HourLifetime() throws {
        let token = try FixtureLoader.decode(RawToken.self, from: FixtureLoader.Name.token)
        XCTAssertEqual(token.tokenType, "Bearer")
        XCTAssertEqual(token.expiresIn, 86400, "measured lifetime is 24h, not the 3600s blogs quote")
        XCTAssertFalse(token.accessToken.isEmpty)
    }

    // MARK: - error envelopes

    func testCommonErrorEnvelope() throws {
        let unauthorized = try FixtureLoader.decode(RawCommonError.self, from: FixtureLoader.Name.error401)
        XCTAssertEqual(unauthorized.error.requestId, "6rOxXisFxJuawk9p")
        XCTAssertEqual(unauthorized.error.code, "invalid-token")
        XCTAssertEqual(unauthorized.error.message, "유효하지 않은 토큰입니다.")
        XCTAssertNil(unauthorized.error.data)

        let rateLimited = try FixtureLoader.decode(RawCommonError.self, from: FixtureLoader.Name.error429)
        XCTAssertEqual(rateLimited.error.code, "rate-limit-exceeded")
        XCTAssertEqual(rateLimited.error.message, "", "api-notes: message may be empty by policy")
        XCTAssertEqual(rateLimited.error.data?.retryAfterSeconds, 1)
    }

    func testOAuth2ErrorEnvelopeNamesTheFailingField() throws {
        let error = try FixtureLoader.decode(RawOAuthError.self,
                                             from: FixtureLoader.Name.oauthErrorInvalidClient)
        XCTAssertEqual(error.error, "invalid_client")
        XCTAssertEqual(error.errorDescription, "Client authentication failed: client_secret")
        XCTAssertTrue(error.errorDescription.contains("client_secret"),
                      "this substring is what distinguishes a wrong id from a wrong secret")
    }

    // MARK: - Snapshot / Settings coding

    func testSnapshotEncodesAmountsAsDecimalStrings() throws {
        let holdings = try FixtureLoader.result(HoldingsOverview.self, from: FixtureLoader.Name.holdings)
        let rate = try FixtureLoader.result(ExchangeRate.self, from: FixtureLoader.Name.exchangeRate)
        let snapshot = Snapshot(
            currentAssets: holdings.marketValue.totalKRW(usdKrwRate: rate.rate),
            perAccount: [1: holdings.marketValue.totalKRW(usdKrwRate: rate.rate)],
            krwAmount: holdings.marketValue.krw,
            usdAmount: holdings.marketValue.usd,
            usdKrwRate: rate.rate,
            cashKRW: nil,
            fetchedAt: TestDate.kst("2026-09-06T17:51:58+09:00"),
            status: .ok
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)

        XCTAssertTrue(json.contains("\"22417.561095\""))
        XCTAssertTrue(json.contains("\"1353.1\""))
        XCTAssertTrue(json.contains("30371787"))
    }

    func testFetchStatusRawValuesAreStable() {
        // Persisted verbatim in the App Group container; renaming one silently resets every install.
        XCTAssertEqual(FetchStatus.ok.rawValue, "ok")
        XCTAssertEqual(FetchStatus.staleNetwork.rawValue, "staleNetwork")
        XCTAssertEqual(FetchStatus.authFailed.rawValue, "authFailed")
        XCTAssertEqual(FetchStatus.ipBlocked.rawValue, "ipBlocked")
        XCTAssertEqual(RefreshPolicy.hourly.rawValue, "hourly")
        XCTAssertEqual(RefreshPolicy.daily.rawValue, "daily")
    }
}

// MARK: - Raw wire shapes without a model of their own
//
// `TossClient` reads these three payloads inline (a token, a cash figure, an error envelope), so
// there is no public type to decode them into. Declared here purely to assert the recorded bytes.

private struct RawBuyingPower: Decodable {
    let currency: String
    let cashBuyingPower: String
}

private struct RawToken: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

private struct RawCommonError: Decodable {
    struct Payload: Decodable {
        struct Details: Decodable {
            let retryAfterSeconds: Int
        }
        let requestId: String
        let code: String
        let message: String
        let data: Details?
    }
    let error: Payload
}

private struct RawOAuthError: Decodable {
    let error: String
    let errorDescription: String

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
