import Foundation

/// Every request this app is able to make. There is no case for an order, a modification, a
/// cancellation or anything under `/conditional-orders`, so no code path can reach one
/// (README §3.4, api-notes "Endpoints deliberately absent from the client").
///
/// The `X-Tossinvest-Account` header is a property of the *case*, not of the caller: it exists for
/// `.account(seq:_)` and cannot exist for `.global(_)`. That is why `holdings` and `buying-power`
/// can never be sent without it, and why it can never be attached to `/api/v1/accounts`, which
/// rejects it.
public enum TossEndpoint: Sendable, Hashable {

    /// Endpoints that require `X-Tossinvest-Account`. They carry no seq of their own — it lives on
    /// the `.account(seq:_)` case, so building one without a seq is not expressible.
    public enum AccountScoped: Sendable, Hashable {
        /// `GET /api/v1/holdings` — rate-limit group `ASSET`, 5 rps.
        case holdings
        /// `GET /api/v1/buying-power` — group `ORDER_INFO`, 6 rps. Read-only: it reports cash, it
        /// cannot spend it. Only called when `Settings.includeCash` is on.
        case buyingPower(currency: Currency)
    }

    /// Endpoints that must *not* carry `X-Tossinvest-Account`.
    public enum Global: Sendable, Hashable {
        /// `GET /api/v1/accounts` — group `ACCOUNT`, **1 rps**. Never fan these out.
        case accounts
        /// `GET /api/v1/exchange-rate` — group `MARKET_INFO`, 3 rps.
        case exchangeRate(base: Currency, quote: Currency)
    }

    /// `POST /oauth2/token` — group `AUTH`, 5 rps. The only non-`GET` request in the app.
    /// Built through ``tokenRequest(credentials:baseURL:)``, which is the sole place credentials
    /// ever enter a request.
    case token
    case global(Global)
    case account(seq: Int, AccountScoped)

    // MARK: - Spellings the client actually uses

    public static let accounts = TossEndpoint.global(.accounts)

    public static func holdings(accountSeq: Int) -> TossEndpoint {
        .account(seq: accountSeq, .holdings)
    }

    public static func exchangeRate(base: Currency, quote: Currency) -> TossEndpoint {
        .global(.exchangeRate(base: base, quote: quote))
    }

    public static func buyingPower(accountSeq: Int, currency: Currency) -> TossEndpoint {
        .account(seq: accountSeq, .buyingPower(currency: currency))
    }

    // MARK: - Shape

    public var path: String {
        switch self {
        case .token:
            return "/oauth2/token"
        case .global(.accounts):
            return "/api/v1/accounts"
        case .global(.exchangeRate):
            return "/api/v1/exchange-rate"
        case .account(_, .holdings):
            return "/api/v1/holdings"
        case .account(_, .buyingPower):
            return "/api/v1/buying-power"
        }
    }

    public var method: String {
        switch self {
        case .token: return "POST"
        case .global, .account: return "GET"
        }
    }

    public var queryItems: [URLQueryItem] {
        switch self {
        case .token, .global(.accounts), .account(_, .holdings):
            return []
        case .global(.exchangeRate(let base, let quote)):
            return [
                URLQueryItem(name: "baseCurrency", value: base.rawValue),
                URLQueryItem(name: "quoteCurrency", value: quote.rawValue),
            ]
        case .account(_, .buyingPower(let currency)):
            return [URLQueryItem(name: "currency", value: currency.rawValue)]
        }
    }

    /// Non-`nil` exactly for the endpoints that must send `X-Tossinvest-Account`.
    public var accountSeq: Int? {
        switch self {
        case .account(let seq, _): return seq
        case .token, .global: return nil
        }
    }

    /// `false` only for `.token`, which authenticates with the credentials themselves.
    public var requiresAccessToken: Bool {
        switch self {
        case .token: return false
        case .global, .account: return true
        }
    }

    public var isTokenEndpoint: Bool {
        if case .token = self { return true }
        return false
    }

    // MARK: - URLRequest

    public func url(baseURL: URL = TossClient.baseURL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return fallbackURL(baseURL: baseURL)
        }
        var prefix = components.path
        if prefix.hasSuffix("/") { prefix.removeLast() }
        components.path = prefix + path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url ?? fallbackURL(baseURL: baseURL)
    }

    /// Builds the request for this endpoint.
    ///
    /// - Parameter accessToken: attached as `Authorization: Bearer …` on the read endpoints. It is
    ///   ignored by `.token`, which never carries a bearer header — passing one there cannot
    ///   accidentally authenticate a token request with a stale token.
    public func urlRequest(baseURL: URL = TossClient.baseURL, accessToken: String? = nil) -> URLRequest {
        var request = URLRequest(url: url(baseURL: baseURL))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accountSeq {
            request.setValue(String(accountSeq), forHTTPHeaderField: "X-Tossinvest-Account")
        }

        switch self {
        case .token:
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
        case .global, .account:
            if let accessToken, !accessToken.isEmpty {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    /// `POST /oauth2/token` with `grant_type=client_credentials` and the two keys, form-encoded.
    ///
    /// The credentials go in the **body**, never in the URL or a header, so they cannot end up in a
    /// server access log, a `URLError` description or a redirect (README §7).
    public static func tokenRequest(
        credentials: TokenCredentials,
        baseURL: URL = TossClient.baseURL
    ) -> URLRequest {
        var request = TossEndpoint.token.urlRequest(baseURL: baseURL)
        request.httpBody = formURLEncodedBody(credentials: credentials)
        return request
    }

    private func fallbackURL(baseURL: URL) -> URL {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(relative)
    }
}

// MARK: - Form encoding

extension TossEndpoint {

    /// `application/x-www-form-urlencoded` body for the token grant.
    static func formURLEncodedBody(credentials: TokenCredentials) -> Data {
        let pairs = [
            ("grant_type", "client_credentials"),
            ("client_id", credentials.clientId),
            ("client_secret", credentials.clientSecret),
        ]
        let joined = pairs
            .map { "\(percentEncodedFormComponent($0.0))=\(percentEncodedFormComponent($0.1))" }
            .joined(separator: "&")
        return Data(joined.utf8)
    }

    /// Percent-encodes one form component, byte by byte over UTF-8.
    ///
    /// Everything outside the unreserved set `A-Z a-z 0-9 - . _ ~` is escaped, which is stricter
    /// than `URLComponents.queryItems` — that leaves `+`, `&`, `=` and `;` alone, and a secret
    /// containing any of them would arrive at the server split in half or with a `+` read back as a
    /// space. A `client_secret` is opaque; it gets the strict treatment.
    static func percentEncodedFormComponent(_ value: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isFormUnreserved(byte) {
                bytes.append(byte)
            } else {
                bytes.append(UInt8(ascii: "%"))
                bytes.append(hexDigits[Int(byte >> 4)])
                bytes.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    private static func isFormUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }
}
