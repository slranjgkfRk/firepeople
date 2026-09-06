//
//  StorageTests.swift
//  FireCoreTests
//
//  `Settings` and `Snapshot` round-trip through both stores, and a corrupt payload reads back as
//  `nil` rather than taking the app down. README §4.3 keeps these two in the App Group container;
//  secrets never come near them (README §7).
//
//  The `UserDefaults` suite is unique per test and removed in `tearDown`, so nothing leaks between
//  tests or onto the machine running `swift test`.
//

import XCTest
import FireCore

final class StorageTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "com.jay-lab.firepeople.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    // MARK: - Settings round trip

    func testSettingsRoundTripThroughUserDefaults() throws {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertNil(store.load(), "a fresh install has nothing stored")

        let settings = makeSettings()
        try store.save(settings)

        XCTAssertEqual(store.load(), settings)
        XCTAssertNotNil(defaults.data(forKey: UserDefaultsSettingsStore.storageKey),
                        "stored as JSON `Data` under the documented key")
    }

    func testSettingsRoundTripThroughTheInMemoryStore() throws {
        let settings = makeSettings()
        let store = InMemorySettingsStore()

        XCTAssertNil(store.load())
        try store.save(settings)
        XCTAssertEqual(store.load(), settings)

        try store.clear()
        XCTAssertNil(store.load())

        XCTAssertEqual(InMemorySettingsStore(settings).load(), settings, "seeded at init")
    }

    func testSettingsClearRemovesThePayload() throws {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        try store.save(makeSettings())
        XCTAssertNotNil(store.load())

        try store.clear()

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.object(forKey: UserDefaultsSettingsStore.storageKey),
                     "README §2.3 'API 키 삭제 및 초기화' has to leave nothing behind")
    }

    // MARK: - Snapshot round trip

    func testSnapshotRoundTripThroughUserDefaultsKeepsEveryDecimalExact() throws {
        let store = UserDefaultsSnapshotStore(defaults: defaults)
        XCTAssertNil(store.load())

        let snapshot = try makeRecordedSnapshot()
        try store.save(snapshot)
        let restored = try XCTUnwrap(store.load())

        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.currentAssets, 30_371_787)
        XCTAssertEqual(restored.usdAmount.description, "22417.561095",
                       "a Double round trip here would quietly lose won")
        XCTAssertEqual(restored.usdKrwRate.description, "1353.1")
        XCTAssertEqual(restored.perAccount, [1: 30_371_787])
        XCTAssertEqual(restored.fetchedAt, snapshot.fetchedAt)
        XCTAssertEqual(restored.status, .ok)
    }

    func testSnapshotRoundTripThroughTheInMemoryStore() throws {
        let snapshot = try makeRecordedSnapshot()
        let store = InMemorySnapshotStore()

        try store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)

        try store.clear()
        XCTAssertNil(store.load())

        XCTAssertEqual(InMemorySnapshotStore(snapshot).load(), snapshot)
    }

    func testSnapshotWithCashAndADowngradedStatusRoundTrips() throws {
        var snapshot = try makeRecordedSnapshot()
        snapshot.cashKRW = 67_705
        snapshot.status = .staleNetwork

        let store = UserDefaultsSnapshotStore(defaults: defaults)
        try store.save(snapshot)

        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.cashKRW, 67_705)
        XCTAssertEqual(restored.status, .staleNetwork)
    }

    // MARK: - Corrupt payloads read as nil, never as a crash

    func testCorruptSettingsBytesLoadAsNil() {
        defaults.set(Data("{ this is not json".utf8), forKey: UserDefaultsSettingsStore.storageKey)
        XCTAssertNil(UserDefaultsSettingsStore(defaults: defaults).load())
    }

    func testCorruptSnapshotBytesLoadAsNil() {
        defaults.set(Data([0x00, 0xFF, 0x10, 0x42]), forKey: UserDefaultsSnapshotStore.storageKey)
        XCTAssertNil(UserDefaultsSnapshotStore(defaults: defaults).load())
    }

    func testValidJsonOfTheWrongShapeLoadsAsNil() throws {
        // A `Snapshot` has no `fetchedAt` here, so there is no honest way to render it.
        defaults.set(Data("{}".utf8), forKey: UserDefaultsSnapshotStore.storageKey)
        XCTAssertNil(UserDefaultsSnapshotStore(defaults: defaults).load())

        let settingsPayload = try JSONEncoder().encode(["unrelated": "value"])
        defaults.set(settingsPayload, forKey: UserDefaultsSnapshotStore.storageKey)
        XCTAssertNil(UserDefaultsSnapshotStore(defaults: defaults).load())
    }

    func testAValueOfTheWrongTypeLoadsAsNil() {
        // Something other than `Data` under the key must not trap on a forced cast.
        defaults.set(42, forKey: UserDefaultsSettingsStore.storageKey)
        defaults.set("not data", forKey: UserDefaultsSnapshotStore.storageKey)

        XCTAssertNil(UserDefaultsSettingsStore(defaults: defaults).load())
        XCTAssertNil(UserDefaultsSnapshotStore(defaults: defaults).load())
    }

    func testSettingsMissingKeysFallBackToDefaultsInsteadOfBeingDiscarded() throws {
        // An older build's payload must not throw away everything the user configured.
        defaults.set(Data("{\"targetAmount\":200000000}".utf8),
                     forKey: UserDefaultsSettingsStore.storageKey)

        let settings = try XCTUnwrap(UserDefaultsSettingsStore(defaults: defaults).load())
        XCTAssertEqual(settings.targetAmount, 200_000_000)
        XCTAssertEqual(settings.refreshPolicy, .hourly)
        XCTAssertEqual(settings.selectedAccountSeqs, [])
        XCTAssertFalse(settings.onboardingCompleted)
    }

    // MARK: - Token cache

    func testInMemoryTokenCacheRoundTripAndClear() throws {
        let cache = InMemoryTokenCache()
        XCTAssertNil(try cache.loadToken())

        let issuedAt = TestDate.kst("2026-09-06T17:51:58+09:00")
        let token = AccessToken(value: "eyJhbGciOiJSUzI1NiJ9.RECORDED_SHAPE_ONLY.signature",
                                expiresAt: issuedAt.addingTimeInterval(86_400))
        try cache.saveToken(token)

        XCTAssertEqual(try cache.loadToken(), token)
        XCTAssertTrue(try XCTUnwrap(cache.loadToken()).isValid(at: issuedAt))

        try cache.clearToken()
        XCTAssertNil(try cache.loadToken())
    }

    func testAccessTokenRoundTripsAsJSON() throws {
        // `KeychainStore` stores it exactly this way.
        let token = AccessToken(value: "token-value",
                                expiresAt: TestDate.kst("2026-09-07T17:51:58+09:00"))
        let data = try JSONEncoder().encode(token)
        XCTAssertEqual(try JSONDecoder().decode(AccessToken.self, from: data), token)
    }

    // MARK: - Settings semantics

    func testFreshSettingsAreAnEmptyOnboardingState() {
        let fresh = Settings.fresh

        XCTAssertEqual(fresh.targetAmount, 0)
        XCTAssertEqual(fresh.selectedAccountSeqs, [])
        XCTAssertEqual(fresh.refreshPolicy, .hourly)
        XCTAssertFalse(fresh.hideAmountInWidget)
        XCTAssertFalse(fresh.includeCash, "README §12 default: stock market value only")
        XCTAssertFalse(fresh.onboardingCompleted)
        XCTAssertEqual(FireCalculator.kstMidnight(of: fresh.targetDate), fresh.targetDate,
                       "the default target date is a KST midnight")
    }

    func testDefaultTargetDateIsTenYearsOutAtKstMidnight() {
        XCTAssertEqual(
            Settings.defaultTargetDate(from: TestDate.kst("2026-09-06T17:51:58+09:00")),
            TestDate.kst("2036-09-06T00:00:00+09:00")
        )
        XCTAssertEqual(
            Settings.defaultTargetDate(from: TestDate.iso("2026-09-06T15:30:00Z")),
            TestDate.kst("2036-09-07T00:00:00+09:00"),
            "anchored to the KST day, not the UTC one"
        )
    }

    func testTargetDateIsNormalisedToKstMidnightOnEveryAssignment() throws {
        var settings = Settings.fresh
        settings.targetDate = TestDate.kst("2029-12-31T14:37:12+09:00")
        XCTAssertEqual(settings.targetDate, TestDate.kst("2029-12-31T00:00:00+09:00"))

        // 2029-12-30T15:00:00Z is already 2029-12-31 in Seoul.
        settings.targetDate = TestDate.iso("2029-12-30T16:20:00Z")
        XCTAssertEqual(settings.targetDate, TestDate.kst("2029-12-31T00:00:00+09:00"))

        let constructed = Settings(targetAmount: 1,
                                   targetDate: TestDate.kst("2029-12-31T23:59:59+09:00"))
        XCTAssertEqual(constructed.targetDate, TestDate.kst("2029-12-31T00:00:00+09:00"),
                       "normalised in init too, where property observers do not run")
    }

    func testTargetDateSurvivesAStorageRoundTripAsKstMidnight() throws {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        var settings = Settings.fresh
        settings.targetDate = TestDate.kst("2029-12-31T09:00:00+09:00")
        try store.save(settings)

        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.targetDate, TestDate.kst("2029-12-31T00:00:00+09:00"))
        XCTAssertEqual(FireFormatter.targetDate(restored.targetDate), "2029.12.31 (월)")
    }

    // MARK: - Shared container identifiers

    func testStorageKeysAndGroupIdentifiersAreTheDocumentedOnes() {
        // Both processes and every future migration depend on these exact strings.
        XCTAssertEqual(UserDefaultsSettingsStore.storageKey, "settings.v1")
        XCTAssertEqual(UserDefaultsSnapshotStore.storageKey, "snapshot.v1")
        XCTAssertEqual(AppGroup.identifier, "group.com.jay-lab.firepeople.shared")
        XCTAssertEqual(AppGroup.keychainAccessGroup, "com.jay-lab.firepeople.shared")
        XCTAssertEqual(AppGroup.widgetKind, "FireWidget")
    }

    func testTheTwoStoresDoNotShareAKey() throws {
        try UserDefaultsSettingsStore(defaults: defaults).save(makeSettings())
        try UserDefaultsSnapshotStore(defaults: defaults).save(try makeRecordedSnapshot())

        XCTAssertNotNil(UserDefaultsSettingsStore(defaults: defaults).load())
        XCTAssertNotNil(UserDefaultsSnapshotStore(defaults: defaults).load())

        try UserDefaultsSnapshotStore(defaults: defaults).clear()
        XCTAssertNotNil(UserDefaultsSettingsStore(defaults: defaults).load(),
                        "clearing one store must not wipe the other")
    }

    func testNoSecretIsEverWrittenToUserDefaults() throws {
        try UserDefaultsSettingsStore(defaults: defaults).save(makeSettings())
        try UserDefaultsSnapshotStore(defaults: defaults).save(try makeRecordedSnapshot())

        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        let dump = domain.map { key, value in
            "\(key)=\(String(data: (value as? Data) ?? Data(), encoding: .utf8) ?? String(describing: value))"
        }.joined(separator: "\n")

        for forbidden in ["client_id", "client_secret", "clientSecret", "accessToken", "Bearer"] {
            XCTAssertFalse(dump.contains(forbidden),
                           "README §7: \"\(forbidden)\" must never reach UserDefaults")
        }
    }

    // MARK: - Helpers

    private func makeSettings() -> Settings {
        Settings(targetAmount: 200_000_000,
                 targetDate: TestDate.kst("2029-12-31T00:00:00+09:00"),
                 selectedAccountSeqs: [1, 2],
                 refreshPolicy: .daily,
                 hideAmountInWidget: true,
                 includeCash: true,
                 onboardingCompleted: true)
    }

    /// Built from the recorded responses, so every number persisted here is one the API really sent.
    private func makeRecordedSnapshot() throws -> Snapshot {
        let holdings = try FixtureLoader.result(HoldingsOverview.self, from: FixtureLoader.Name.holdings)
        let rate = try FixtureLoader.result(ExchangeRate.self, from: FixtureLoader.Name.exchangeRate)
        let total = holdings.marketValue.totalKRW(usdKrwRate: rate.rate)

        return Snapshot(currentAssets: total,
                        perAccount: [1: total],
                        krwAmount: holdings.marketValue.krw,
                        usdAmount: holdings.marketValue.usd,
                        usdKrwRate: rate.rate,
                        cashKRW: nil,
                        fetchedAt: TestDate.kst("2026-09-06T17:51:58+09:00"),
                        status: .ok)
    }
}
