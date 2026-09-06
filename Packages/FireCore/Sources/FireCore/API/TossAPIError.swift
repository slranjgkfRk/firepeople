import Foundation

// MARK: - TossAPIError

/// Every failure this app can surface while talking to the Toss Securities Open API.
///
/// The associated values are *diagnostics* — the code/requestId a support request needs
/// (README §3.5). The text a person reads is `userMessageKo`, which is derived from the case and
/// never from the server's own `message` (api-notes: "`message` may be empty by policy — map from
/// `code`, don't display `message` blindly").
///
/// No case ever carries a `client_id`, a `client_secret` or an access token: the only strings that
/// reach a payload are server-authored or `URLError` descriptions, and both go through
/// ``redactingSecrets(_:)`` first (README §7 — keys must not appear in logs or error text).
public enum TossAPIError: Error, Sendable, Equatable {

    /// `POST /oauth2/token` rejected the credentials.
    ///
    /// `field` is ``clientIdField`` or ``clientSecretField`` when the OAuth2 `error_description`
    /// names one ("Client authentication failed: client_secret"), so the key-input screen can point
    /// at the box that is wrong; `nil` when the server did not say, or when no keys are stored yet.
    case invalidCredentials(field: String?)

    /// 403 from any endpoint: this device's IP is not on the WTS allowed-IP list.
    /// Deliberately distinct from 401 — api-notes: "403 = register your IP, 401 = wrong key".
    case ipNotAllowed

    /// 401 from a normal endpoint, still 401 after one token re-issue and one retry.
    case unauthorized(code: String, requestId: String?)

    /// 429 after the retry budget is spent. `retryAfter` is the server's own hint (header, else
    /// `error.data.retryAfterSeconds`, else 1s), clamped to `0...30`.
    case rateLimited(retryAfter: TimeInterval)

    /// Any other non-2xx status, including 5xx.
    case server(status: Int, code: String?, message: String?, requestId: String?)

    /// `URLError` and anything else that stopped the request from producing an HTTP response.
    case transport(String)

    /// The response was HTTP-fine but not the shape this app knows.
    case decoding(String)

    /// The two values `invalidCredentials(field:)` can name.
    public static let clientIdField = "client_id"
    /// The two values `invalidCredentials(field:)` can name.
    public static let clientSecretField = "client_secret"

    /// Drives the README §2.6 `API 키를 확인해주세요` banner (which taps through to settings).
    /// 403 is *not* an auth failure: the key is fine, the IP is not.
    public var isAuthFailure: Bool {
        switch self {
        case .invalidCredentials, .unauthorized:
            return true
        case .ipNotAllowed, .rateLimited, .server, .transport, .decoding:
            return false
        }
    }

    /// One actionable Korean sentence per case. Every one of them names the next thing to do,
    /// because the app has no other place to explain itself.
    public var userMessageKo: String {
        switch self {
        case .invalidCredentials(let field):
            switch field {
            case Self.clientIdField:
                return "client_id가 올바르지 않아요. 설정 > API 키 재입력에서 client_id를 다시 확인해 주세요."
            case Self.clientSecretField:
                return "client_secret이 올바르지 않아요. 설정 > API 키 재입력에서 client_secret을 다시 확인해 주세요."
            default:
                return "API 키가 올바르지 않아요. 설정 > API 키 재입력에서 client_id와 client_secret을 다시 입력해 주세요."
            }
        case .ipNotAllowed:
            return "허용되지 않은 IP에서 요청했어요. 토스증권 WTS의 설정 > Open API > 허용 IP 관리에서 지금 쓰는 IP를 등록해 주세요."
        case .unauthorized:
            return "API 키를 확인해주세요. 토큰이 만료됐거나 키가 폐기된 것 같아요. 설정 > API 키 재입력에서 키를 다시 등록해 주세요."
        case .rateLimited(let retryAfter):
            let seconds = max(1, Int(retryAfter.rounded(.up)))
            return "요청이 너무 잦아 잠시 제한됐어요. \(seconds)초 뒤 다음 갱신에서 자동으로 다시 시도해요."
        case .server(let status, _, _, _):
            if status >= 500 {
                return "토스증권 서버에 일시적인 문제가 있어요 (오류 \(status)). 이전 값을 그대로 두고 다음 갱신에서 다시 시도해요."
            }
            return "요청이 거부됐어요 (오류 \(status)). 잠시 뒤 다시 시도하고, 계속되면 설정에서 API 키를 다시 등록해 주세요."
        case .transport:
            return "네트워크에 연결할 수 없어요. 연결 상태를 확인해 주세요. 그동안은 마지막으로 갱신된 값을 보여줄게요."
        case .decoding:
            return "응답을 해석하지 못했어요. API 응답 형식이 바뀐 것 같아요. 앱 업데이트를 확인해 주세요."
        }
    }
}

extension TossAPIError: LocalizedError {
    /// So `error.localizedDescription` is the Korean sentence too, wherever one slips through.
    public var errorDescription: String? { userMessageKo }
}

// MARK: - Building an error from a response

extension TossAPIError {

    /// The largest delay this client will ever wait on a 429, whatever the server asks for.
    static let maxRetryAfter: TimeInterval = 30
    /// Used when neither the `Retry-After` header nor `error.data.retryAfterSeconds` is present.
    static let defaultRetryAfter: TimeInterval = 1

    /// Maps an HTTP status plus a parsed error body onto a case.
    ///
    /// - Parameter isTokenEndpoint: `POST /oauth2/token` answers with the OAuth2 error shape and a
    ///   401/400 there means "wrong keys", not "expired token" — which is the whole difference
    ///   between `invalidCredentials` and `unauthorized`.
    static func make(
        status: Int,
        body: TossErrorBody,
        retryAfterHeader: String?,
        isTokenEndpoint: Bool
    ) -> TossAPIError {
        if status == 403 {
            return .ipNotAllowed
        }
        if status == 429 {
            return .rateLimited(retryAfter: resolvedRetryAfter(header: retryAfterHeader, body: body))
        }
        if isTokenEndpoint {
            if status == 400 || status == 401 {
                return .invalidCredentials(field: body.credentialField)
            }
            return .server(
                status: status,
                code: body.code,
                message: body.message,
                requestId: body.requestId
            )
        }
        if status == 401 {
            return .unauthorized(code: body.code ?? "unauthorized", requestId: body.requestId)
        }
        return .server(status: status, code: body.code, message: body.message, requestId: body.requestId)
    }

    /// `Retry-After` header first, then `error.data.retryAfterSeconds`, then 1s — clamped to 0…30s.
    static func resolvedRetryAfter(header: String?, body: TossErrorBody) -> TimeInterval {
        let raw = parseRetryAfterHeader(header) ?? body.retryAfterSeconds ?? defaultRetryAfter
        return min(max(raw, 0), maxRetryAfter)
    }

    /// The header is delta-seconds in practice. An HTTP-date form is not honoured; the caller falls
    /// back to the body value and then to the 1s default, which is never worse than waiting a minute.
    static func parseRetryAfterHeader(_ header: String?) -> TimeInterval? {
        guard let trimmed = header?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        guard let seconds = TimeInterval(trimmed), seconds.isFinite else { return nil }
        return seconds
    }
}

// MARK: - Secret redaction

extension TossAPIError {

    /// Strips anything that looks like a credential out of a diagnostic string before it is stored
    /// in an error case. Nothing in this app puts a key in a URL or a message, so this is a belt to
    /// go with the braces (README §7).
    static func redactingSecrets(_ message: String) -> String {
        var result = message
        for marker in ["client_secret=", "client_id=", "access_token=", "Bearer "] {
            result = redacting(marker: marker, in: result)
        }
        return result
    }

    /// Replaces the run of characters that follows `marker` with `***`, in one pass.
    private static func redacting(marker: String, in text: String) -> String {
        guard text.range(of: marker) != nil else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            guard let markerRange = text.range(of: marker, range: index..<text.endIndex) else {
                result.append(contentsOf: text[index..<text.endIndex])
                break
            }
            result.append(contentsOf: text[index..<markerRange.upperBound])
            var valueEnd = markerRange.upperBound
            while valueEnd < text.endIndex, !isSecretDelimiter(text[valueEnd]) {
                valueEnd = text.index(after: valueEnd)
            }
            if valueEnd > markerRange.upperBound {
                result.append("***")
            }
            index = valueEnd
        }
        return result
    }

    private static func isSecretDelimiter(_ character: Character) -> Bool {
        character.isWhitespace || "&?\"',;}]".contains(character)
    }
}

// MARK: - Error envelopes

/// The two error bodies the API uses, parsed into one flat shape.
///
/// - The common envelope, on every endpoint but the token one:
///   `{"error":{"requestId":…,"code":…,"message":…,"data":{"retryAfterSeconds":1}}}`
/// - The OAuth2 envelope, only on `POST /oauth2/token`:
///   `{"error":"invalid_client","error_description":"Client authentication failed: client_secret"}`
///
/// Parsed with `JSONSerialization` rather than `Codable` on purpose: `"error"` is an object in one
/// shape and a string in the other, `data` is free-form, and an error body that is itself malformed
/// must degrade to `.unparsed` instead of masking the status code that actually matters.
struct TossErrorBody: Sendable, Equatable {

    enum Shape: Sendable, Equatable {
        /// `{"error": { … }}`
        case common
        /// `{"error": "…", "error_description": "…"}`
        case oauth
        /// Empty, non-JSON, or JSON this app does not recognise.
        case unparsed
    }

    var shape: Shape = .unparsed
    var requestId: String?
    /// `error.code` for the common shape, `error` for the OAuth2 shape.
    var code: String?
    /// `error.message` for the common shape, `error_description` for the OAuth2 shape.
    var message: String?
    /// `error.data.retryAfterSeconds`.
    var retryAfterSeconds: TimeInterval?

    static let unparsed = TossErrorBody()

    /// Which credential the server blamed, if it named one. `client_secret` is tested first: it is
    /// the longer literal and neither string is a substring of the other.
    var credentialField: String? {
        let haystack = [message, code].compactMap { $0 }.joined(separator: " ")
        if haystack.contains(TossAPIError.clientSecretField) { return TossAPIError.clientSecretField }
        if haystack.contains(TossAPIError.clientIdField) { return TossAPIError.clientIdField }
        return nil
    }

    static func parse(_ data: Data) -> TossErrorBody {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return .unparsed }

        // OAuth2 shape — `error` is a string.
        if let oauthCode = nonEmptyString(root["error"]) {
            return TossErrorBody(
                shape: .oauth,
                requestId: nil,
                code: oauthCode,
                message: nonEmptyString(root["error_description"]).map(TossAPIError.redactingSecrets),
                retryAfterSeconds: nil
            )
        }

        // Common shape — `error` is an object.
        if let payload = root["error"] as? [String: Any] {
            let retryAfter = (payload["data"] as? [String: Any])?["retryAfterSeconds"]
            return TossErrorBody(
                shape: .common,
                requestId: nonEmptyString(payload["requestId"]),
                code: nonEmptyString(payload["code"]),
                message: nonEmptyString(payload["message"]).map(TossAPIError.redactingSecrets),
                retryAfterSeconds: seconds(from: retryAfter)
            )
        }

        return .unparsed
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The field is a JSON number in every recorded response; a numeric string is accepted too.
    private static func seconds(from value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return TimeInterval(truncating: number) }
        if let text = value as? String { return TimeInterval(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
