import Foundation

/// The single refresh path shared by the app and the widget (README §4.1).
///
/// It reads `Settings`, fetches the USD→KRW rate plus the market value of every selected account,
/// converts everything to KRW and persists a `Snapshot`. Views never call the API themselves; they
/// render from the `Snapshot` this service produces.
///
/// `FireCore` depends on Foundation alone so `swift test` runs on macOS without Xcode; reloading the
/// home-screen widget's timelines after a successful refresh is therefore the *caller's* job.
public actor RefreshService {

    /// `ASSET` allows 5 rps; overlap account fetches but stay under the limit (docs/api-notes.md).
    private static let maxConcurrentHoldingsFetches = 4

    /// `ORDER_INFO` allows 6 rps and only 3 rps between 09:00–09:10 KST, and every account costs two
    /// requests (KRW + USD), so the cash window is deliberately narrower.
    private static let maxConcurrentCashFetches = 3

    private let client: any TossReadOnlyAPI
    private let settingsStore: any SettingsStoring
    private let snapshotStore: any SnapshotStoring
    private let now: @Sendable () -> Date

    public init(client: any TossReadOnlyAPI,
                settingsStore: any SettingsStoring,
                snapshotStore: any SnapshotStoring,
                now: @Sendable @escaping () -> Date = Date.init) {
        self.client = client
        self.settingsStore = settingsStore
        self.snapshotStore = snapshotStore
        self.now = now
    }

    // MARK: - Entry points

    /// Fetches everything and persists a fresh `Snapshot`.
    ///
    /// Never throws. On any failure it returns the previously stored snapshot with only `status`
    /// downgraded (`.staleNetwork` / `.authFailed` / `.ipBlocked`) and `fetchedAt` **unchanged**, so
    /// the UI can keep rendering the last known numbers and say how old they are (README §2.6).
    /// Returns `nil` only when the fetch failed and there is no previous snapshot at all.
    @discardableResult
    public func refresh() async -> Snapshot? {
        let previous = snapshotStore.load()

        // Nothing configured yet: leave the stored snapshot exactly as it is.
        guard let settings = settingsStore.load() else { return previous }
        let accountSeqs = Self.orderedUniqueSeqs(settings.selectedAccountSeqs)
        guard !accountSeqs.isEmpty else { return previous }

        do {
            let snapshot = try await fetchSnapshot(accountSeqs: accountSeqs,
                                                   includeCash: settings.includeCash)
            // A storage failure must not hide a good fetch; the fresh values are still returned.
            try? snapshotStore.save(snapshot)
            return snapshot
        } catch {
            guard var downgraded = previous else { return nil }
            downgraded.status = Self.status(for: error)
            return downgraded
        }
    }

    /// Refreshes only when the stored snapshot is older than `Settings.refreshPolicy.interval`;
    /// otherwise it hands back the stored snapshot untouched. Foreground and widget-timeline entry
    /// point (README §4.2). With no stored snapshot it always refreshes.
    @discardableResult
    public func refreshIfStale() async -> Snapshot? {
        guard let stored = snapshotStore.load(), let settings = settingsStore.load() else {
            return await refresh()
        }
        let age = now().timeIntervalSince(stored.fetchedAt)
        guard age >= settings.refreshPolicy.interval else { return stored }
        return await refresh()
    }

    // MARK: - Fetch

    private func fetchSnapshot(accountSeqs: [Int], includeCash: Bool) async throws -> Snapshot {
        // FX first: every conversion below needs it, and it is a single `MARKET_INFO` request.
        let usdKrwRate = try await client.exchangeRate(base: .usd, quote: .krw).rate

        let holdings = try await mapAccountsConcurrently(
            accountSeqs: accountSeqs,
            maxConcurrent: Self.maxConcurrentHoldingsFetches
        ) { [client] accountSeq in
            try await client.holdings(accountSeq: accountSeq)
        }

        var perAccount: [Int: Int] = [:]
        perAccount.reserveCapacity(accountSeqs.count)
        var krwAmount: Decimal = 0
        var usdAmount: Decimal = 0

        // Iterate the selected order, not the dictionary's, so the sums are bit-for-bit repeatable.
        for accountSeq in accountSeqs {
            guard let overview = holdings[accountSeq] else {
                throw TossAPIError.decoding("holdings missing for account \(accountSeq)")
            }
            let marketValue = overview.marketValue
            perAccount[accountSeq] = marketValue.totalKRW(usdKrwRate: usdKrwRate)
            krwAmount += marketValue.krw
            usdAmount += marketValue.usd
        }

        // Round the aggregate once, exactly as docs/api-notes.md computes `currentAssets`:
        // marketValue.amount.krw + marketValue.amount.usd × usdKrwRate.
        var currentAssets = MoneyByCurrency(krw: krwAmount, usd: usdAmount)
            .totalKRW(usdKrwRate: usdKrwRate)

        var cashKRW: Int?
        if includeCash {
            let cash = try await fetchCashKRW(accountSeqs: accountSeqs, usdKrwRate: usdKrwRate)
            cashKRW = cash
            currentAssets += cash
        }

        return Snapshot(currentAssets: currentAssets,
                        perAccount: perAccount,
                        krwAmount: krwAmount,
                        usdAmount: usdAmount,
                        usdKrwRate: usdKrwRate,
                        cashKRW: cashKRW,
                        fetchedAt: now(),
                        status: .ok)
    }

    /// `cashBuyingPower(KRW) + cashBuyingPower(USD) × usdKrwRate`, summed over the selected accounts
    /// and rounded like every other conversion (docs/api-notes.md § buying-power).
    private func fetchCashKRW(accountSeqs: [Int], usdKrwRate: Decimal) async throws -> Int {
        let cash = try await mapAccountsConcurrently(
            accountSeqs: accountSeqs,
            maxConcurrent: Self.maxConcurrentCashFetches
        ) { [client] accountSeq in
            let krw = try await client.cashBuyingPower(accountSeq: accountSeq, currency: .krw)
            let usd = try await client.cashBuyingPower(accountSeq: accountSeq, currency: .usd)
            return CashBuyingPower(krw: krw, usd: usd)
        }

        var krw: Decimal = 0
        var usd: Decimal = 0
        for accountSeq in accountSeqs {
            guard let amounts = cash[accountSeq] else {
                throw TossAPIError.decoding("buying power missing for account \(accountSeq)")
            }
            krw += amounts.krw
            usd += amounts.usd
        }
        return MoneyByCurrency(krw: krw, usd: usd).totalKRW(usdKrwRate: usdKrwRate)
    }

    /// Runs `fetch` for every account with a bounded number of requests in flight, keyed by
    /// `accountSeq` so the caller can rebuild a deterministic order. The first failure cancels the
    /// rest and propagates: a silently low total would be worse than a stale one.
    private func mapAccountsConcurrently<Value: Sendable>(
        accountSeqs: [Int],
        maxConcurrent: Int,
        fetch: @escaping @Sendable (Int) async throws -> Value
    ) async throws -> [Int: Value] {
        try await withThrowingTaskGroup(of: KeyedValue<Value>.self,
                                        returning: [Int: Value].self) { group in
            var results: [Int: Value] = [:]
            results.reserveCapacity(accountSeqs.count)

            var pending = 0
            let window = min(max(maxConcurrent, 1), accountSeqs.count)
            while pending < window {
                let accountSeq = accountSeqs[pending]
                group.addTask {
                    KeyedValue(accountSeq: accountSeq, value: try await fetch(accountSeq))
                }
                pending += 1
            }

            while let keyed = try await group.next() {
                results[keyed.accountSeq] = keyed.value
                if pending < accountSeqs.count {
                    let accountSeq = accountSeqs[pending]
                    group.addTask {
                        KeyedValue(accountSeq: accountSeq, value: try await fetch(accountSeq))
                    }
                    pending += 1
                }
            }
            return results
        }
    }

    // MARK: - Helpers

    /// README §2.6 maps the failure onto the banner: 403 tells the user to register their IP, a 401
    /// or bad credentials tell them to check the key, everything else is "just" stale data.
    private static func status(for error: Error) -> FetchStatus {
        guard let apiError = error as? TossAPIError else { return .staleNetwork }
        if apiError.isAuthFailure { return .authFailed }
        if case .ipNotAllowed = apiError { return .ipBlocked }
        return .staleNetwork
    }

    /// Preserves the user's selection order and drops duplicates, which would otherwise be counted
    /// twice in the totals.
    private static func orderedUniqueSeqs(_ seqs: [Int]) -> [Int] {
        var seen = Set<Int>()
        var ordered: [Int] = []
        ordered.reserveCapacity(seqs.count)
        for seq in seqs where seen.insert(seq).inserted {
            ordered.append(seq)
        }
        return ordered
    }
}

// MARK: - Private transport-free value types

private struct KeyedValue<Value: Sendable>: Sendable {
    let accountSeq: Int
    let value: Value
}

private struct CashBuyingPower: Sendable {
    let krw: Decimal
    let usd: Decimal
}
