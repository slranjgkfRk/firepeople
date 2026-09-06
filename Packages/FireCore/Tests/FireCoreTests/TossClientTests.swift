//
//  TossClientTests.swift
//  FireCoreTests
//
//  README §9, `TossClient` row: token issuance and caching, re-issue 60s before expiry, 401 (one
//  re-issue, one retry), 429 `Retry-After` backoff and error handling.
//
//  The client is exercised end to end: it builds the real requests and parses the real recorded
//  responses. Only `URLSession`'s transport is replaced (`StubURLProtocol`), and the bytes it
//  replays come from `Fixtures/`.
//
//  Backoff is asserted on *attempt counts*, never by waiting out a real delay — `Retry-After: 0`
//  keeps the client tests instant, and the precedence rules the client honours are pinned directly
//  in `testRetryAfterPrecedence`.
//

import XCTest
@testable import FireCore

final class TossClientTests: XCTestCase {

    /// The instant docs/api-notes.md recorded the fixtures at.
    private static let t0 = TestDate.kst("2026-09-06T17:51:58+09:00")
    /// The access token in `Fixtures/token.json`.
    private static let recordedToken = "eyJhbGciOiJSUzI1NiJ9.RECORDED_SHAPE_ONLY.signature"
    /// `expires_in` in the same fixture.
    private static let recordedLifetime: TimeInterval = 86_400

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        XCTAssertEqual(StubURLProtocol.unhandledPaths(), [],
                       "a request reached an un-stubbed path — the test is missing a stub")
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Token issuance and caching

    func testTokenIsIssuedOnceAndReusedFromTheCache() async throws {
        try stubToken()
        try stub(StubPath.accounts, fixture: FixtureLoader.Name.accounts)

        let cache = InMemoryTokenCache()
        let client = makeClient(cache: cache, clock: TestClock(Self.t0))

        _ = try await client.accounts()
        _ = try await client.accounts()
        _ = try await client.accounts()

        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 1,
                       "only one access token may exist per client — re-issuing revokes the old one")
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.accounts), 3)

        let cached = try XCTUnwrap(cache.loadToken())
        XCTAssertEqual(cached.value, Self.recordedToken)
        XCTAssertEqual(cached.expiresAt, Self.t0.addingTimeInterval(Self.recordedLifetime))
        XCTAssertTrue(cached.isValid(at: Self.t0))
    }

    func testTokenRequestIsAFormPostThatKeepsTheSecretOutOfTheURL() async throws {
        try stubToken()
        try stub(StubPath.accounts, fixture: FixtureLoader.Name.accounts)
        let client = makeClient(clock: TestClock(Self.t0))

        _ = try await client.accounts()

        let request = try XCTUnwrap(StubURLProtocol.requests(for: StubPath.token).first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(
            (request.header("Content-Type") ?? "").contains("application/x-www-form-urlencoded"),
            "got \(request.header("Content-Type") ?? "no Content-Type")"
        )
        XCTAssertTrue(request.bodyText.contains("grant_type=client_credentials"))
        XCTAssertTrue(request.bodyText.contains("client_id="))
        XCTAssertTrue(request.bodyText.contains("client_secret="))
        XCTAssertTrue(request.queryItems.isEmpty, "credentials go in the body, never in the query")

        let accountsRequest = try XCTUnwrap(StubURLProtocol.requests(for: StubPath.accounts).first)
        XCTAssertEqual(accountsRequest.header("Authorization"), "Bearer \(Self.recordedToken)")
        XCTAssertEqual(accountsRequest.header("Accept"), "application/json")
    }

    func testConcurrentCallsIssueExactlyOneToken() async throws {
        // A 20ms delay widens the window in which a second caller could see an empty cache. With the
        // token issue serialized inside the actor there is still only one POST.
        try stubToken(delay: 0.02)
        try stub(StubPath.accounts, fixture: FixtureLoader.Name.accounts)
        try stub(StubPath.exchangeRate, fixture: FixtureLoader.Name.exchangeRate)
        let client = makeClient(clock: TestClock(Self.t0))

        async let accounts: [TossAccount] = client.accounts()
        async let rate: ExchangeRate = client.exchangeRate(base: .usd, quote: .krw)
        let (fetchedAccounts, fetchedRate) = try await (accounts, rate)

        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 1,
                       "two racing callers must share one token, not revoke each other's")
        XCTAssertEqual(fetchedAccounts.count, 1)
        XCTAssertEqual(fetchedRate.rate, Decimal(string: "1353.1")!)
    }

    // MARK: - Expiry leeway (README §3.2 — reissue 60s before expiry)

    func testCachedTokenIsUsedUntilSixtySecondsBeforeExpiryAndReissuedAtTheBoundary() async throws {
        try stubToken()
        try stub(StubPath.accounts, fixture: FixtureLoader.Name.accounts)

        let cache = InMemoryTokenCache()
        try cache.saveToken(AccessToken(value: "seeded-token",
                                        expiresAt: Self.t0.addingTimeInterval(100)))
        let clock = TestClock(Self.t0.addingTimeInterval(39))
        let client = makeClient(cache: cache, clock: clock)

        // 61s of life left: still inside the 60s leeway margin, so the cached token is used.
        _ = try await client.accounts()
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 0)
        XCTAssertEqual(StubURLProtocol.requests(for: StubPath.accounts).first?.header("Authorization"),
                       "Bearer seeded-token")

        // One second later exactly 60s remain, which is no longer "valid".
        clock.set(Self.t0.addingTimeInterval(40))
        _ = try await client.accounts()
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 1)
        XCTAssertEqual(StubURLProtocol.requests(for: StubPath.accounts).last?.header("Authorization"),
                       "Bearer \(Self.recordedToken)")
    }

    func testAccessTokenValidityUsesAStrictSixtySecondLeeway() {
        let token = AccessToken(value: "t", expiresAt: Self.t0.addingTimeInterval(100))

        XCTAssertTrue(token.isValid(at: Self.t0.addingTimeInterval(39)))
        XCTAssertFalse(token.isValid(at: Self.t0.addingTimeInterval(40)))
        XCTAssertFalse(token.isValid(at: Self.t0.addingTimeInterval(1000)))

        XCTAssertTrue(token.isValid(at: Self.t0.addingTimeInterval(99), leeway: 0))
        XCTAssertFalse(token.isValid(at: Self.t0.addingTimeInterval(100), leeway: 0))
    }

    func testInvalidateTokenForcesAReissue() async throws {
        try stubToken()
        try stub(StubPath.accounts, fixture: FixtureLoader.Name.accounts)
        let cache = InMemoryTokenCache()
        let client = makeClient(cache: cache, clock: TestClock(Self.t0))

        _ = try await client.accounts()
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 1)

        await client.invalidateToken()
        _ = try await client.accounts()
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 2)
    }

    // MARK: - 401 (README §3.5 — one re-issue, one retry)

    func testUnauthorizedReissuesTheTokenOnceAndRetriesOnce() async throws {
        try stubToken()
        StubURLProtocol.stubSequence(StubPath.accounts, [
            .status(401, try FixtureLoader.data(FixtureLoader.Name.error401)),
            .ok(try FixtureLoader.data(FixtureLoader.Name.accounts))
        ])

        let cache = InMemoryTokenCache()
        try cache.saveToken(AccessToken(value: "revoked-token",
                                        expiresAt: Self.t0.addingTimeInterval(Self.recordedLifetime)))
        let client = makeClient(cache: cache, clock: TestClock(Self.t0))

        let accounts = try await client.accounts()

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.accounts), 2, "exactly one retry")
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 1, "exactly one re-issue")

        let requests = StubURLProtocol.requests(for: StubPath.accounts)
        XCTAssertEqual(requests[0].header("Authorization"), "Bearer revoked-token")
        XCTAssertEqual(requests[1].header("Authorization"), "Bearer \(Self.recordedToken)")
        XCTAssertEqual(try cache.loadToken()?.value, Self.recordedToken)
    }

    func testUnauthorizedTwiceSurfacesUnauthorizedWithTheServerDiagnostics() async throws {
        try stubToken()
        try stub(StubPath.accounts, status: 401, fixture: FixtureLoader.Name.error401)

        let cache = InMemoryTokenCache()
        try cache.saveToken(AccessToken(value: "revoked-token",
                                        expiresAt: Self.t0.addingTimeInterval(Self.recordedLifetime)))
        let client = makeClient(cache: cache, clock: TestClock(Self.t0))

        let error = await tossError { try await client.accounts() }

        XCTAssertEqual(error, TossAPIError.unauthorized(code: "invalid-token", requestId: "6rOxXisFxJuawk9p"))
        XCTAssertEqual(error?.isAuthFailure, true, "drives the README §2.6 'API 키를 확인해주세요' banner")
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.accounts), 2, "no third attempt")
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 1)
    }

    // MARK: - 403 (api-notes: register your IP, not a bad key)

    func testForbiddenIsIpNotAllowedAndIsNeverRetried() async throws {
        try stubToken()
        // A 403 body is not among the recorded responses — the project's IP is registered — and the
        // client maps 403 from the status alone, so the transport returns the status with no body.
        StubURLProtocol.stub(StubPath.holdings, status: 403, body: Data())
        let client = makeClient(clock: TestClock(Self.t0))

        let error = await tossError { try await client.holdings(accountSeq: 1) }

        XCTAssertEqual(error, TossAPIError.ipNotAllowed)
        XCTAssertEqual(error?.isAuthFailure, false, "the key is fine, the IP is not")
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.holdings), 1)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 1)
    }

    // MARK: - 429 (README §3.5 — Retry-After, max 3 attempts)

    func testRateLimitedHonoursTheRetryAfterHeaderThenSucceeds() async throws {
        try stubToken()
        StubURLProtocol.stubSequence(StubPath.holdings, [
            .status(429,
                    try FixtureLoader.data(FixtureLoader.Name.error429),
                    headers: ["Retry-After": "2", "X-RateLimit-Remaining": "0"]),
            .ok(try FixtureLoader.data(FixtureLoader.Name.holdings))
        ])
        let backoff = DelayRecorder()
        let client = makeClient(clock: TestClock(Self.t0), backoff: backoff)

        let holdings = try await client.holdings(accountSeq: 1)

        XCTAssertEqual(holdings.marketValue.krw, Decimal(string: "38585")!)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.holdings), 2,
                       "one 429, one retry, then the real payload")
        XCTAssertEqual(backoff.values.count, 1)
        let delay = try XCTUnwrap(backoff.values.first)
        XCTAssertGreaterThanOrEqual(delay, 2, "the header's 2s is honoured, not the 1s default")
        XCTAssertLessThan(delay, 2.5, "…with only a little jitter on top")
    }

    func testRateLimitedFallsBackToTheBodyHintAndGivesUpAfterThreeAttempts() async throws {
        try stubToken()
        // No `Retry-After` header, so the recorded body's `error.data.retryAfterSeconds` (1) is used.
        StubURLProtocol.stub(StubPath.holdings,
                             status: 429,
                             body: try FixtureLoader.data(FixtureLoader.Name.error429))
        let backoff = DelayRecorder()
        let client = makeClient(clock: TestClock(Self.t0), backoff: backoff)

        let error = await tossError { try await client.holdings(accountSeq: 1) }

        XCTAssertEqual(error, TossAPIError.rateLimited(retryAfter: 1))
        XCTAssertEqual(error?.isAuthFailure, false)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.holdings), 3,
                       "three attempts is the whole budget — the next scheduled refresh tries again")
        XCTAssertEqual(backoff.values.count, 2, "three attempts means two waits")
        XCTAssertTrue((1.0..<1.25).contains(backoff.values[0]),
                      "×1 of the server's hint plus jitter, got \(backoff.values[0])")
        XCTAssertTrue((2.0..<2.5).contains(backoff.values[1]),
                      "×2 of the server's hint plus jitter, got \(backoff.values[1])")
    }

    func testRateLimitedBackoffIsCappedAtThirtySeconds() async throws {
        try stubToken()
        StubURLProtocol.stub(StubPath.holdings,
                             status: 429,
                             headers: ["Retry-After": "600"],
                             body: try FixtureLoader.data(FixtureLoader.Name.error429))
        let backoff = DelayRecorder()
        let client = makeClient(clock: TestClock(Self.t0), backoff: backoff)

        let error = await tossError { try await client.holdings(accountSeq: 1) }

        XCTAssertEqual(error, TossAPIError.rateLimited(retryAfter: 30))
        XCTAssertEqual(backoff.values, [30, 30],
                       "never wait longer than 30s, whatever the server asks for")
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.holdings), 3)
    }

    /// The precedence the client backs off with, pinned without waiting for any of it:
    /// `Retry-After` header, else `error.data.retryAfterSeconds`, else 1s, clamped to 0…30s.
    func testRetryAfterPrecedence() throws {
        let recorded = TossErrorBody.parse(try FixtureLoader.data(FixtureLoader.Name.error429))
        XCTAssertEqual(recorded.shape, TossErrorBody.Shape.common)
        XCTAssertEqual(recorded.code, "rate-limit-exceeded")
        XCTAssertEqual(recorded.retryAfterSeconds, 1)

        XCTAssertEqual(TossAPIError.resolvedRetryAfter(header: "5", body: recorded), 5,
                       "the header wins over the body")
        XCTAssertEqual(TossAPIError.resolvedRetryAfter(header: nil, body: recorded), 1,
                       "then error.data.retryAfterSeconds")
        XCTAssertEqual(TossAPIError.resolvedRetryAfter(header: nil, body: TossErrorBody.unparsed), 1,
                       "then the 1s default")
        XCTAssertEqual(TossAPIError.resolvedRetryAfter(header: "600", body: recorded), 30,
                       "capped at 30s whatever the server asks for")
        XCTAssertEqual(TossAPIError.resolvedRetryAfter(header: "0", body: recorded), 0)
        XCTAssertEqual(TossAPIError.resolvedRetryAfter(header: "Wed, 21 Oct 2026 07:28:00 GMT",
                                                       body: recorded), 1,
                       "an HTTP-date form falls back rather than blocking for hours")
    }

    // MARK: - The OAuth2 error shape

    func testInvalidClientSecretMapsToInvalidCredentialsNamingTheField() async throws {
        StubURLProtocol.stub(
            StubPath.token,
            status: 401,
            headers: ["WWW-Authenticate": "Basic realm=\"openapi\""],
            body: try FixtureLoader.data(FixtureLoader.Name.oauthErrorInvalidClient)
        )
        let client = makeClient(clock: TestClock(Self.t0))

        let error = await tossError { try await client.accounts() }

        XCTAssertEqual(error, TossAPIError.invalidCredentials(field: "client_secret"))
        XCTAssertEqual(error?.isAuthFailure, true)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 1)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.accounts), 0,
                       "there is no token, so the request is never sent")
    }

    func testErrorBodyParsingOfTheRecordedEnvelopes() throws {
        let common = TossErrorBody.parse(try FixtureLoader.data(FixtureLoader.Name.error401))
        XCTAssertEqual(common.shape, TossErrorBody.Shape.common)
        XCTAssertEqual(common.code, "invalid-token")
        XCTAssertEqual(common.requestId, "6rOxXisFxJuawk9p")
        XCTAssertNil(common.credentialField)

        let oauth = TossErrorBody.parse(try FixtureLoader.data(FixtureLoader.Name.oauthErrorInvalidClient))
        XCTAssertEqual(oauth.shape, TossErrorBody.Shape.oauth)
        XCTAssertEqual(oauth.code, "invalid_client")
        XCTAssertEqual(oauth.credentialField, TossAPIError.clientSecretField)

        XCTAssertEqual(TossErrorBody.parse(Data()), TossErrorBody.unparsed)
        XCTAssertEqual(TossErrorBody.parse(Data("not json at all".utf8)), TossErrorBody.unparsed)
    }

    func testMissingCredentialsFailBeforeAnyRequestIsSent() async throws {
        let client = makeClient(credentials: StubCredentials(stored: nil), clock: TestClock(Self.t0))

        let error = await tossError { try await client.accounts() }

        XCTAssertEqual(error, TossAPIError.invalidCredentials(field: nil))
        XCTAssertEqual(StubURLProtocol.allRequests().count, 0,
                       "with nothing in the Keychain there is nothing to send")
    }

    // MARK: - Headers per endpoint (api-notes § Calling other endpoints)

    func testAccountHeaderIsSentForHoldingsAndOmittedForAccounts() async throws {
        try stubToken()
        try stub(StubPath.accounts, fixture: FixtureLoader.Name.accounts)
        try stub(StubPath.holdings, fixture: FixtureLoader.Name.holdings)
        let client = makeClient(clock: TestClock(Self.t0))

        _ = try await client.accounts()
        _ = try await client.holdings(accountSeq: 7)

        let accountsRequest = try XCTUnwrap(StubURLProtocol.requests(for: StubPath.accounts).first)
        XCTAssertNil(accountsRequest.header("X-Tossinvest-Account"),
                     "GET /api/v1/accounts does not take the account header")

        let holdingsRequest = try XCTUnwrap(StubURLProtocol.requests(for: StubPath.holdings).first)
        XCTAssertEqual(holdingsRequest.header("X-Tossinvest-Account"), "7")
        XCTAssertEqual(holdingsRequest.method, "GET")
        XCTAssertEqual(holdingsRequest.header("Authorization"), "Bearer \(Self.recordedToken)")
    }

    func testExchangeRateSendsBothCurrenciesAndNoAccountHeader() async throws {
        try stubToken()
        try stub(StubPath.exchangeRate, fixture: FixtureLoader.Name.exchangeRate)
        let client = makeClient(clock: TestClock(Self.t0))

        let rate = try await client.exchangeRate(base: .usd, quote: .krw)

        XCTAssertEqual(rate.baseCurrency, .usd)
        XCTAssertEqual(rate.quoteCurrency, .krw)
        XCTAssertEqual(rate.rate, Decimal(string: "1353.1")!)

        let request = try XCTUnwrap(StubURLProtocol.requests(for: StubPath.exchangeRate).first)
        XCTAssertEqual(request.queryItems["baseCurrency"], "USD")
        XCTAssertEqual(request.queryItems["quoteCurrency"], "KRW")
        XCTAssertNil(request.header("X-Tossinvest-Account"), "MARKET_INFO takes no account header")
    }

    func testCashBuyingPowerSendsTheCurrencyAndTheAccountHeader() async throws {
        try stubToken()
        try stub(StubPath.buyingPower, fixture: FixtureLoader.Name.buyingPowerKRW)
        let client = makeClient(clock: TestClock(Self.t0))

        let cash = try await client.cashBuyingPower(accountSeq: 3, currency: .krw)

        XCTAssertEqual(cash, Decimal(50))

        let request = try XCTUnwrap(StubURLProtocol.requests(for: StubPath.buyingPower).first)
        XCTAssertEqual(request.queryItems["currency"], "KRW")
        XCTAssertEqual(request.header("X-Tossinvest-Account"), "3")
    }

    // MARK: - Decoding the recorded payloads through the client

    func testHoldingsDecodesTheRecordedTotals() async throws {
        try stubToken()
        try stub(StubPath.holdings, fixture: FixtureLoader.Name.holdings)
        let client = makeClient(clock: TestClock(Self.t0))

        let holdings = try await client.holdings(accountSeq: 1)

        XCTAssertEqual(holdings.marketValue.krw, Decimal(string: "38585")!)
        XCTAssertEqual(holdings.marketValue.usd, Decimal(string: "22417.561095")!)
        XCTAssertEqual(holdings.itemCount, 6)
        XCTAssertEqual(holdings.marketValue.totalKRW(usdKrwRate: Decimal(string: "1353.1")!),
                       30_371_787)
    }

    func testEmptyPayloadsDecodeWithoutFailing() async throws {
        try stubToken()
        try stub(StubPath.accounts, fixture: FixtureLoader.Name.accountsEmpty)
        try stub(StubPath.holdings, fixture: FixtureLoader.Name.holdingsEmpty)
        let client = makeClient(clock: TestClock(Self.t0))

        let accounts = try await client.accounts()
        let holdings = try await client.holdings(accountSeq: 1)

        XCTAssertEqual(accounts, [])
        XCTAssertEqual(holdings.itemCount, 0)
        XCTAssertEqual(holdings.marketValue.usd, 0, "a null currency bucket is zero")
    }

    func testVerifyConnectionIssuesATokenAndReturnsTheAccountList() async throws {
        // Onboarding step [2]'s 연결 테스트 button.
        try stubToken()
        try stub(StubPath.accounts, fixture: FixtureLoader.Name.accounts)
        let client = makeClient(clock: TestClock(Self.t0))

        let accounts = try await client.verifyConnection()

        XCTAssertEqual(accounts.map(\.accountSeq), [1])
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 1)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.accounts), 1)
    }

    // MARK: - Transport and server failures (README §3.5 — no retry, keep the snapshot)

    func testTransportFailureIsSurfacedWithoutRetryAndWithoutLeakingTheSecret() async throws {
        try stubToken()
        StubURLProtocol.handle(StubPath.accounts) { _ in .networkError(.notConnectedToInternet) }
        let client = makeClient(clock: TestClock(Self.t0))

        let error = await tossError { try await client.accounts() }

        guard case .transport(let message) = error else {
            return XCTFail("expected .transport, got \(String(describing: error))")
        }
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.accounts), 1, "no retry on transport")
        assertNoSecretLeaked(in: message)
        assertNoSecretLeaked(in: String(describing: error))
        assertNoSecretLeaked(in: error?.userMessageKo ?? "")
        XCTAssertFalse(error?.userMessageKo.isEmpty ?? true, "every state needs Korean copy")
    }

    func testServerErrorIsSurfacedWithItsStatusAndIsNotRetried() async throws {
        try stubToken()
        StubURLProtocol.stub(StubPath.accounts, status: 500, body: Data())
        let client = makeClient(clock: TestClock(Self.t0))

        let error = await tossError { try await client.accounts() }

        guard case .server(let status, _, _, _) = error else {
            return XCTFail("expected .server, got \(String(describing: error))")
        }
        XCTAssertEqual(status, 500)
        XCTAssertEqual(error?.isAuthFailure, false)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.accounts), 1,
                       "a 5xx abandons the refresh; the previous snapshot stays on screen")
    }

    func testNoSecretEverReachesAnErrorFromTheTokenEndpoint() async throws {
        StubURLProtocol.stub(StubPath.token,
                             status: 401,
                             body: try FixtureLoader.data(FixtureLoader.Name.oauthErrorInvalidClient))
        let client = makeClient(clock: TestClock(Self.t0))

        let error = await tossError { try await client.accounts() }

        assertNoSecretLeaked(in: String(describing: error))
        assertNoSecretLeaked(in: error?.userMessageKo ?? "")
        assertNoSecretLeaked(in: error?.localizedDescription ?? "")
    }

    // MARK: - The surface itself

    func testBaseURLIsTheOnlyHostThisAppTalksTo() {
        XCTAssertEqual(TossClient.baseURL.absoluteString, "https://openapi.tossinvest.com")
        XCTAssertEqual(TossClient.baseURL.scheme, "https", "README §7 — no ATS exception anywhere")
    }

    func testSessionFactoryTimeouts() {
        // README §3.5: app 15s, widget 10s.
        XCTAssertEqual(URLSession.fireDefault.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(URLSession.fire(timeout: 10).configuration.timeoutIntervalForRequest, 10)
        XCTAssertFalse(URLSession.fireDefault.configuration.waitsForConnectivity,
                       "a widget timeline must fail fast, not wait for connectivity")
    }

    func testOnlyReadOnlyPathsAreEverRequested() async throws {
        try stubToken()
        try stub(StubPath.accounts, fixture: FixtureLoader.Name.accounts)
        try stub(StubPath.holdings, fixture: FixtureLoader.Name.holdings)
        try stub(StubPath.exchangeRate, fixture: FixtureLoader.Name.exchangeRate)
        try stub(StubPath.buyingPower, fixture: FixtureLoader.Name.buyingPowerKRW)
        let client = makeClient(clock: TestClock(Self.t0))

        _ = try await client.accounts()
        _ = try await client.holdings(accountSeq: 1)
        _ = try await client.exchangeRate(base: .usd, quote: .krw)
        _ = try await client.cashBuyingPower(accountSeq: 1, currency: .krw)

        // Non-negotiable #1: there is no order code path in this codebase at all.
        let allowed: Set<String> = [
            StubPath.token, StubPath.accounts, StubPath.holdings,
            StubPath.exchangeRate, StubPath.buyingPower
        ]
        for request in StubURLProtocol.allRequests() {
            XCTAssertTrue(allowed.contains(request.path), "unexpected endpoint: \(request.path)")
            XCTAssertTrue(request.method == "GET" || request.path == StubPath.token,
                          "only the token endpoint may POST, got \(request.method) \(request.path)")
        }
    }

    // MARK: - Helpers

    private func makeClient(cache: InMemoryTokenCache = InMemoryTokenCache(),
                            credentials: StubCredentials = StubCredentials(),
                            clock: TestClock) -> TossClient {
        TossClient(credentials: credentials,
                   tokenCache: cache,
                   session: StubURLProtocol.makeSession(),
                   now: clock.closure)
    }

    /// The client asks for a backoff; this records it instead of spending it, so the retry policy
    /// is asserted exactly and `swift test` stays instant.
    private final class DelayRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [TimeInterval] = []

        var values: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        /// Synchronous on purpose: `NSLock` may not be taken from an async context.
        private func record(_ seconds: TimeInterval) {
            lock.withLock { recorded.append(seconds) }
        }

        var sleep: @Sendable (TimeInterval) async throws -> Void {
            { [self] seconds in record(seconds) }
        }
    }

    private func makeClient(cache: InMemoryTokenCache = InMemoryTokenCache(),
                            credentials: StubCredentials = StubCredentials(),
                            clock: TestClock,
                            backoff: DelayRecorder) -> TossClient {
        TossClient(credentials: credentials,
                   tokenCache: cache,
                   session: StubURLProtocol.makeSession(),
                   now: clock.closure,
                   backoffSleep: backoff.sleep)
    }

    private func stubToken(delay: TimeInterval = 0) throws {
        StubURLProtocol.stub(StubPath.token,
                             body: try FixtureLoader.data(FixtureLoader.Name.token),
                             delay: delay)
    }

    private func stub(_ path: String, status: Int = 200, fixture: String) throws {
        StubURLProtocol.stub(path, status: status, body: try FixtureLoader.data(fixture))
    }

    /// Runs `operation`, expecting it to throw a `TossAPIError`.
    private func tossError<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async -> TossAPIError? {
        do {
            _ = try await operation()
            XCTFail("expected the call to throw", file: file, line: line)
            return nil
        } catch let error as TossAPIError {
            return error
        } catch {
            XCTFail("expected a TossAPIError, got \(error)", file: file, line: line)
            return nil
        }
    }

    /// README §7: a key must never appear in a log, an error or a crash report.
    private func assertNoSecretLeaked(in text: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        XCTAssertFalse(text.contains(StubCredentials.clientSecret),
                       "client_secret leaked into \"\(text)\"", file: file, line: line)
        XCTAssertFalse(text.contains(StubCredentials.clientId),
                       "client_id leaked into \"\(text)\"", file: file, line: line)
        XCTAssertFalse(text.contains(Self.recordedToken),
                       "an access token leaked into \"\(text)\"", file: file, line: line)
    }
}
