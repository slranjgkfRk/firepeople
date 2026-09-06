//
//  AppModel.swift
//  firepeople
//
//  The single source of truth for the app process: it owns the Keychain, the App Group stores, the
//  API client and the refresh service, and it publishes the handful of values the views render.
//
//  Views never do the arithmetic themselves — they read `state` (a `FireState`), `banner` and
//  `route`. Anything that changes what the home-screen widget shows ends in `WidgetRefresher.reload()`.
//

import Foundation
import Observation
import FireCore

#if canImport(SwiftUI)
import SwiftUI
#endif

// NOTE: SwiftUI also declares a `Settings` type, so every mention of the model type in this file is
// spelled `FireCore.Settings`.

/// The one banner slot on the main screen (README §2.6).
///
/// A failure banner always wins over ``targetPassed``: "your key stopped working" is more urgent
/// than "your goal date slipped by". `429` deliberately has no case — the client backs off and
/// retries silently (README §3.5).
enum AppBanner: Equatable, Sendable {
    /// No banner.
    case none
    /// Refresh failed for a network/server reason. The associated date is the still-valid
    /// `fetchedAt` of the preserved snapshot, rendered as `마지막 갱신 3시간 전`.
    case network(Date)
    /// 401 or bad credentials — `API 키를 확인해주세요`, tapping opens 설정.
    case authFailed
    /// 403 — this device's IP is not on the Toss allow-list. Never retried automatically.
    case ipBlocked
    /// The target date is in the past. Shown once per target date, then dismissed for good.
    case targetPassed
}

@MainActor
@Observable
final class AppModel {

    /// Which of the two top-level screens is on-screen.
    enum Route: Hashable, Sendable {
        case onboarding
        case main
    }

    /// Alias so call sites can spell the banner either way.
    typealias Banner = AppBanner

    // MARK: - Published state

    /// The user's two inputs plus their preferences.
    ///
    /// Assign to it directly (`model.settings.targetAmount = …`) or go through
    /// ``saveSettings(targetAmount:targetDate:selectedAccountSeqs:refreshPolicy:hideAmountInWidget:includeCash:)``:
    /// either way the change is written to the App Group store, `state` is recomputed, the widget is
    /// reloaded, and a change that invalidates the current numbers (a different set of accounts,
    /// 예수금 on/off) starts a refresh. README §2.3 "즉시 반영, 위젯 갱신".
    var settings: FireCore.Settings {
        didSet {
            guard !isApplyingStoredState, settings != oldValue else { return }
            applySettingsChange(from: oldValue)
        }
    }

    /// Last fetched (or last preserved) snapshot; `nil` before the first successful fetch and after
    /// a reset. Setting it re-renders the screen and the widget.
    ///
    /// Persisting is **not** done here on purpose: `RefreshService` already stored the successful
    /// fetch, and a failed refresh hands back the previous snapshot with a downgraded `status` that
    /// must stay in memory only — the widget should keep reading the last good one.
    var snapshot: Snapshot? {
        didSet {
            guard !isApplyingStoredState, snapshot != oldValue else { return }
            recomputeState()
            WidgetRefresher.reload()
        }
    }

    /// Everything the main screen and its components draw.
    private(set) var state: FireState

    /// A refresh is in flight. Drives the inline spinner only — the numbers are never blanked
    /// (README §2.2: 이전 값 유지가 원칙).
    private(set) var isRefreshing = false

    /// The banner currently shown at the top of the main screen.
    private(set) var banner: AppBanner = .none

    /// Onboarding until it is completed, main afterwards.
    private(set) var route: Route = .onboarding

    // MARK: - Owned collaborators

    /// Credentials and the shared access token. Exposed so a key-entry screen can write the keys
    /// straight to the Keychain (README §2.1) without a second abstraction in between.
    let keychain: KeychainStore

    /// Read-only Toss API — `연결 테스트` and the per-account 평가금액 preview use it directly.
    let client: TossClient

    private let settingsStore: any SettingsStoring
    private let snapshotStore: any SnapshotStoring
    private let refreshService: RefreshService
    /// Small non-secret UI flags (banner dismissals). Secrets never come near `UserDefaults`.
    private let flagDefaults: UserDefaults
    private let now: @Sendable () -> Date
    private let automaticallyRefreshes: Bool

    // MARK: - Internal bookkeeping

    private var hasBootstrapped = false
    /// Set while values loaded from disk are being installed, so the property observers do not
    /// treat a plain read-back as a user edit and bounce it straight back at the store.
    private var isApplyingStoredState = false
    /// The failure banner implied by the newest refresh result, before dismissal is applied.
    private var failureBanner: AppBanner = .none
    /// The failure banner the user closed; stays suppressed until the failure itself changes.
    private var dismissedFailureBanner: AppBanner = .none
    private var midnightTask: Task<Void, Never>?

    /// Remembers, per target date, that `목표일이 지났어요` was already shown and dismissed. Keyed by
    /// the date itself so moving the goal re-arms the banner for the new one.
    private static let targetPassedDismissKey = "banner.targetPassedDismissedFor.v1"

    // MARK: - Init

    /// - Parameters:
    ///   - settingsStore: defaults to the App Group store, falling back to an in-memory one when the
    ///     process has no App Group entitlement (previews, unentitled runs).
    ///   - snapshotStore: same fallback.
    ///   - keychain: the shared-access-group Keychain both the app and the widget read.
    ///   - defaults: App Group `UserDefaults`, used for the stores and for banner-dismissal flags.
    ///   - automaticallyRefreshes: previews pass `false` so rendering never touches the network.
    init(settingsStore: (any SettingsStoring)? = nil,
         snapshotStore: (any SnapshotStoring)? = nil,
         keychain: KeychainStore = KeychainStore(),
         defaults: UserDefaults? = AppGroup.defaults,
         automaticallyRefreshes: Bool = true,
         now: @Sendable @escaping () -> Date = Date.init) {

        if let settingsStore {
            self.settingsStore = settingsStore
        } else if let defaults {
            self.settingsStore = UserDefaultsSettingsStore(defaults: defaults)
        } else {
            self.settingsStore = InMemorySettingsStore()
        }

        if let snapshotStore {
            self.snapshotStore = snapshotStore
        } else if let defaults {
            self.snapshotStore = UserDefaultsSnapshotStore(defaults: defaults)
        } else {
            self.snapshotStore = InMemorySnapshotStore()
        }

        self.keychain = keychain
        self.flagDefaults = defaults ?? .standard
        self.now = now
        self.automaticallyRefreshes = automaticallyRefreshes

        // 15s request timeout for the app; the widget builds its own client with 10s (README §3.5).
        let client = TossClient(credentials: keychain,
                                tokenCache: keychain,
                                session: .fireDefault,
                                now: now)
        self.client = client
        self.refreshService = RefreshService(client: client,
                                             settingsStore: self.settingsStore,
                                             snapshotStore: self.snapshotStore,
                                             now: now)

        let settings = FireCore.Settings.fresh
        self.settings = settings
        self.state = FireState.make(settings: settings, snapshot: nil, now: now())
    }

    // MARK: - Lifecycle

    /// Loads what is on disk, picks the route and — on the main route — starts a refresh if the
    /// stored snapshot is stale.
    ///
    /// Synchronous and idempotent: call it from `.task`/`.onAppear` without worrying about how often
    /// the root view is re-created.
    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        isApplyingStoredState = true
        settings = settingsStore.load() ?? .fresh
        snapshot = snapshotStore.load()
        isApplyingStoredState = false

        route = settings.onboardingCompleted ? .main : .onboarding
        recomputeState()
        scheduleMidnightRollover()

        if route == .main, automaticallyRefreshes {
            Task { await refresh() }
        }
    }

    /// Recomputes `state` (and therefore the banner) against the current wall clock.
    ///
    /// Cheap and pure. Call it when the app returns to the foreground: the D-day number depends on
    /// the KST date, so a day that passed while the app was suspended has to be picked up.
    func recomputeState() {
        state = FireState.make(settings: settings, snapshot: snapshot, now: now())
        recomputeBanner()
    }

    /// `true` when the stored snapshot is older than the configured refresh interval (README §4.2).
    /// No snapshot at all counts as stale.
    var isSnapshotStale: Bool {
        guard let snapshot else { return true }
        return now().timeIntervalSince(snapshot.fetchedAt) >= settings.refreshPolicy.interval
    }

    /// `true` once `client_id`/`client_secret` are in the Keychain.
    var hasCredentials: Bool {
        ((try? keychain.credentials()) ?? nil) != nil
    }

    // MARK: - Refresh

    /// Fetches new numbers.
    ///
    /// - Parameter force: `true` for an explicit user action (pull-to-refresh, the retry button) —
    ///   it always hits the network. `false` refreshes only when the snapshot is stale, which is
    ///   what foregrounding uses.
    ///
    /// Never throws and never blanks the numbers: `RefreshService` hands back the previous snapshot
    /// with a downgraded status on failure, and that status becomes the banner (README §2.6).
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let result = force ? await refreshService.refresh() : await refreshService.refreshIfStale()

        if let result {
            failureBanner = Self.failureBanner(for: result)
        } else if force {
            // No snapshot at all *and* the fetch failed: README §2.6's "스냅샷 없음" state. The
            // service cannot say why, so ask the API — one `accounts` call — whether this is a key
            // or IP problem the user can actually fix.
            failureBanner = await diagnoseFailureWithoutSnapshot()
        } else {
            failureBanner = .none
        }

        if failureBanner == .none {
            dismissedFailureBanner = .none
        }

        // The observer recomputes and reloads the widget when the value really changed; the explicit
        // call after it covers a result that is equal but arrived with a new banner.
        snapshot = result
        recomputeState()
    }

    // MARK: - Settings

    /// Patches the stored settings: every parameter left `nil` keeps its current value.
    func saveSettings(targetAmount: Int? = nil,
                      targetDate: Date? = nil,
                      selectedAccountSeqs: [Int]? = nil,
                      refreshPolicy: RefreshPolicy? = nil,
                      hideAmountInWidget: Bool? = nil,
                      includeCash: Bool? = nil) {
        var updated = settings
        if let targetAmount { updated.targetAmount = targetAmount }
        if let targetDate { updated.targetDate = targetDate }
        if let selectedAccountSeqs { updated.selectedAccountSeqs = selectedAccountSeqs }
        if let refreshPolicy { updated.refreshPolicy = refreshPolicy }
        if let hideAmountInWidget { updated.hideAmountInWidget = hideAmountInWidget }
        if let includeCash { updated.includeCash = includeCash }
        saveSettings(updated)
    }

    /// Replaces the whole settings value; the property observer does the persisting.
    func saveSettings(_ newSettings: FireCore.Settings) {
        settings = newSettings
    }

    /// Convenience setters for the settings screen's rows (README §2.3).
    func setTargetAmount(_ amount: Int) { saveSettings(targetAmount: max(amount, 0)) }
    func setTargetDate(_ date: Date) { saveSettings(targetDate: date) }
    func setSelectedAccounts(_ seqs: [Int]) { saveSettings(selectedAccountSeqs: seqs) }
    func setRefreshPolicy(_ policy: RefreshPolicy) { saveSettings(refreshPolicy: policy) }
    func setHideAmountInWidget(_ hide: Bool) { saveSettings(hideAmountInWidget: hide) }
    func setIncludeCash(_ include: Bool) { saveSettings(includeCash: include) }

    /// Everything a settings change implies. Runs off the `settings` property observer.
    private func applySettingsChange(from oldValue: FireCore.Settings) {
        // A failed write is not worth an alert: the in-memory value still drives the screen and the
        // next successful save fixes the store. Nothing here is a secret, and nothing is logged.
        try? settingsStore.save(settings)

        if settings.onboardingCompleted != oldValue.onboardingCompleted {
            route = settings.onboardingCompleted ? .main : .onboarding
        }

        recomputeState()
        WidgetRefresher.reload()

        let assetsChanged = settings.selectedAccountSeqs != oldValue.selectedAccountSeqs
            || settings.includeCash != oldValue.includeCash
        if assetsChanged, hasBootstrapped, automaticallyRefreshes, route == .main {
            // The stored snapshot no longer matches the settings, so it has to be refetched rather
            // than waiting for the next interval.
            Task { await refresh(force: true) }
        }
    }

    // MARK: - Onboarding

    /// Stores the API keys in the Keychain and drops any token issued for the previous pair.
    ///
    /// README §2.1: 키는 Keychain에 즉시 저장. Nothing here — not the thrown error, not a log line —
    /// carries the key material.
    func saveCredentials(clientId: String, clientSecret: String) async throws {
        try keychain.saveCredentials(TokenCredentials(clientId: clientId, clientSecret: clientSecret))
        await client.invalidateToken()
    }

    /// Onboarding step [2]'s `연결 테스트`: issues a token and lists the accounts.
    func verifyConnection() async throws -> [TossAccount] {
        try await client.verifyConnection()
    }

    /// Finishes onboarding: adopts whatever the onboarding flow persisted, switches to the main
    /// screen, reloads the widget and fetches the first snapshot (README §2.1 step [5]).
    ///
    /// The onboarding flow owns its own stores and writes the target amount, date and account
    /// selection straight to the shared container, so this **re-reads** them instead of saving this
    /// object's older copy over the top.
    func completeOnboarding() {
        isApplyingStoredState = true
        snapshot = snapshotStore.load() ?? snapshot
        isApplyingStoredState = false

        var updated = settingsStore.load() ?? settings
        updated.onboardingCompleted = true
        settings = updated

        route = .main
        recomputeState()
        WidgetRefresher.reload()

        if automaticallyRefreshes {
            // Not forced: the onboarding flow stores the first snapshot itself, so this only fetches
            // when that did not happen or already went stale.
            Task { await refresh() }
        }
    }

    /// The name the onboarding flow's completion callback uses; identical to ``completeOnboarding()``.
    func onboardingDidFinish() {
        completeOnboarding()
    }

    /// README §2.3 `API 키 삭제 및 초기화` — wipes the Keychain, the snapshot, the settings and the
    /// banner flags, then drops back into onboarding. The widget is reloaded so it stops showing
    /// stale money on the home screen.
    func resetEverything() {
        try? keychain.clearAll()
        try? settingsStore.clear()
        try? snapshotStore.clear()
        flagDefaults.removeObject(forKey: Self.targetPassedDismissKey)

        failureBanner = .none
        dismissedFailureBanner = .none

        isApplyingStoredState = true
        snapshot = nil
        settings = .fresh
        isApplyingStoredState = false

        route = .onboarding
        recomputeState()
        WidgetRefresher.reload()

        Task { [client] in await client.invalidateToken() }
    }

    // MARK: - Banner

    /// Dismisses whatever banner is showing.
    ///
    /// A failure banner stays dismissed until the failure itself changes (a different status, or a
    /// newer preserved snapshot). `목표일 지남` is dismissed permanently for that target date, which
    /// is what makes it the "1회" banner README §2.6 asks for.
    func dismissBanner() {
        switch banner {
        case .none:
            return
        case .targetPassed:
            flagDefaults.set(settings.targetDate.timeIntervalSinceReferenceDate,
                             forKey: Self.targetPassedDismissKey)
        case .network, .authFailed, .ipBlocked:
            dismissedFailureBanner = failureBanner
        }
        recomputeBanner()
    }

    private func recomputeBanner() {
        if failureBanner != .none, failureBanner != dismissedFailureBanner {
            banner = failureBanner
        } else if state.dDay < 0, !isTargetPassedBannerDismissed {
            banner = .targetPassed
        } else {
            banner = .none
        }
    }

    private var isTargetPassedBannerDismissed: Bool {
        guard let dismissedFor = flagDefaults.object(forKey: Self.targetPassedDismissKey) as? Double
        else { return false }
        // One-second tolerance: settings round-trip through ISO-8601, which has whole-second
        // resolution.
        return abs(dismissedFor - settings.targetDate.timeIntervalSinceReferenceDate) < 1
    }

    /// Maps a snapshot's status onto the banner README §2.6 specifies for it.
    private static func failureBanner(for snapshot: Snapshot) -> AppBanner {
        switch snapshot.status {
        case .ok: .none
        case .staleNetwork: .network(snapshot.fetchedAt)
        case .authFailed: .authFailed
        case .ipBlocked: .ipBlocked
        }
    }

    /// Why did the very first refresh fail? `RefreshService` returns `nil` without a reason when
    /// there is no previous snapshot, so one `accounts` call (`ACCOUNT`, 1 rps) tells the user
    /// whether the key or the IP allow-list is at fault instead of leaving them at a bare retry
    /// button. A plain network failure stays banner-less — the retry state already says it.
    private func diagnoseFailureWithoutSnapshot() async -> AppBanner {
        guard hasCredentials else { return .none }
        do {
            _ = try await client.verifyConnection()
            return .none
        } catch let error as TossAPIError {
            if error.isAuthFailure { return .authFailed }
            if case .ipNotAllowed = error { return .ipBlocked }
            return .none
        } catch {
            return .none
        }
    }

    // MARK: - Midnight rollover

    /// Re-renders the D-day number when the KST date changes while the app stays open.
    ///
    /// `FireCalculator.upcomingMidnights` gives the exact next KST midnight, so this sleeps once per
    /// day instead of polling. The widget has its own timeline for the same job (README §4.2).
    private func scheduleMidnightRollover() {
        midnightTask?.cancel()
        midnightTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current = self.now()
                guard let nextMidnight = FireCalculator.upcomingMidnights(from: current, count: 1).first
                else { return }

                let delay = max(nextMidnight.timeIntervalSince(current), 1)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return  // cancelled
                }
                guard !Task.isCancelled else { return }
                self.recomputeState()
            }
        }
    }
}

#if canImport(SwiftUI)
extension AppModel {

    /// A `Binding` onto one settings field that persists (and reloads the widget) on every write.
    ///
    /// For rows that are naturally two-way — `Toggle(Strings.settingsHideAmountInWidget,
    /// isOn: model.binding(\.hideAmountInWidget))`, a `DatePicker` on `\.targetDate`. Anything that
    /// needs a draft value while the user types should keep its own `@State` and assign to
    /// `settings` (or call `saveSettings(…)`) on commit.
    func binding<Value>(_ keyPath: WritableKeyPath<FireCore.Settings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = self.settings
                updated[keyPath: keyPath] = newValue
                self.settings = updated
            }
        )
    }
}
#endif
