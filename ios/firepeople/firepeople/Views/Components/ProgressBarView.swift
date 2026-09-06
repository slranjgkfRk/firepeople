//
//  ProgressBarView.swift
//  firepeople
//
//  The `████████████░░░░░░░` row of README §2.2, and the only place the 100% colour change of
//  README §2.6 is implemented.
//

import SwiftUI
import FireCore

#if canImport(UIKit)
import UIKit
#endif

/// A flat capsule progress bar driven by `FireState.progress`.
///
/// The ratio may exceed `1.0` (over-achieved goals are allowed to read `103.7%`); the fill clamps at
/// full width and switches colour instead, which is README §2.6's "진행률 바 가득 + 색 변경".
struct ProgressBarView: View {

    /// `currentAssets / targetAmount`. `0…∞`, `1.0` == 100%.
    let progress: Double

    /// No snapshot yet (README §2.6): draw the empty track, no fill, and read `--%` out loud.
    var isUnavailable: Bool = false

    var height: CGFloat = 14

    private var clampedFraction: Double {
        guard progress.isFinite, progress > 0 else { return 0 }
        return min(progress, 1)
    }

    private var isGoalReached: Bool {
        progress.isFinite && progress >= 1
    }

    private var fillColor: Color {
        // Semantic, adaptive colours only — never a literal black or white, so dark mode is free.
        isGoalReached ? .green : .accentColor
    }

    private var trackColor: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemFill)
        #else
        Color.secondary.opacity(0.2)
        #endif
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(trackColor)

                if !isUnavailable, clampedFraction > 0 {
                    Capsule(style: .continuous)
                        .fill(fillColor)
                        // A sliver of progress still has to look like a capsule, not a hairline.
                        .frame(width: max(proxy.size.width * clampedFraction, height))
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: clampedFraction)
        .animation(.easeOut(duration: 0.35), value: isGoalReached)
        .accessibilityElement()
        .accessibilityLabel(Strings.progressAccessibilityLabel)
        .accessibilityValue(isUnavailable ? Strings.percentPlaceholder : FireFormatter.percent(progress))
    }
}

#if DEBUG
#Preview("진행률 바") {
    // Synthetic ratios, not fetched data — previews are the one place that is allowed (CONTRACT).
    VStack(spacing: 24) {
        ProgressBarView(progress: 0.612)
        ProgressBarView(progress: 1.037)
        ProgressBarView(progress: 0, isUnavailable: true)
    }
    .padding()
}
#endif
