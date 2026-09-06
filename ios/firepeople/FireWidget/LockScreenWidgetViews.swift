//
//  LockScreenWidgetViews.swift
//  FireWidget
//
//  README §2.4 잠금화면 위젯. The README left the shape `[TBD]` between "원형
//  게이지로 %" and "인라인 텍스트 `D-1,234 · 61%`" — both are built, one per family:
//
//    .accessoryRectangular — `D-1,234 · 61.2%` on one line, 예정일 underneath
//    .accessoryCircular    — a `Gauge` ring for the progress with the % inside
//
//  The percentage keeps README §2.5's one decimal place (that table is the
//  authoritative format rule; the `61%` in §2.4 sits under the `[TBD]` marker),
//  and it comes from `FireFormatter.percent` like everywhere else.
//
//  Lock-screen families render monochrome through the widget rendering mode, so
//  these views carry no colour of their own — only weight and size.
//

import SwiftUI
import WidgetKit
import FireCore

// MARK: - Rectangular

struct RectangularWidgetView: View {

    let entry: FireEntry

    /// `"D-1,234 · 61.2%"`. Both halves via `FireFormatter`.
    private var headline: String {
        "\(entry.dDayText) · \(entry.percentText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(WidgetStrings.untilFire)
                .font(.caption2)
                .widgetAccentable()

            if entry.isConfigured {
                Text(headline)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text(FireFormatter.targetDate(entry.state.targetDate))
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(WidgetStrings.needsSetup)
                    .font(.caption)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Circular

struct CircularWidgetView: View {

    let entry: FireEntry

    var body: some View {
        Gauge(value: entry.isConfigured ? entry.barFraction : 0, in: 0...1) {
            Text(WidgetStrings.untilFire)
        } currentValueLabel: {
            Text(entry.isConfigured ? entry.percentText : "--%")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }
}

// MARK: - Previews

#Preview("Rectangular", as: .accessoryRectangular) {
    FireWidget()
} timeline: {
    FireTimelineProvider.placeholderEntry(now: Date())
}

#Preview("Circular", as: .accessoryCircular) {
    FireWidget()
} timeline: {
    FireTimelineProvider.placeholderEntry(now: Date())
}
