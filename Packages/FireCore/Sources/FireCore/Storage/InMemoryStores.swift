import Foundation

/// `Settings` held in memory.
///
/// Exists because `UserDefaults(suiteName: AppGroup.identifier)` is unavailable to an unentitled
/// process — `swift test` on macOS — and because SwiftUI previews must not touch the real
/// container. It stores whatever it is handed; it never invents a value.
public final class InMemorySettingsStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Settings?

    public init(_ initial: Settings? = nil) {
        self.stored = initial
    }

    public func load() -> Settings? {
        lock.withLock { stored }
    }

    public func save(_ settings: Settings) throws {
        lock.withLock { stored = settings }
    }

    public func clear() throws {
        lock.withLock { stored = nil }
    }
}

/// `Snapshot` held in memory. Same role as ``InMemorySettingsStore``.
///
/// Seed it only with a snapshot that came from a real recorded response (tests) or one that is
/// obviously synthetic (previews) — never with invented numbers presented as fetched.
public final class InMemorySnapshotStore: SnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Snapshot?

    public init(_ initial: Snapshot? = nil) {
        self.stored = initial
    }

    public func load() -> Snapshot? {
        lock.withLock { stored }
    }

    public func save(_ snapshot: Snapshot) throws {
        lock.withLock { stored = snapshot }
    }

    public func clear() throws {
        lock.withLock { stored = nil }
    }
}

/// Access token held in memory, for tests and previews.
///
/// The shipping app must use `KeychainStore` instead: only one access token may exist per client,
/// so the app and the widget have to share one cache across processes (`docs/api-notes.md` § Auth).
/// A per-process cache would make the two revoke each other's token forever.
public final class InMemoryTokenCache: TokenCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AccessToken?

    public init() {}

    public func loadToken() throws -> AccessToken? {
        lock.withLock { stored }
    }

    public func saveToken(_ token: AccessToken) throws {
        lock.withLock { stored = token }
    }

    public func clearToken() throws {
        lock.withLock { stored = nil }
    }
}
