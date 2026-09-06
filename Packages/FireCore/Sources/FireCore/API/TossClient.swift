import Foundation

// MARK: - Credentials and token

/// The two values issued in WTS → 설정 → Open API.
///
/// They live in the Keychain and are read out only to build one form body
/// (`TossEndpoint.tokenRequest`). Nothing here validates their shape: api-notes says the `tsck_` /
/// `tssk_` prefixes are not contractual, so "non-empty" is the only rule the app may enforce.
public struct TokenCredentials: Sendable, Hashable {
    public let clientId: String
    public let clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

/// A bearer token with the moment it stops being usable.
///
/// **Only one of these is valid per client at a time** — re-issuing revokes the previous one
/// (api-notes § Auth). The app and the widget are separate processes on one client, so this value
/// is shared through the Keychain rather than held per process.
public struct AccessToken: Codable, Sendable, Hashable {
    public let value: String
    public let expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }

    /// `expiresAt > now + leeway`. The 60s default is README §3.2's "reissue 60 seconds before
    /// expiry", so a token can never expire mid-flight.
    public func isValid(at now: Date, leeway: TimeInterval = 60) -> Bool {
        expiresAt > now.addingTimeInterval(leeway)
    }
}

/// The shared token cache. `KeychainStore` is the real one; the app and widget must be handed the
/// same access group so they see one token (non-negotiable #4).
public protocol TokenCaching: Sendable {
    func loadToken() throws -> AccessToken?
    func saveToken(_ token: AccessToken) throws
    func clearToken() throws
}

public protocol CredentialProviding: Sendable {
    /// `nil` when no keys have been entered yet (fresh install, or after 초기화).
    func credentials() throws -> TokenCredentials?
}

/// The whole network surface of this app. Read-only by construction: there is no order method here
/// and no endpoint case that could serve one (README §3.4).
public protocol TossReadOnlyAPI: Sendable {
    func accounts() async throws -> [TossAccount]
    func holdings(accountSeq: Int) async throws -> HoldingsOverview
    func exchangeRate(base: Currency, quote: Currency) async throws -> ExchangeRate
    func cashBuyingPower(accountSeq: Int, currency: Currency) async throws -> Decimal
}

// MARK: - TossClient

/// The Toss Securities Open API client.
///
/// An `actor` for one reason above all: **token issuance must be serialised**. The server keeps a
/// single valid access token per client and issuing a new one revokes the old one, so two
/// concurrent refreshes would hand each other dead tokens forever. Every caller that needs a token
/// while an issue is in flight awaits *the same* `Task`; only one `POST /oauth2/token` is ever in
/// the air inside a process, and the result is written straight to the shared cache so the other
/// process picks it up instead of issuing its own.
///
/// Retry rules (README §3.5, api-notes § Rate limits):
/// - `401` on a read endpoint → drop the cached token, re-issue **once**, retry **once**.
/// - `403` → `ipNotAllowed` immediately. Retrying from a disallowed IP never helps.
/// - `429` → wait `Retry-After` (header, else `error.data.retryAfterSeconds`, else 1s), capped at
///   30s, growing ×1 → ×2 → ×4 with jitter, at most ``maxAttempts`` attempts.
/// - `5xx` and `URLError` → no retry at all. The refresh is abandoned and the previous snapshot
///   stays on screen, which is always better than a wrong number.
public actor TossClient: TossReadOnlyAPI {

    public static let baseURL = URL(string: "https://openapi.tossinvest.com")!

    /// Total attempts for one request, including the first. Reached only on repeated 429s.
    static let maxAttempts = 3

    private let credentialProvider: any CredentialProviding
    private let tokenCache: any TokenCaching
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let backoffSleep: @Sendable (TimeInterval) async throws -> Void
    private let decoder: JSONDecoder

    /// Mirror of the shared cache, so a burst of requests does not hit the Keychain for every one.
    private var cachedToken: AccessToken?
    /// The single in-flight `POST /oauth2/token`, if any. This is the serialisation point.
    private var issuance: Task<AccessToken, Error>?

    public init(
        credentials: any CredentialProviding,
        tokenCache: any TokenCaching,
        session: URLSession = .fireDefault,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.credentialProvider = credentials
        self.tokenCache = tokenCache
        self.session = session
        self.now = now
        self.backoffSleep = TossClient.defaultSleep
        self.decoder = TossClient.makeDecoder()
    }

    /// Same client with an injectable sleep, so a 429 test does not have to spend real seconds
    /// waiting out a backoff. `backoffSleep` has no default, which keeps this unambiguous against
    /// the public initialiser above.
    init(
        credentials: any CredentialProviding,
        tokenCache: any TokenCaching,
        session: URLSession,
        now: @Sendable @escaping () -> Date,
        backoffSleep: @Sendable @escaping (TimeInterval) async throws -> Void
    ) {
        self.credentialProvider = credentials
        self.tokenCache = tokenCache
        self.session = session
        self.now = now
        self.backoffSleep = backoffSleep
        self.decoder = TossClient.makeDecoder()
    }

    // MARK: - TossReadOnlyAPI

    /// `GET /api/v1/accounts`. Rate-limit group `ACCOUNT` is **1 rps** — call this one at a time.
    public func accounts() async throws -> [TossAccount] {
        try await result(of: .accounts, as: [TossAccount].self)
    }

    /// `GET /api/v1/holdings` for one account. `X-Tossinvest-Account` comes from the endpoint case.
    public func holdings(accountSeq: Int) async throws -> HoldingsOverview {
        try await result(of: .holdings(accountSeq: accountSeq), as: HoldingsOverview.self)
    }

    /// `GET /api/v1/exchange-rate?baseCurrency=…&quoteCurrency=…`. No account header.
    /// The app needs this because holdings are split by trading currency and are never converted
    /// server-side (api-notes — this is where README §3.3 was wrong).
    public func exchangeRate(base: Currency, quote: Currency) async throws -> ExchangeRate {
        try await result(of: .exchangeRate(base: base, quote: quote), as: ExchangeRate.self)
    }

    /// `GET /api/v1/buying-power?currency=…` → `result.cashBuyingPower`.
    /// Only called when `Settings.includeCash` is on. Reading buying power cannot spend it.
    public func cashBuyingPower(accountSeq: Int, currency: Currency) async throws -> Decimal {
        let payload = try await result(
            of: .buyingPower(accountSeq: accountSeq, currency: currency),
            as: BuyingPowerResult.self
        )
        return payload.cashBuyingPower
    }

    // MARK: - Onboarding and token lifetime

    /// Onboarding's 연결 테스트: prove these keys work, then show what they can see.
    ///
    /// The cached token is dropped first *on purpose*. A token cached from the previous keys stays
    /// valid for its full 24h, so reusing it would let a wrong `client_secret` pass the test. The
    /// re-issue that follows revokes the old token, which is exactly right when the keys have just
    /// been replaced — and harmless when they have not, because the new token lands in the shared
    /// cache before anything else reads it.
    public func verifyConnection() async throws -> [TossAccount] {
        if let issuance {
            // Never invalidate underneath an in-flight issue; let it land first.
            _ = try? await issuance.value
        }
        await invalidateToken()
        _ = try await accessToken()
        return try await accounts()
    }

    /// Forgets the token here and in the shared cache. Used on 401 and by 설정 > API 키 삭제.
    public func invalidateToken() async {
        cachedToken = nil
        try? tokenCache.clearToken()
    }

    // MARK: - Request pipeline

    private func result<T: Decodable & Sendable>(of endpoint: TossEndpoint, as type: T.Type) async throws -> T {
        let data = try await send(endpoint)
        return try decodeResult(data, as: type)
    }

    /// Runs one read-only endpoint to completion, applying the retry rules. Returns the raw body of
    /// the 2xx response.
    private func send(_ endpoint: TossEndpoint) async throws -> Data {
        var attempt = 0
        var didReissueToken = false

        while true {
            try Task.checkCancellation()
            attempt += 1

            let token = try await accessToken()
            let request = endpoint.urlRequest(baseURL: Self.baseURL, accessToken: token.value)
            let (data, response) = try await perform(request)

            if (200..<300).contains(response.statusCode) {
                return data
            }

            let error = TossAPIError.make(
                status: response.statusCode,
                body: TossErrorBody.parse(data),
                retryAfterHeader: response.value(forHTTPHeaderField: "Retry-After"),
                isTokenEndpoint: false
            )

            switch error {
            case .unauthorized:
                // The token was revoked (or the widget's re-issue revoked ours). One re-issue,
                // one retry — a second 401 means the key itself is the problem.
                guard !didReissueToken else { throw error }
                didReissueToken = true
                attempt -= 1  // a revoked token is not a rate-limit attempt
                await invalidateToken()
                continue

            case .rateLimited(let retryAfter):
                guard attempt < Self.maxAttempts else { throw error }
                try await backOff(base: retryAfter, attempt: attempt)
                continue

            default:
                throw error
            }
        }
    }

    /// Waits ×1 → ×2 → ×4 of the server's own hint, never longer than 30s, with a little jitter so
    /// the app and the widget do not come back in lockstep.
    private func backOff(base: TimeInterval, attempt: Int) async throws {
        let growth = pow(2, Double(max(attempt - 1, 0)))
        let delay = min(base * growth, TossAPIError.maxRetryAfter)
        let jittered = min(delay * Double.random(in: 1.0..<1.25), TossAPIError.maxRetryAfter)
        try await backoffSleep(jittered)
        try Task.checkCancellation()
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TossAPIError.transport("non-HTTP response")
            }
            return (data, http)
        } catch let error as TossAPIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw TossAPIError.transport(
                TossAPIError.redactingSecrets("URLError \(error.errorCode): \(error.localizedDescription)")
            )
        } catch {
            throw TossAPIError.transport(TossAPIError.redactingSecrets(error.localizedDescription))
        }
    }

    // MARK: - Token acquisition

    /// A usable token: the in-memory one, else the shared cache (another process may have issued
    /// one), else a freshly issued one.
    private func accessToken() async throws -> AccessToken {
        let moment = now()

        if let cachedToken, cachedToken.isValid(at: moment) {
            return cachedToken
        }
        if let stored = try? tokenCache.loadToken(), stored.isValid(at: moment) {
            cachedToken = stored
            return stored
        }
        return try await issueToken()
    }

    /// The serialisation point. A second caller arriving while a `POST /oauth2/token` is in flight
    /// awaits **that** task instead of starting another one, so the client never revokes its own
    /// token mid-refresh (non-negotiable #4).
    private func issueToken() async throws -> AccessToken {
        if let issuance {
            return try await issuance.value
        }

        let task = Task<AccessToken, Error> { [weak self] in
            guard let self else { throw TossAPIError.transport("client released") }
            return try await self.performTokenRequest()
        }
        issuance = task

        do {
            let token = try await task.value
            issuance = nil
            return token
        } catch {
            issuance = nil
            throw error
        }
    }

    private func performTokenRequest() async throws -> AccessToken {
        // Last look at the shared cache: the widget may have issued one microseconds ago, and using
        // its token is strictly better than replacing it.
        if let stored = try? tokenCache.loadToken(), stored.isValid(at: now()) {
            cachedToken = stored
            return stored
        }

        guard let credentials = loadCredentials(), !credentials.clientId.isEmpty,
              !credentials.clientSecret.isEmpty
        else {
            throw TossAPIError.invalidCredentials(field: nil)
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1

            let request = TossEndpoint.tokenRequest(credentials: credentials, baseURL: Self.baseURL)
            let (data, response) = try await perform(request)

            if (200..<300).contains(response.statusCode) {
                let token = try decodeToken(data)
                cachedToken = token
                // A failed write is not a failed refresh: the token is good, this process can use
                // it, the other one will issue its own. Never surfaced, never logged — it would
                // have to carry the token to say anything useful.
                try? tokenCache.saveToken(token)
                return token
            }

            let error = TossAPIError.make(
                status: response.statusCode,
                body: TossErrorBody.parse(data),
                retryAfterHeader: response.value(forHTTPHeaderField: "Retry-After"),
                isTokenEndpoint: true
            )

            if case .rateLimited(let retryAfter) = error, attempt < Self.maxAttempts {
                try await backOff(base: retryAfter, attempt: attempt)
                continue
            }
            throw error
        }
    }

    /// A Keychain that will not open is, from the user's side, the same problem as a key that is
    /// wrong: re-enter the keys. Mapping it to `invalidCredentials` also keeps `isAuthFailure`
    /// true, so README §2.6's `API 키를 확인해주세요` banner appears instead of a network one.
    private func loadCredentials() -> TokenCredentials? {
        try? credentialProvider.credentials()
    }

    // MARK: - Decoding

    private func decodeResult<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try decoder.decode(ResultEnvelope<T>.self, from: data).result
        } catch let error as DecodingError {
            throw TossAPIError.decoding(Self.describe(error))
        } catch {
            throw TossAPIError.decoding(TossAPIError.redactingSecrets(error.localizedDescription))
        }
    }

    private func decodeToken(_ data: Data) throws -> AccessToken {
        let payload: TokenResponse
        do {
            payload = try decoder.decode(TokenResponse.self, from: data)
        } catch let error as DecodingError {
            throw TossAPIError.decoding(Self.describe(error))
        } catch {
            throw TossAPIError.decoding(TossAPIError.redactingSecrets(error.localizedDescription))
        }

        guard !payload.accessToken.isEmpty else {
            throw TossAPIError.decoding("empty access_token")
        }
        // Measured lifetime is 86400s; the value is always taken from the response, never assumed.
        return AccessToken(
            value: payload.accessToken,
            expiresAt: now().addingTimeInterval(payload.expiresIn)
        )
    }

    /// Structural only — a coding path and a kind, never the payload, so an amount or a token can
    /// not ride along into a log.
    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.isEmpty
                ? "<root>"
                : context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "keyNotFound(\(key.stringValue)) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "valueNotFound(\(type)) at \(path(context))"
        case .typeMismatch(let type, let context):
            return "typeMismatch(\(type)) at \(path(context))"
        case .dataCorrupted(let context):
            return "dataCorrupted at \(path(context))"
        @unknown default:
            return "decodingFailed"
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // The API stamps dates as `2026-09-06T17:56:56.000+09:00` — internet date time *with*
        // fractional seconds, which `.iso8601` alone does not accept.
        decoder.dateDecodingStrategy = .custom { dateDecoder in
            let container = try dateDecoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = TossClient.parseAPIDate(raw) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Unrecognised date format."
                    )
                )
            }
            return date
        }
        return decoder
    }

    /// Formatters are built per call: this runs at most twice per refresh and it keeps the client
    /// free of shared mutable reference state.
    static func parseAPIDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static let defaultSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        guard seconds > 0 else { return }
        let capped = min(seconds, TossAPIError.maxRetryAfter)
        try await Task.sleep(nanoseconds: UInt64((capped * 1_000_000_000).rounded()))
    }
}

// MARK: - Wire shapes

/// `{"result": …}` — the common success envelope on every endpoint but the token one.
struct ResultEnvelope<T: Decodable>: Decodable {
    let result: T
}

/// `{"access_token": "…", "token_type": "Bearer", "expires_in": 86399}` — the OAuth2 success shape.
/// Never `Codable`-synthesised into anything that gets logged; the value goes straight into the
/// Keychain.
struct TokenResponse: Decodable {
    let accessToken: String
    let tokenType: String?
    let expiresIn: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)

        if let seconds = try? container.decode(TimeInterval.self, forKey: .expiresIn) {
            expiresIn = seconds
        } else if let text = try? container.decode(String.self, forKey: .expiresIn),
                  let seconds = TimeInterval(text) {
            expiresIn = seconds
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.expiresIn],
                    debugDescription: "expires_in is not a number of seconds."
                )
            )
        }
    }
}

/// `{"result": {"currency": "KRW", "cashBuyingPower": "50"}}`.
/// The amount is a decimal *string*, read straight into `Decimal` — never through `Double`.
struct BuyingPowerResult: Decodable, Sendable {
    let currency: Currency?
    let cashBuyingPower: Decimal

    private enum CodingKeys: String, CodingKey {
        case currency
        case cashBuyingPower
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currency = try? container.decodeIfPresent(Currency.self, forKey: .currency)
        cashBuyingPower = try container.decodeDecimal(forKey: .cashBuyingPower)
    }
}
