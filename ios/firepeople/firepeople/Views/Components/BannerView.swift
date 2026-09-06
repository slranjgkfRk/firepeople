//
//  BannerView.swift
//  firepeople
//
//  The single top-of-screen banner slot of README §2.6:
//
//      갱신 실패 (네트워크)  → `갱신 실패 · 마지막 갱신 3시간 전`
//      401 / 키 폐기        → `API 키를 확인해주세요`   (탭하면 설정)
//      403 / IP 미등록      → `토스증권에 이 기기의 IP를 등록해주세요` (탭하면 설정)
//      목표일 지남          → 목표일 수정 유도, 1회 (탭하면 설정)
//
//  429 has no banner on purpose — the client backs off silently (README §3.5).
//

import SwiftUI

/// A tappable, dismissible status banner. Renders nothing at all for ``AppBanner/none``.
struct BannerView: View {

    let banner: AppBanner
    /// Reference point for the `마지막 갱신 3시간 전` text; injected so previews are deterministic.
    var now: Date = Date()
    /// What tapping the banner body does — open 설정 for the key/IP/goal cases, retry for network.
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        if let style = Style(banner: banner, now: now) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: style.systemImage)
                    .foregroundStyle(style.tint)
                    .accessibilityHidden(true)

                Text(style.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Image(systemName: style.actionImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.bannerDismiss)
            }
            .padding(.vertical, 10)
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(style.tint.opacity(0.14))
            )
            // The row itself is the tap target; only the ✕ is a nested button, so no button-in-button.
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(style.message)
            .accessibilityHint(style.accessibilityHint)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Everything that varies per banner case, resolved once.
    private struct Style {
        let message: String
        let systemImage: String
        /// Trailing affordance glyph: a gear for "go fix it in 설정", a refresh arrow for "try again".
        let actionImage: String
        let accessibilityHint: String
        let tint: Color

        init?(banner: AppBanner, now: Date) {
            switch banner {
            case .none:
                return nil

            case .network(let lastUpdated):
                message = Strings.bannerRefreshFailedLine(lastUpdated: lastUpdated, now: now)
                systemImage = "wifi.exclamationmark"
                actionImage = "arrow.clockwise"
                accessibilityHint = Strings.retry
                tint = .orange

            case .authFailed:
                message = Strings.bannerAuthFailed
                systemImage = "key.slash"
                actionImage = "gearshape"
                accessibilityHint = Strings.settingsAccessibilityLabel
                tint = .red

            case .ipBlocked:
                message = Strings.bannerIPBlocked
                systemImage = "exclamationmark.shield"
                actionImage = "gearshape"
                accessibilityHint = Strings.settingsAccessibilityLabel
                tint = .red

            case .targetPassed:
                message = Strings.bannerTargetPassed
                systemImage = "calendar.badge.exclamationmark"
                actionImage = "gearshape"
                accessibilityHint = Strings.settingsAccessibilityLabel
                tint = .accentColor
            }
        }
    }
}

#if DEBUG
#Preview("배너") {
    // Synthetic dates only — previews never render fetched data (CONTRACT § On "no mock data").
    let now = Date()
    return VStack(spacing: 12) {
        BannerView(banner: .network(now.addingTimeInterval(-3 * 3600)), now: now, onTap: {}, onDismiss: {})
        BannerView(banner: .authFailed, onTap: {}, onDismiss: {})
        BannerView(banner: .ipBlocked, onTap: {}, onDismiss: {})
        BannerView(banner: .targetPassed, onTap: {}, onDismiss: {})
    }
    .padding()
}
#endif
