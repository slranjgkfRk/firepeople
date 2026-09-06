//
//  FireTimelineProvider.swift
//  FireWidget
//
//  README §4.2. Two things happen on every timeline request:
//
//    1. `RefreshService.refreshIfStale()` is attempted over the App Group stores
//       with a 10s session (the app uses 15s). It never throws: a failure hands
//       back the previously stored snapshot with `status` downgraded, so the
//       widget renders the last known numbers instead of going blank.
//    2. One entry is emitted per KST midnight for the next 7 days, all carrying
//       the *same* asset numbers with the D-day recomputed for that day. That is
//       what makes the number roll over at midnight with no network at all —
//       the single most important widget requirement in the README.
//
//  Only `placeholder(in:)` is allowed to invent numbers, and the ones it invents
//  are obviously synthetic (D-1,000 · 50.0% · 1.0억 / 2.0억).
//

import Foundation
import WidgetKit
import FireCore

// MARK: - Entry

/// One rendered moment. `state` is already computed for `date`, so the views do
/// no date math and the app and widget cannot drift apart.
struct FireEntry: TimelineEntry, Sendable, Equatable {

    /// When this entry becomes the visible one.
    let date: Date

    /// Everything the views read (README: views never touch `Snapshot`/`Settings`).
    let state: FireState

    /// `Settings.hideAmountInWidget` — drops the amount row on the medium family.
    let hideAmount: Bool

    /// `false` before the user has set a 목표 금액; the views then prompt instead of
    /// rendering a D-day derived from the default ten-years-out placeholder date.
    let isConfigured: Bool

    /// `"D-1,234"` / `"D-DAY"` / `"D+12"`.
    var dDayText: String { FireFormatter.dDay(state.dDay) }

    /// `"61.2%"`, or README §2.6's `"--%"` while no snapshot has ever been stored.
    var percentText: String { state.hasSnapshot ? FireFormatter.percent(state.progress) : "--%" }

    /// `"1.2억 / 2.0억"` — README §2.5 위젯 축약 금액, both sides via `FireFormatter`.
    var amountText: String {
        "\(FireFormatter.amountCompact(state.currentAssets)) / \(FireFormatter.amountCompact(state.targetAmount))"
    }

    /// The progress bar's fill fraction. `progress` may exceed 1.0; a bar cannot.
    var barFraction: Double {
        guard state.progress.isFinite else { return 0 }
        return min(max(state.progress, 0), 1)
    }
}

// MARK: - Provider

struct FireTimelineProvider: TimelineProvider {

    typealias Entry = FireEntry

    /// How many KST midnights are pre-populated (README §4.2: "앞으로 7일").
    static let midnightEntryCount = 7

    /// Widget request timeout. The app uses 15s; a widget gets a much smaller
    /// budget from the OS, so it gives up sooner and renders the stored snapshot
    /// (README §3.5 "요청 타임아웃: 앱 15s, 위젯 10s").
    static let requestTimeout: TimeInterval = 10

    // MARK: TimelineProvider

    /// The gallery / redacted state. **The only place synthetic numbers exist**,
    /// and they are deliberately round so they can never be mistaken for a real
    /// portfolio: D-1,000, 50.0%, 1.0억 / 2.0억.
    nonisolated func placeholder(in context: Context) -> FireEntry {
        Self.placeholderEntry(now: Date())
    }

    /// Previews get the synthetic placeholder; everything else gets the real
    /// stored snapshot. No network here — `getSnapshot` must return fast, and the
    /// timeline request that follows does the refreshing.
    nonisolated func getSnapshot(in context: Context, completion: @escaping (FireEntry) -> Void) {
        let isPreview = context.isPreview
        let sink = CompletionSink(completion)
        Task {
            let now = Date()
            guard !isPreview else { return sink.finish(Self.placeholderEntry(now: now)) }
            let payload = WidgetData.stored()
            sink.finish(Self.entries(for: payload, now: now, dates: [now])[0])
        }
    }

    /// Attempt a refresh, then emit today plus the next seven KST midnights.
    nonisolated func getTimeline(in context: Context, completion: @escaping (Timeline<FireEntry>) -> Void) {
        let sink = CompletionSink(completion)
        Task {
            let now = Date()
            // Never throws, and never returns less than what was already stored.
            let payload = await WidgetData.refreshedIfStale(timeout: Self.requestTimeout)
            let dates = [now] + FireCalculator.upcomingMidnights(from: now, count: Self.midnightEntryCount)
            let entries = Self.entries(for: payload, now: now, dates: dates)
            let policy = Self.reloadPolicy(for: payload.settings?.refreshPolicy ?? .hourly, now: now)
            sink.finish(Timeline(entries: entries, policy: policy))
        }
    }

    // MARK: Entry construction

    /// One entry per date in `dates`, every one of them carrying the *same*
    /// snapshot. `FireState.make(settings:snapshot:now:)` recomputes only the
    /// D-day, which is exactly the offline midnight rollover README §4.2 asks for.
    nonisolated static func entries(for payload: WidgetData.Payload, now: Date, dates: [Date]) -> [FireEntry] {
        let settings = payload.settings ?? .fresh
        let isConfigured = (payload.settings?.targetAmount ?? 0) > 0
        let entryDates = dates.isEmpty ? [now] : dates

        return entryDates.map { date in
            FireEntry(
                date: date,
                state: FireState.make(settings: settings, snapshot: payload.snapshot, now: date),
                hideAmount: settings.hideAmountInWidget,
                isConfigured: isConfigured
            )
        }
    }

    /// README §4.2: `매시간` → `.after(now + 1h)`, `하루 1회` → `.after(다음 18:00 KST)`.
    ///
    /// The midnight entries above already cover the D-day rollover, so this policy
    /// only governs when new *asset* numbers are fetched.
    nonisolated static func reloadPolicy(for policy: RefreshPolicy, now: Date) -> TimelineReloadPolicy {
        switch policy {
        case .hourly:
            return .after(now.addingTimeInterval(policy.interval))
        case .daily:
            return .after(nextEveningReload(after: now))
        }
    }

    /// The next 18:00 in Asia/Seoul strictly after `now`.
    nonisolated static func nextEveningReload(after now: Date, calendar: Calendar = .seoul) -> Date {
        // `direction: .forward` already rolls to tomorrow when 18:00 has passed;
        // the comparison and the fallback are belt-and-braces for a calendar that
        // fails to match (Asia/Seoul has no DST, so it does not happen here).
        if let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now), evening > now {
            return evening
        }
        let midnight = FireCalculator.kstMidnight(of: now, calendar: calendar)
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: midnight),
           let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow),
           evening > now {
            return evening
        }
        return now.addingTimeInterval(RefreshPolicy.daily.interval)
    }

    // MARK: Placeholder

    /// Synthetic, and unmistakably so. Round numbers only — see the file header.
    nonisolated static func placeholderEntry(now: Date) -> FireEntry {
        let dDay = 1_000
        let targetDate = Calendar.seoul.date(byAdding: .day, value: dDay, to: FireCalculator.kstMidnight(of: now))
            ?? now
        let targetAmount = 200_000_000
        let currentAssets = 100_000_000

        return FireEntry(
            date: now,
            state: FireState(
                dDay: dDay,
                progress: 0.5,
                currentAssets: currentAssets,
                targetAmount: targetAmount,
                remaining: targetAmount - currentAssets,
                targetDate: targetDate,
                fetchedAt: now,
                status: .ok
            ),
            hideAmount: false,
            isConfigured: true
        )
    }
}

// MARK: - Shared-container access

/// Builds the App Group / Keychain stack the widget shares with the app and reads
/// (or refreshes) through it.
///
/// The widget is a second process on the *same* API client, and only one access
/// token may exist per client (`docs/api-notes.md` § Auth), which is why the token
/// comes from the shared-access-group `KeychainStore` rather than a private cache.
enum WidgetData {

    /// What one timeline request needs from disk. Both members are `Sendable`.
    struct Payload: Sendable {
        let settings: Settings?
        let snapshot: Snapshot?

        static let empty = Payload(settings: nil, snapshot: nil)
    }

    /// Reads the shared container without touching the network.
    nonisolated static func stored() -> Payload {
        guard let defaults = AppGroup.defaults else { return .empty }
        return Payload(
            settings: UserDefaultsSettingsStore(defaults: defaults).load(),
            snapshot: UserDefaultsSnapshotStore(defaults: defaults).load()
        )
    }

    /// Attempts `RefreshService.refreshIfStale()` and falls back to whatever is on
    /// disk. `refreshIfStale` never throws and already returns the previous
    /// snapshot (with a downgraded `status`) when the network is down; the extra
    /// `?? stored` covers the one case it returns `nil` — a failed fetch with
    /// nothing stored yet.
    nonisolated static func refreshedIfStale(timeout: TimeInterval) async -> Payload {
        guard let defaults = AppGroup.defaults else { return .empty }

        let settingsStore = UserDefaultsSettingsStore(defaults: defaults)
        let snapshotStore = UserDefaultsSnapshotStore(defaults: defaults)
        let settings = settingsStore.load()

        // Nothing to fetch for yet: skip the round trip entirely rather than
        // burning a token issue on an account list that was never selected.
        guard let settings, !settings.selectedAccountSeqs.isEmpty else {
            return Payload(settings: settings, snapshot: snapshotStore.load())
        }

        let keychain = KeychainStore()
        let client = TossClient(
            credentials: keychain,
            tokenCache: keychain,
            session: .fire(timeout: timeout)
        )
        let service = RefreshService(
            client: client,
            settingsStore: settingsStore,
            snapshotStore: snapshotStore
        )

        let snapshot = await service.refreshIfStale() ?? snapshotStore.load()
        return Payload(settings: settings, snapshot: snapshot)
    }
}

// MARK: - Completion bridging

/// Carries WidgetKit's completion closure into the `Task` that does the async
/// work, and guarantees it is called exactly once.
///
/// The current SDK types those completions `@escaping @Sendable`, but the
/// requirement is `@preconcurrency` and older SDKs omit the annotation. Declaring
/// the witness *without* `@Sendable` matches both (a `@Sendable` argument is a
/// subtype of a plain one), and this box is what then lets the non-`Sendable`
/// parameter cross into the task under Swift 6 strict concurrency — instead of
/// pinning the code to one SDK's annotations.
private final class CompletionSink<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Value) -> Void)?

    init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    func finish(_ value: Value) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(value)
    }
}
