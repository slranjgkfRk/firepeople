//
//  FireWidgetEntryView.swift
//  FireWidget
//
//  README §2.4 홈 위젯:
//    Small  — `D-1,234` 크게, 아래에 작게 `61.2%`
//    Medium — 좌: `D-1,234` + 예정일 / 우: 진행 바 + % + `1.2억 / 2.0억`
//             (설정 "위젯에 금액 숨기기"가 켜져 있으면 금액 줄이 사라진다)
//
//  Every number on screen is rendered by `FireFormatter` — the D-day grouping,
//  the one-decimal percentage and the 억/만 abbreviations are not re-implemented
//  here, so the widget and the app can never disagree about a value.
//

import SwiftUI
import WidgetKit
import FireCore

// MARK: - Family router

/// Picks the layout for the family being rendered and applies the iOS 17
/// `containerBackground`, which is mandatory — a widget without one is clipped to
/// nothing on iOS 17+.
struct FireWidgetEntryView: View {

    @Environment(\.widgetFamily) private var family

    let entry: FireEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(FireWidgetLink.main)
        case .accessoryRectangular:
            RectangularWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
                .widgetURL(FireWidgetLink.main)
        case .accessoryCircular:
            CircularWidgetView(entry: entry)
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
                .widgetURL(FireWidgetLink.main)
        default:
            // .systemSmall and any family a future OS adds.
            SmallWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(FireWidgetLink.main)
        }
    }
}

// MARK: - Small

/// D-day dominates; the percentage sits underneath at a fraction of the size.
struct SmallWidgetView: View {

    let entry: FireEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(WidgetStrings.untilFire)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if entry.isConfigured {
                Text(entry.dDayText)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)

                Text(entry.percentText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Text(WidgetStrings.needsSetup)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Medium

/// Left column carries the countdown, right column the progress.
struct MediumWidgetView: View {

    let entry: FireEntry

    var body: some View {
        if entry.isConfigured {
            HStack(alignment: .center, spacing: 14) {
                countdown
                Spacer(minLength: 0)
                progress
                    .frame(maxWidth: 170, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(WidgetStrings.untilFire)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(WidgetStrings.needsSetup)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var countdown: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(WidgetStrings.untilFire)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(entry.dDayText)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.4)

            Text(FireFormatter.targetDate(entry.state.targetDate))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetProgressBar(fraction: entry.barFraction, isGoalReached: entry.state.isGoalReached)

            Text(entry.percentText)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            // README §2.6 — once the goal is met the amount line becomes 목표 달성,
            // which is also the only line README §2.4's privacy toggle removes.
            if entry.state.isGoalReached {
                Text(WidgetStrings.goalReached)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if !entry.hideAmount {
                Text(entry.amountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

// MARK: - Components

/// A plain capacity bar. Rounded caps, and README §2.6's colour change once the
/// goal is met (the fill also saturates at 100% — `progress` may exceed 1.0).
struct WidgetProgressBar: View {

    let fraction: Double
    let isGoalReached: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.25))

                Capsule(style: .continuous)
                    .fill(isGoalReached ? Color.green : Color.accentColor)
                    .frame(width: max(geometry.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// The handful of Korean strings the widget owns. README §2.2 supplies "FIRE까지"
/// verbatim; the rest are widget-only.
enum WidgetStrings {
    static let untilFire = "FIRE까지"
    static let needsSetup = "앱에서 목표를 설정해주세요"
    static let goalReached = "목표 달성"
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    FireWidget()
} timeline: {
    FireTimelineProvider.placeholderEntry(now: Date())
}

#Preview("Medium", as: .systemMedium) {
    FireWidget()
} timeline: {
    FireTimelineProvider.placeholderEntry(now: Date())
}
