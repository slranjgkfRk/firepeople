//
//  WidgetRefresher.swift
//  firepeople
//
//  The only place the app target imports WidgetKit.
//
//  `FireCore` must keep building and testing on macOS with plain `swift test`, so it cannot import
//  WidgetKit at all — which is why `RefreshService` persists a snapshot but never reloads a
//  timeline. Poking the widget is the caller's job, and this is that caller (CONTRACT § RefreshService).
//

import Foundation

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Tells WidgetKit that the shared snapshot or settings changed.
///
/// Call it after **every** mutation the widget can see: a persisted `Snapshot`, a changed target
/// amount or date, an account re-selection, the `위젯에 금액 숨기기` toggle, and a full reset.
/// It is cheap and idempotent — WidgetKit coalesces reloads — but it is not free with respect to
/// the OS reload budget (README §4.2), so it is never called on a refresh that produced no change.
enum WidgetRefresher {

    /// Reloads every timeline this app owns.
    ///
    /// Deliberately `reloadAllTimelines()` rather than `reloadTimelines(ofKind:)`: a typo in a kind
    /// string fails silently and leaves the home screen showing yesterday's number forever.
    /// Safe to call from any isolation and on any platform — a build without WidgetKit gets a no-op.
    static func reload() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
