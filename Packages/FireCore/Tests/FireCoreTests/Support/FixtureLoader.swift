//
//  FixtureLoader.swift
//  FireCoreTests
//
//  Access to `Fixtures/` — the **real** recorded Toss Open API responses (docs/api-notes.md,
//  "Live verification, 2026-09-06 17:51 KST"). Nothing in the test suite may hand-write a payload
//  that pretends to be an API response; every byte the tests feed to the code under test comes
//  from one of these files.
//

import Foundation

// MARK: - Fixture access

enum FixtureLoader {

    /// Every recorded response, by base name. Kept as a literal list so that adding a fixture
    /// without adding a decoding test fails `ModelDecodingTests.testEveryFixtureIsCovered`.
    enum Name {
        static let accounts = "accounts"
        static let accountsEmpty = "accounts_empty"
        static let buyingPowerKRW = "buying_power_krw"
        static let error401 = "error_401"
        static let error429 = "error_429"
        static let exchangeRate = "exchange_rate"
        static let holdings = "holdings"
        static let holdingsEmpty = "holdings_empty"
        static let oauthErrorInvalidClient = "oauth_error_invalid_client"
        static let token = "token"

        static let all: [String] = [
            accounts, accountsEmpty, buyingPowerKRW, error401, error429,
            exchangeRate, holdings, holdingsEmpty, oauthErrorInvalidClient, token
        ]
    }

    struct MissingFixture: Error, CustomStringConvertible {
        let name: String
        var description: String {
            "Fixture \"\(name).json\" is not in Bundle.module. "
            + "Package.swift must keep `.copy(\"Fixtures\")` on the test target."
        }
    }

    /// Location of one recorded response. Tries the copied `Fixtures/` directory first, then the
    /// bundle root, so the loader survives a switch between `.copy` and `.process`.
    static func url(_ name: String) throws -> URL {
        let base = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        if let url = Bundle.module.url(forResource: base, withExtension: "json", subdirectory: "Fixtures") {
            return url
        }
        if let url = Bundle.module.url(forResource: base, withExtension: "json") {
            return url
        }
        throw MissingFixture(name: base)
    }

    /// The recorded bytes, exactly as they came off the wire. This is what `StubURLProtocol` replays.
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    /// The recorded bytes with one literal swapped out. Used only to build *corrupt* input for
    /// negative tests — never to fabricate a plausible response.
    static func corruptedData(_ name: String, replacing needle: String, with replacement: String) throws -> Data {
        let raw = try text(name)
        guard raw.contains(needle) else {
            throw MissingFixture(name: "\(name) (does not contain \"\(needle)\")")
        }
        return Data(raw.replacingOccurrences(of: needle, with: replacement).utf8)
    }

    /// Base names of every `.json` actually present in the bundle, sorted.
    static func presentNames() -> [String] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil)
            ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    // MARK: Decoding

    /// A decoder configured the way `FireCore` reads wire payloads: money arrives as decimal
    /// strings (handled inside the models), and any bare `Date` is ISO-8601 with the fractional
    /// seconds the API actually sends (`"2026-09-06T17:56:56.000+09:00"`).
    ///
    /// Built per call: `JSONDecoder` is a non-`Sendable` class.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = TestDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO-8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }

    /// Decodes a whole recorded file into `T`.
    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try makeDecoder().decode(type, from: data(name))
    }

    /// Decodes the `result` of the common success envelope (`{"result": …}`) into `T`.
    static func result<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try makeDecoder().decode(FixtureEnvelope<T>.self, from: data(name)).result
    }
}

/// The common success envelope every non-token endpoint uses (docs/api-notes.md § Calling other
/// endpoints).
struct FixtureEnvelope<T: Decodable>: Decodable {
    let result: T
}

// MARK: - Deterministic dates

/// Builds `Date`s from explicit ISO-8601 strings with an explicit offset, so no test ever depends
/// on the machine's timezone, locale or clock. `TestDate.kst("2026-09-06T14:30:00+09:00")` reads as
/// the wall-clock time a Seoul user would see.
enum TestDate {

    /// Parses `"2029-12-31T00:00:00+09:00"` and the fractional-seconds form the API sends.
    static func parse(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    /// Same as ``parse(_:)`` but for literals written in a test, where a typo is a programmer error.
    static func iso(_ string: String, file: StaticString = #file, line: UInt = #line) -> Date {
        guard let date = parse(string) else {
            preconditionFailure("Malformed ISO-8601 literal in a test: \(string)", file: file, line: line)
        }
        return date
    }

    /// Alias that documents intent at the call site: a KST wall-clock instant.
    static func kst(_ string: String, file: StaticString = #file, line: UInt = #line) -> Date {
        iso(string, file: file, line: line)
    }
}
