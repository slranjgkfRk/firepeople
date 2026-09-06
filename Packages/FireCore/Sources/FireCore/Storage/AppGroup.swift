import Foundation

/// Identifiers shared by the app process, the widget extension and `FireCore`.
///
/// The app group backs the JSON `Settings` / `Snapshot` store; the Keychain access group backs the
/// credential and access-token store (README §7). Both processes read and write the same two
/// containers — that is what lets the widget render, and refresh, while the app is not running,
/// and it is also why exactly one access token may exist at a time (see `docs/api-notes.md` § Auth).
public enum AppGroup: Sendable {
    /// App Group container id. Must match the `com.apple.security.application-groups` entitlement
    /// on both the app and the widget target.
    public static let identifier = "group.com.jay-lab.firepeople.shared"

    /// Keychain sharing group. Must match `keychain-access-groups` on both targets, where it is
    /// written with the team-id prefix (`$(AppIdentifierPrefix)com.jay-lab.firepeople.shared`);
    /// the prefix is supplied by the system at runtime, so it is absent here.
    public static let keychainAccessGroup = "com.jay-lab.firepeople.shared"

    /// `WidgetKit` kind string for the single widget this app ships.
    public static let widgetKind = "FireWidget"

    /// `UserDefaults` for the shared container.
    ///
    /// `nil` when the process has no App Groups entitlement for ``identifier`` — which is exactly
    /// the situation under `swift test` on macOS. Callers must tolerate `nil` and fall back
    /// (`InMemorySettingsStore` / `InMemorySnapshotStore` in tests and SwiftUI previews) instead of
    /// force-unwrapping.
    public static var defaults: UserDefaults? { UserDefaults(suiteName: identifier) }
}
