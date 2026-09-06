//
//  StubURLProtocol.swift
//  FireCoreTests
//
//  The network is faked at the **transport** boundary and nowhere else: `StubURLProtocol` decides
//  the status line, the headers and the bytes, and the bytes are always a file out of `Fixtures/`
//  (the real recorded responses). Nothing above `URLSession` is stubbed — `TossClient` builds every
//  request, parses every response and runs its own retry logic exactly as it does in the app.
//
//  This file also holds the two other deterministic doubles the tests inject: `TestClock` (so no
//  production code ever reads `Date()`) and `StubCredentials` (a local secret store, not API data).
//

import Foundation
import FireCore

// MARK: - What the stub saw

/// One request as it reached the transport, recorded for assertions.
struct StubRequest: Sendable {
    let method: String
    /// `URL.path`, e.g. `"/api/v1/holdings"`. The registry is keyed by this.
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let body: Data?
    /// 1-based index of this request among all requests to the same path — the retry-attempt number.
    let attempt: Int

    /// HTTP header names are case-insensitive, and `URLSession` may re-case them on the way through.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var bodyText: String {
        body.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

// MARK: - What the stub answers

enum StubResult: Sendable {
    /// A complete HTTP response. `delay` is the only real sleeping any test does, in milliseconds,
    /// and only to widen a race window.
    case http(status: Int, headers: [String: String], body: Data, delay: TimeInterval)
    /// A transport failure — `URLError` with this raw code, i.e. no HTTP response at all.
    case failure(urlErrorCode: Int)

    static func ok(_ body: Data, headers: [String: String] = [:], delay: TimeInterval = 0) -> StubResult {
        .http(status: 200, headers: headers, body: body, delay: delay)
    }

    static func status(
        _ status: Int,
        _ body: Data = Data(),
        headers: [String: String] = [:],
        delay: TimeInterval = 0
    ) -> StubResult {
        .http(status: status, headers: headers, body: body, delay: delay)
    }

    static func networkError(_ code: URLError.Code) -> StubResult {
        .failure(urlErrorCode: code.rawValue)
    }
}

/// The four read-only paths this app is allowed to call, plus the token endpoint.
/// There is deliberately no order path here, because there is no order path anywhere.
enum StubPath {
    static let token = "/oauth2/token"
    static let accounts = "/api/v1/accounts"
    static let holdings = "/api/v1/holdings"
    static let exchangeRate = "/api/v1/exchange-rate"
    static let buyingPower = "/api/v1/buying-power"
}

// MARK: - Registry

/// Handlers and recorded requests, shared across the URL loading threads.
private final class StubRegistry: @unchecked Sendable {

    static let shared = StubRegistry()

    private let lock = NSLock()
    private var handlers: [String: @Sendable (StubRequest) -> StubResult] = [:]
    private var recorded: [String: [StubRequest]] = [:]
    private var unhandled: [String] = []

    func reset() {
        lock.lock()
        handlers = [:]
        recorded = [:]
        unhandled = []
        lock.unlock()
    }

    func setHandler(_ path: String, _ handler: @escaping @Sendable (StubRequest) -> StubResult) {
        lock.lock()
        handlers[path] = handler
        lock.unlock()
    }

    /// Records the request, then answers it. The handler runs outside the lock so it may itself ask
    /// the registry for counts.
    func dispatch(
        method: String,
        path: String,
        queryItems: [String: String],
        headers: [String: String],
        body: Data?
    ) -> StubResult {
        lock.lock()
        let attempt = (recorded[path]?.count ?? 0) + 1
        let request = StubRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            headers: headers,
            body: body,
            attempt: attempt
        )
        recorded[path, default: []].append(request)
        let handler = handlers[path]
        if handler == nil { unhandled.append(path) }
        lock.unlock()

        guard let handler else {
            // An un-stubbed path is a test bug, not a scenario: fail loudly rather than silently
            // returning something the client could mistake for data.
            return .networkError(.unsupportedURL)
        }
        return handler(request)
    }

    func requests(for path: String) -> [StubRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded[path] ?? []
    }

    func allRequests() -> [StubRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.values.flatMap { $0 }
    }

    func unhandledPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return unhandled
    }
}

// MARK: - The protocol

final class StubURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let url = request.url
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var queryItems: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            queryItems[item.name] = item.value ?? ""
        }

        let result = StubRegistry.shared.dispatch(
            method: request.httpMethod ?? "GET",
            path: components?.path ?? url?.path ?? "",
            queryItems: queryItems,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request)
        )

        switch result {
        case .http(let status, let headers, let body, let delay):
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            guard let url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                  )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)

        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
        }
    }

    override func stopLoading() {}

    /// `URLRequest.httpBody` is `nil` once the request reaches a `URLProtocol` — the body has been
    /// turned into a stream. The token endpoint's form body is only readable this way.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Test-facing API

extension StubURLProtocol {

    /// Clears every handler and every recorded request. Call in `setUp` *and* `tearDown`.
    static func reset() {
        StubRegistry.shared.reset()
    }

    /// Answers `path` with whatever `handler` decides, per request.
    static func handle(_ path: String, _ handler: @escaping @Sendable (StubRequest) -> StubResult) {
        StubRegistry.shared.setHandler(path, handler)
    }

    /// Answers `path` with the same response every time.
    static func stub(
        _ path: String,
        status: Int = 200,
        headers: [String: String] = [:],
        body: Data,
        delay: TimeInterval = 0
    ) {
        let result = StubResult.http(status: status, headers: headers, body: body, delay: delay)
        handle(path) { _ in result }
    }

    /// Answers the n-th request to `path` with `results[n - 1]`; the last entry repeats forever.
    /// This is how a "429, 429, then 200" sequence is expressed.
    static func stubSequence(_ path: String, _ results: [StubResult]) {
        precondition(!results.isEmpty, "stubSequence needs at least one result")
        handle(path) { request in
            results[min(request.attempt - 1, results.count - 1)]
        }
    }

    static func requests(for path: String) -> [StubRequest] {
        StubRegistry.shared.requests(for: path)
    }

    static func requestCount(for path: String) -> Int {
        StubRegistry.shared.requests(for: path).count
    }

    static func allRequests() -> [StubRequest] {
        StubRegistry.shared.allRequests()
    }

    /// Paths that were requested without a handler — always assert this is empty.
    static func unhandledPaths() -> [String] {
        StubRegistry.shared.unhandledPaths()
    }

    /// A session that reaches nothing but this protocol. `timeout` is short so a hung test fails
    /// fast rather than stalling `swift test`.
    static func makeSession(timeout: TimeInterval = 5) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }
}

// MARK: - Deterministic clock

/// The `now` every actor under test is initialised with. Tests move time explicitly; no production
/// code path in a test ever reads the wall clock.
final class TestClock: @unchecked Sendable {

    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        self.current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }

    @discardableResult
    func advance(_ seconds: TimeInterval) -> Date {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let updated = current
        lock.unlock()
        return updated
    }

    /// Pass this as the `now:` parameter of `TossClient` / `RefreshService`.
    var closure: @Sendable () -> Date {
        { [self] in self.now }
    }
}

// MARK: - Credentials double

/// Stands in for the Keychain. These are *local secrets*, not API data — the values below are
/// obviously fake and exist so the tests can assert that they never reach a log, a URL or an error.
struct StubCredentials: CredentialProviding {

    static let clientId = "tsck_live_unit_test_client_id_00"
    static let clientSecret = "tssk_live_unit_test_secret_never_logged_00000000000"

    var stored: TokenCredentials?

    init(stored: TokenCredentials? = TokenCredentials(clientId: StubCredentials.clientId,
                                                      clientSecret: StubCredentials.clientSecret)) {
        self.stored = stored
    }

    func credentials() throws -> TokenCredentials? { stored }
}
