//
//  RefreshServiceTests.swift
//  FireCoreTests
//
//  The one refresh path the app and the widget share (README §4.1). Driven through a real
//  `TossClient` over `StubURLProtocol`, so the numbers below come out of the recorded responses in
//  `Fixtures/` after passing through the real request building, decoding and FX conversion.
//
//  README §2.6 is the contract under test on the failure side: a failed refresh keeps the previous
//  numbers and the previous `마지막 갱신`, and only downgrades the status.
//

import XCTest
import FireCore

final class RefreshServiceTests: XCTestCase {

    /// docs/api-notes.md § Live verification.
    private static let t0 = TestDate.kst("2026-09-06T17:51:58+09:00")
    private static let recordedTotal = 30_371_787

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

    // MARK: - Happy path

    func testRefreshProducesTheRecordedCurrentAssets() async throws {
        try stubHappyPath()
        let clock = TestClock(Self.t0)
        let stack = makeStack(settings: makeSettings(accountSeqs: [1]), clock: clock)

        let snapshot = try unwrap(await stack.service.refresh())

        // 38585 + 22417.561095 × 1353.1 == 30,371,787 KRW.
        XCTAssertEqual(snapshot.currentAssets, Self.recordedTotal)
        XCTAssertEqual(snapshot.perAccount, [1: Self.recordedTotal])
        XCTAssertEqual(snapshot.krwAmount, Decimal(string: "38585")!)
        XCTAssertEqual(snapshot.usdAmount, Decimal(string: "22417.561095")!)
        XCTAssertEqual(snapshot.usdKrwRate, Decimal(string: "1353.1")!)
        XCTAssertNil(snapshot.cashKRW, "includeCash is off by default (README §12)")
        XCTAssertEqual(snapshot.fetchedAt, Self.t0)
        XCTAssertEqual(snapshot.status, .ok)
    }

    func testRefreshPersistsTheSnapshot() async throws {
        try stubHappyPath()
        let stack = makeStack(settings: makeSettings(accountSeqs: [1]), clock: TestClock(Self.t0))

        let snapshot = try unwrap(await stack.service.refresh())

        XCTAssertEqual(stack.snapshotStore.load(), snapshot,
                       "the widget reads the container, so the snapshot must land there")
    }

    func testRefreshNeverListsAccountsAndOnlyAsksForCashWhenToldTo() async throws {
        try stubHappyPath()
        let stack = makeStack(settings: makeSettings(accountSeqs: [1]), clock: TestClock(Self.t0))

        _ = await stack.service.refresh()

        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.exchangeRate), 1)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.holdings), 1)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.accounts), 0,
                       "ACCOUNT is 1 rps; a refresh works from the stored selection instead")
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.buyingPower), 0)
    }

    func testMultipleAccountsAreAggregated() async throws {
        try stubHappyPath()
        let stack = makeStack(settings: makeSettings(accountSeqs: [1, 2]), clock: TestClock(Self.t0))

        let snapshot = try unwrap(await stack.service.refresh())

        XCTAssertEqual(snapshot.perAccount, [1: Self.recordedTotal, 2: Self.recordedTotal])
        XCTAssertEqual(snapshot.currentAssets, 60_743_574)
        XCTAssertEqual(snapshot.krwAmount, Decimal(string: "77170")!)
        XCTAssertEqual(snapshot.usdAmount, Decimal(string: "44835.12219")!)

        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.holdings), 2)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.exchangeRate), 1,
                       "one FX request per refresh, not one per account")

        let headers = Set(StubURLProtocol.requests(for: StubPath.holdings)
            .compactMap { $0.header("X-Tossinvest-Account") })
        XCTAssertEqual(headers, ["1", "2"])
    }

    func testADuplicatedAccountIsCountedOnce() async throws {
        try stubHappyPath()
        let stack = makeStack(settings: makeSettings(accountSeqs: [1, 1]), clock: TestClock(Self.t0))

        let snapshot = try unwrap(await stack.service.refresh())

        XCTAssertEqual(snapshot.currentAssets, Self.recordedTotal, "no double counting")
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.holdings), 1)
    }

    // MARK: - includeCash (README §12)

    func testIncludeCashAddsTheCashBuyingPower() async throws {
        try stubHappyPath()
        // Only the KRW buying-power response was recorded, so the USD leg replays the same recorded
        // bytes: cash == 50 KRW + 50 USD × 1353.1 == 67,705 KRW.
        StubURLProtocol.stub(StubPath.buyingPower,
                             body: try FixtureLoader.data(FixtureLoader.Name.buyingPowerKRW))
        let stack = makeStack(settings: makeSettings(accountSeqs: [1], includeCash: true),
                              clock: TestClock(Self.t0))

        let snapshot = try unwrap(await stack.service.refresh())

        XCTAssertEqual(snapshot.cashKRW, 67_705)
        XCTAssertEqual(snapshot.currentAssets, Self.recordedTotal + 67_705)
        XCTAssertEqual(snapshot.krwAmount, Decimal(string: "38585")!,
                       "the holdings amounts stay the holdings amounts; cash is tracked separately")
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.buyingPower), 2,
                       "one KRW request and one USD request for the account")

        let currencies = Set(StubURLProtocol.requests(for: StubPath.buyingPower)
            .compactMap { $0.queryItems["currency"] })
        XCTAssertEqual(currencies, ["KRW", "USD"])
    }

    // MARK: - Failures keep the previous snapshot (README §2.6)

    func testNetworkFailurePreservesThePreviousSnapshotAndMarksItStale() async throws {
        try stubHappyPath()
        let clock = TestClock(Self.t0)
        let stack = makeStack(settings: makeSettings(accountSeqs: [1]), clock: clock)
        let first = try unwrap(await stack.service.refresh())

        StubURLProtocol.handle(StubPath.exchangeRate) { _ in .networkError(.notConnectedToInternet) }
        clock.advance(2 * 3600)

        let second = try unwrap(await stack.service.refresh())

        XCTAssertEqual(second.status, .staleNetwork)
        XCTAssertEqual(second.fetchedAt, first.fetchedAt,
                       "마지막 갱신 must keep pointing at the last *successful* fetch")
        XCTAssertEqual(second.currentAssets, first.currentAssets, "the numbers must not blank out")
        XCTAssertEqual(second.perAccount, first.perAccount)
        XCTAssertEqual(second.usdKrwRate, first.usdKrwRate)
    }

    func testAuthFailurePreservesThePreviousSnapshotAndMarksItAuthFailed() async throws {
        try stubHappyPath()
        let clock = TestClock(Self.t0)
        let stack = makeStack(settings: makeSettings(accountSeqs: [1]), clock: clock)
        let first = try unwrap(await stack.service.refresh())

        // 401 that survives the one permitted token re-issue and retry.
        StubURLProtocol.stub(StubPath.exchangeRate,
                             status: 401,
                             body: try FixtureLoader.data(FixtureLoader.Name.error401))
        clock.advance(2 * 3600)

        let second = try unwrap(await stack.service.refresh())

        XCTAssertEqual(second.status, .authFailed, "banner: API 키를 확인해주세요")
        XCTAssertEqual(second.fetchedAt, first.fetchedAt)
        XCTAssertEqual(second.currentAssets, first.currentAssets)
    }

    func testForbiddenPreservesThePreviousSnapshotAndMarksItIpBlocked() async throws {
        try stubHappyPath()
        let clock = TestClock(Self.t0)
        let stack = makeStack(settings: makeSettings(accountSeqs: [1]), clock: clock)
        let first = try unwrap(await stack.service.refresh())

        // The 403 body is not among the recorded responses; the status alone carries the meaning.
        StubURLProtocol.stub(StubPath.holdings, status: 403, body: Data())
        clock.advance(2 * 3600)

        let second = try unwrap(await stack.service.refresh())

        XCTAssertEqual(second.status, .ipBlocked, "403 = register your IP in WTS, not a bad key")
        XCTAssertEqual(second.fetchedAt, first.fetchedAt)
        XCTAssertEqual(second.currentAssets, first.currentAssets)
    }

    func testAFailureWithNoPreviousSnapshotYieldsNil() async throws {
        // README §2.6 "스냅샷 없음": the screen shows `--%` and a retry button, not a fake zero.
        StubURLProtocol.stub(StubPath.token,
                             status: 401,
                             body: try FixtureLoader.data(FixtureLoader.Name.oauthErrorInvalidClient))
        let stack = makeStack(settings: makeSettings(accountSeqs: [1]), clock: TestClock(Self.t0))

        let snapshot = await stack.service.refresh()

        XCTAssertNil(snapshot)
        XCTAssertNil(stack.snapshotStore.load(), "a failed first refresh must not persist anything")
    }

    func testAPartialFailureFailsTheWholeRefresh() async throws {
        // A wrong-low total is worse than a stale one: if one account errors, nothing is written.
        try stubHappyPath()
        let clock = TestClock(Self.t0)
        let stack = makeStack(settings: makeSettings(accountSeqs: [1, 2]), clock: clock)
        let first = try unwrap(await stack.service.refresh())

        let holdings = try FixtureLoader.data(FixtureLoader.Name.holdings)
        StubURLProtocol.handle(StubPath.holdings) { request in
            request.header("X-Tossinvest-Account") == "2"
                ? .status(500, Data())
                : .ok(holdings)
        }
        clock.advance(2 * 3600)

        let second = try unwrap(await stack.service.refresh())

        XCTAssertEqual(second.currentAssets, first.currentAssets,
                       "the total must not silently drop to the one account that answered")
        XCTAssertEqual(second.fetchedAt, first.fetchedAt)
        XCTAssertEqual(second.status, .staleNetwork)
    }

    // MARK: - refreshIfStale (README §4.2)

    func testRefreshIfStaleSkipsTheFetchWhileTheSnapshotIsFresh() async throws {
        try stubHappyPath()
        let clock = TestClock(Self.t0)
        let stack = makeStack(settings: makeSettings(accountSeqs: [1], policy: .hourly), clock: clock)
        let first = try unwrap(await stack.service.refresh())
        let baseline = StubURLProtocol.allRequests().count

        clock.advance(1800)
        let again = try unwrap(await stack.service.refreshIfStale())

        XCTAssertEqual(again, first, "returned untouched, fetchedAt and all")
        XCTAssertEqual(StubURLProtocol.allRequests().count, baseline,
                       "half an hour into an hourly policy, nothing goes on the wire")
    }

    func testRefreshIfStaleFetchesOncePastTheInterval() async throws {
        try stubHappyPath()
        let clock = TestClock(Self.t0)
        let stack = makeStack(settings: makeSettings(accountSeqs: [1], policy: .hourly), clock: clock)
        _ = await stack.service.refresh()
        let baseline = StubURLProtocol.requestCount(for: StubPath.holdings)

        clock.advance(3601)
        let refreshed = try unwrap(await stack.service.refreshIfStale())

        XCTAssertEqual(refreshed.fetchedAt, Self.t0.addingTimeInterval(3601))
        XCTAssertEqual(refreshed.status, .ok)
        XCTAssertEqual(refreshed.currentAssets, Self.recordedTotal)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.holdings), baseline + 1)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.token), 1,
                       "the 24h token is still cached — one token per client, remember")
    }

    func testRefreshIfStaleHonoursTheDailyPolicy() async throws {
        try stubHappyPath()
        let clock = TestClock(Self.t0)
        let stack = makeStack(settings: makeSettings(accountSeqs: [1], policy: .daily), clock: clock)
        let first = try unwrap(await stack.service.refresh())
        let baseline = StubURLProtocol.requestCount(for: StubPath.holdings)

        clock.advance(3601)
        let stillFresh = await stack.service.refreshIfStale()
        XCTAssertEqual(stillFresh, first, "an hour is fresh for .daily")
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.holdings), baseline)

        clock.advance(86_400)
        let refreshed = try unwrap(await stack.service.refreshIfStale())
        XCTAssertEqual(refreshed.fetchedAt, Self.t0.addingTimeInterval(3601 + 86_400))
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.holdings), baseline + 1)
    }

    func testRefreshIfStaleWithoutAStoredSnapshotFetches() async throws {
        try stubHappyPath()
        let stack = makeStack(settings: makeSettings(accountSeqs: [1]), clock: TestClock(Self.t0))

        let snapshot = try unwrap(await stack.service.refreshIfStale())

        XCTAssertEqual(snapshot.currentAssets, Self.recordedTotal)
        XCTAssertEqual(StubURLProtocol.requestCount(for: StubPath.holdings), 1)
    }

    // MARK: - Nothing configured yet

    func testWithoutSettingsNothingIsFetched() async throws {
        try stubHappyPath()
        let stack = makeStack(settings: nil, clock: TestClock(Self.t0))

        let snapshot = await stack.service.refresh()

        XCTAssertNil(snapshot)
        XCTAssertEqual(StubURLProtocol.allRequests().count, 0,
                       "onboarding has not finished; there is nothing to ask for")
    }

    func testWithNoSelectedAccountsTheStoredSnapshotIsReturnedUntouched() async throws {
        try stubHappyPath()
        let clock = TestClock(Self.t0)
        let stack = makeStack(settings: makeSettings(accountSeqs: [1]), clock: clock)
        let first = try unwrap(await stack.service.refresh())
        let baseline = StubURLProtocol.allRequests().count

        var cleared = try XCTUnwrap(stack.settingsStore.load())
        cleared.selectedAccountSeqs = []
        try stack.settingsStore.save(cleared)
        clock.advance(2 * 3600)

        let again = await stack.service.refresh()

        XCTAssertEqual(again, first)
        XCTAssertEqual(StubURLProtocol.allRequests().count, baseline)
    }

    // MARK: - Helpers

    /// `XCTUnwrap` takes an autoclosure, which cannot contain an `await`; this can.
    private func unwrap<T>(_ value: T?,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private struct Stack {
        let service: RefreshService
        let settingsStore: InMemorySettingsStore
        let snapshotStore: InMemorySnapshotStore
    }

    private func makeStack(settings: Settings?, clock: TestClock) -> Stack {
        let settingsStore = InMemorySettingsStore(settings)
        let snapshotStore = InMemorySnapshotStore()
        let client = TossClient(credentials: StubCredentials(),
                                tokenCache: InMemoryTokenCache(),
                                session: StubURLProtocol.makeSession(),
                                now: clock.closure)
        return Stack(
            service: RefreshService(client: client,
                                    settingsStore: settingsStore,
                                    snapshotStore: snapshotStore,
                                    now: clock.closure),
            settingsStore: settingsStore,
            snapshotStore: snapshotStore
        )
    }

    private func makeSettings(accountSeqs: [Int],
                              policy: RefreshPolicy = .hourly,
                              includeCash: Bool = false) -> Settings {
        Settings(targetAmount: 200_000_000,
                 targetDate: TestDate.kst("2029-12-31T00:00:00+09:00"),
                 selectedAccountSeqs: accountSeqs,
                 refreshPolicy: policy,
                 hideAmountInWidget: false,
                 includeCash: includeCash,
                 onboardingCompleted: true)
    }

    /// Token + FX + holdings, all replaying the recorded responses.
    private func stubHappyPath() throws {
        StubURLProtocol.stub(StubPath.token,
                             body: try FixtureLoader.data(FixtureLoader.Name.token))
        StubURLProtocol.stub(StubPath.exchangeRate,
                             body: try FixtureLoader.data(FixtureLoader.Name.exchangeRate))
        StubURLProtocol.stub(StubPath.holdings,
                             body: try FixtureLoader.data(FixtureLoader.Name.holdings))
    }
}
