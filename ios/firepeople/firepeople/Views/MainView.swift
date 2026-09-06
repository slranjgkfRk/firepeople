//
//  MainView.swift
//  firepeople
//
//  README §2.2 — the whole product:
//
//      ┌──────────────────────────────┐
//      │  FIRE까지                     │
//      │                              │
//      │         D-1,234              │  ← 화면의 60% 크기. 이게 앱이다
//      │                              │
//      │  2029.12.31 (수)              │
//      │                              │
//      │  ████████████░░░░░░░  61.2%  │
//      │  1억 2,345만원 / 2억원          │
//      │  남은 금액 7,655만원            │
//      │                              │
//      │  마지막 갱신 오늘 14:00         │
//      │                        ⚙     │
//      └──────────────────────────────┘
//
//  Rules that are easy to break and must not be:
//  · The numbers are never blanked while refreshing — only a small spinner appears (README §2.2).
//  · Colours are semantic, so dark mode is whatever the system says (README §2.2).
//  · Every §2.6 state is reachable from here: 100%+, D-DAY, D+n, network/auth/IP banners, and the
//    no-snapshot `--%` + retry state.
//

import SwiftUI
import FireCore

struct MainView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSettings = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                content(availableHeight: proxy.size.height)
                    .frame(minHeight: proxy.size.height, alignment: .top)
            }
            // The content usually fits exactly, and a ScrollView that cannot scroll cannot be
            // pulled: force bounce so pull-to-refresh is always available (README §2.2).
            .scrollBounceBehavior(.always)
            .refreshable {
                await model.refresh(force: true)
            }
        }
        // `SettingsView` brings its own `NavigationStack` and 완료 button, so it is presented bare.
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            // A day may have passed while the app was suspended — the D-day number is a function of
            // the KST date, so recompute before deciding whether the network is even needed.
            model.recomputeState()
            guard model.isSnapshotStale else { return }
            Task { await model.refresh() }
        }
        .animation(.easeInOut(duration: 0.25), value: model.banner)
        .animation(.easeInOut(duration: 0.25), value: model.state)
        .animation(.easeInOut(duration: 0.2), value: model.isRefreshing)
    }

    // MARK: - Layout

    private func content(availableHeight: CGFloat) -> some View {
        let state = model.state
        let now = Date()

        return VStack(alignment: .leading, spacing: 0) {
            if model.banner != .none {
                BannerView(banner: model.banner,
                           now: now,
                           onTap: { handleBannerTap() },
                           onDismiss: { model.dismissBanner() })
                    .padding(.bottom, 18)
            }

            Text(Strings.fireUntil)
                .font(.headline)
                .foregroundStyle(.secondary)

            dDayNumber(state: state, height: Self.dDayBlockHeight(in: availableHeight))

            Text(FireFormatter.targetDate(state.targetDate))
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 28)

            progressSection(state: state)

            Spacer(minLength: 24)

            footer(state: state, now: now)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// The number that *is* the app: about 60% of the height, rounded, monospaced digits so the
    /// glyphs do not jitter when the count changes, shrink-to-fit on narrow screens.
    private func dDayNumber(state: FireState, height: CGFloat) -> some View {
        Text(FireFormatter.dDay(state.dDay))
            .font(.system(size: min(height * 0.72, 260), weight: .heavy, design: .rounded)
                .monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.1)
            .contentTransition(.numericText())
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .accessibilityLabel(Strings.dDayAccessibilityLabel(state.dDay))
    }

    private func progressSection(state: FireState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ProgressBarView(progress: state.progress, isUnavailable: !state.hasSnapshot)

                Text(state.hasSnapshot ? FireFormatter.percent(state.progress) : Strings.percentPlaceholder)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(state.isGoalReached ? Color.green : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minWidth: 72, alignment: .trailing)
            }

            amountsLine(state: state)
            statusLine(state: state)
        }
    }

    /// `1억 2,345만원 / 2억원` — README §2.5 body format on both sides.
    private func amountsLine(state: FireState) -> some View {
        let current = state.hasSnapshot
            ? FireFormatter.amountKo(state.currentAssets)
            : Strings.amountPlaceholder
        let line = current + " " + Strings.amountSeparator + " " + FireFormatter.amountKo(state.targetAmount)
        // `Text(String)` on purpose: a literal with interpolation would become a LocalizedStringKey
        // and send every formatted amount through a lookup that does not exist.
        return Text(line)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// 남은 금액 → `목표 달성` at 100% (README §2.6), or the retry button when nothing was ever
    /// fetched. The retry button replaces this line rather than the numbers above it.
    @ViewBuilder
    private func statusLine(state: FireState) -> some View {
        if !state.hasSnapshot {
            Button {
                Task { await model.refresh(force: true) }
            } label: {
                Label(Strings.retry, systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshing)
        } else if state.isGoalReached {
            Label(Strings.goalReached, systemImage: "checkmark.seal.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.green)
        } else {
            Text(Strings.remainingPrefix + " " + FireFormatter.amountKo(state.remaining))
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// `마지막 갱신 오늘 14:00`, the inline refresh spinner, and ⚙.
    private func footer(state: FireState, now: Date) -> some View {
        HStack(spacing: 10) {
            Text(lastUpdatedText(state: state, now: now))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Strings.refreshing)
            }

            Spacer(minLength: 8)

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.settingsAccessibilityLabel)
        }
    }

    private func lastUpdatedText(state: FireState, now: Date) -> String {
        guard let fetchedAt = state.fetchedAt else { return Strings.neverUpdated }
        return "\(Strings.lastUpdatedPrefix) \(FireFormatter.refreshedAt(fetchedAt, now: now))"
    }

    // MARK: - Actions

    /// README §2.6: the key and IP banners open 설정 ("탭하면 설정"), and so does the 목표일 지남
    /// banner, which exists to nudge the user into editing the date. The network banner retries.
    private func handleBannerTap() {
        switch model.banner {
        case .authFailed, .ipBlocked, .targetPassed:
            isShowingSettings = true
        case .network:
            Task { await model.refresh(force: true) }
        case .none:
            break
        }
    }

    /// ~60% of the available height, floored so the number never disappears on a small screen and
    /// capped so the rows below it are never pushed out of view.
    private static func dDayBlockHeight(in availableHeight: CGFloat) -> CGFloat {
        guard availableHeight > 0 else { return 180 }
        let spaceForEverythingElse: CGFloat = 300
        return max(min(availableHeight * 0.6, availableHeight - spaceForEverythingElse), 140)
    }
}

#if DEBUG

/// Obviously synthetic preview data — the README's own illustration numbers, never a fetched
/// response (CONTRACT § On "no mock data").
@MainActor
private func previewModel(snapshot: Snapshot?,
                          targetAmount: Int = 200_000_000,
                          dayOffset: Int = 1234) -> AppModel {
    let today = FireCalculator.kstMidnight(of: Date())
    let targetDate = Calendar.seoul.date(byAdding: .day, value: dayOffset, to: today) ?? today
    let settings = FireCore.Settings(targetAmount: targetAmount,
                                     targetDate: targetDate,
                                     selectedAccountSeqs: [1],
                                     refreshPolicy: .hourly,
                                     hideAmountInWidget: false,
                                     includeCash: false,
                                     onboardingCompleted: true)
    let model = AppModel(settingsStore: InMemorySettingsStore(settings),
                         snapshotStore: InMemorySnapshotStore(snapshot),
                         defaults: nil,
                         automaticallyRefreshes: false)
    model.bootstrap()
    return model
}

private func previewSnapshot(currentAssets: Int, status: FetchStatus = .ok) -> Snapshot {
    Snapshot(currentAssets: currentAssets,
             perAccount: [1: currentAssets],
             krwAmount: Decimal(currentAssets),
             usdAmount: 0,
             usdKrwRate: Decimal(string: "1353.1") ?? 1,
             cashKRW: nil,
             fetchedAt: Date().addingTimeInterval(-2 * 3600),
             status: status)
}

#Preview("메인 · 진행 중") {
    MainView()
        .environment(previewModel(snapshot: previewSnapshot(currentAssets: 123_450_000)))
}

#Preview("메인 · 목표 달성") {
    MainView()
        .environment(previewModel(snapshot: previewSnapshot(currentAssets: 207_400_000), dayOffset: 0))
}

#Preview("메인 · 스냅샷 없음") {
    MainView()
        .environment(previewModel(snapshot: nil))
}

#endif
