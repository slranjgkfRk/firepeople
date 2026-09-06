import Foundation

// MARK: - Protocols

/// Persistence for the user's two inputs plus their preferences.
///
/// `load()` never throws and never traps: a missing *or* unreadable payload reads as `nil`, which
/// the app treats as "not onboarded yet" rather than as a crash.
public protocol SettingsStoring: Sendable {
    func load() -> Settings?
    func save(_ settings: Settings) throws
    func clear() throws
}

/// Persistence for the last successfully fetched (or last downgraded) snapshot.
///
/// Same contract as ``SettingsStoring``: reads degrade to `nil`, writes throw only on an encoding
/// failure. README §2.6 requires the previous snapshot to survive every failure mode, so a store
/// that threw on read would defeat the whole point.
public protocol SnapshotStoring: Sendable {
    func load() -> Snapshot?
    func save(_ snapshot: Snapshot) throws
    func clear() throws
}

// MARK: - Coding

/// JSON coding shared by every persistent store in this module.
///
/// ISO-8601 dates, not `Double` time intervals: the payload stays human-readable in the container
/// and survives an app update unchanged. Note the format's resolution is one second — a `Date`
/// carrying a fractional part reads back truncated to its whole second.
///
/// Encoders and decoders are created per call on purpose: `JSONEncoder` is a non-`Sendable` class,
/// so a shared `static let` would be a data race under Swift 6 strict concurrency.
enum StorageCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode(_ value: some Encodable) throws -> Data {
        try makeEncoder().encode(value)
    }

    /// Returns `nil` for corrupt, truncated or older-shape payloads instead of throwing.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? makeDecoder().decode(type, from: data)
    }
}

// MARK: - UserDefaults-backed stores

/// `Settings` as JSON in the App Group `UserDefaults` under `"settings.v1"`.
///
/// `@unchecked Sendable`: `UserDefaults` is documented as thread-safe but is not annotated
/// `Sendable` in the SDK, and this type adds no mutable state of its own.
public struct UserDefaultsSettingsStore: SettingsStoring, @unchecked Sendable {
    /// Versioned so a future shape change can be migrated from the old key rather than guessed at.
    public static let storageKey = "settings.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> Settings? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return StorageCoding.decode(Settings.self, from: data)
    }

    public func save(_ settings: Settings) throws {
        let data = try StorageCoding.encode(settings)
        defaults.set(data, forKey: Self.storageKey)
    }

    public func clear() throws {
        defaults.removeObject(forKey: Self.storageKey)
    }
}

/// `Snapshot` as JSON in the App Group `UserDefaults` under `"snapshot.v1"`.
///
/// This is the one object the widget reads on every timeline request, so it stays small: totals and
/// a per-account map, never the holdings item list.
public struct UserDefaultsSnapshotStore: SnapshotStoring, @unchecked Sendable {
    public static let storageKey = "snapshot.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> Snapshot? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return StorageCoding.decode(Snapshot.self, from: data)
    }

    public func save(_ snapshot: Snapshot) throws {
        let data = try StorageCoding.encode(snapshot)
        defaults.set(data, forKey: Self.storageKey)
    }

    public func clear() throws {
        defaults.removeObject(forKey: Self.storageKey)
    }
}
