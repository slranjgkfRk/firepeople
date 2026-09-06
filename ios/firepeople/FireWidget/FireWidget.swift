//
//  FireWidget.swift
//  FireWidget
//
//  The single `StaticConfiguration` this extension ships. There is nothing to
//  configure per-instance: the target amount, the target date and the
//  "위젯에 금액 숨기기" toggle all live in the App Group `Settings`, so every
//  placed instance renders the same numbers and an intent configuration would
//  only add a second place for the user to be confused by.
//

import SwiftUI
import WidgetKit
import FireCore

/// The deep link the widget hands the app when the user taps it (README §2.4:
/// "위젯을 탭하면 앱 메인 화면이 열린다").
///
/// WidgetKit opens the containing app directly, so the tap works even before the
/// app registers the scheme; declaring `CFBundleURLTypes` in the app only matters
/// if the same URL should be openable from elsewhere. The app routes it in
/// `onOpenURL`.
enum FireWidgetLink {
    static let scheme = "firepeople"
    static let main = URL(string: "firepeople://main")!
}

struct FireWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppGroup.widgetKind, provider: FireTimelineProvider()) { entry in
            FireWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("FIRE D-Day")
        .description("FIRE 목표까지 남은 날과 진행률을 보여줍니다.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
        ])
    }
}
