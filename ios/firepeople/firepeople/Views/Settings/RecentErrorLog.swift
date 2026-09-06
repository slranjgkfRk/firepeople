import Foundation
import FireCore

// MARK: - Redaction

/// Scrubs anything that could be a credential out of free-form text before it is written anywhere
/// (README §7: keys never reach logs, and "mask them even in debug logs").
///
/// The rule is deliberately paranoid — it redacts first and asks questions later:
///
/// * any token containing the issued key prefixes (`tsck_` / `tssk_`),
/// * any ASCII token of 20 characters or more that mixes letters and digits (access tokens, JWTs,
///   `Authorization` header values, base64 blobs),
/// * any ASCII token of 40 characters or more containing a `.` (a JWT split across its dots).
///
/// Korean text is never touched: a token has to be pure ASCII to be considered, and real error
/// messages from the API are Korean sentences.
enum SecretRedactor {

    /// Characters that make up one "token"; everything else is a separator and is preserved as-is.
    private static let tokenCharacters = Set("._-+/=~:")

    /// Redacts every suspicious token in `text` and clamps the result to `maxLength`.
    static func redact(_ text: String, maxLength: Int) -> String {
        var output = ""
        var token = ""

        func flushToken() {
            guard !token.isEmpty else { return }
            output += isSensitive(token) ? "***" : token
            token = ""
        }

        for character in text {
            if character.isLetter || character.isNumber || tokenCharacters.contains(character) {
                token.append(character)
            } else {
                flushToken()
                output.append(character)
            }
        }
        flushToken()

        return clamp(output.trimmingCharacters(in: .whitespacesAndNewlines), to: maxLength)
    }

    /// For values that are identifiers rather than prose — an error `code`, an `X-Request-Id`.
    ///
    /// These are meant to be readable (README §3.5 asks for them by name), so the length heuristic
    /// is not applied; only an actual key prefix or a `Bearer` value collapses the whole value.
    static func sanitizeIdentifier(_ value: String, maxLength: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.contains("tsck_") || lowered.contains("tssk_") || lowered.contains("bearer ") {
            return "***"
        }
        let singleLine = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return clamp(singleLine, to: maxLength)
    }

    private static func isSensitive(_ token: String) -> Bool {
        let lowered = token.lowercased()
        if lowered.contains("tsck_") || lowered.contains("tssk_") { return true }
        guard token.count >= 20, token.allSatisfy({ $0.isASCII }) else { return false }
        let hasLetter = token.contains { $0.isLetter }
        let hasDigit = token.contains { $0.isNumber }
        if hasLetter && hasDigit { return true }
        return token.count >= 40 && token.contains(".")
    }

    private static func clamp(_ value: String, to maxLength: Int) -> String {
        guard value.count > maxLength, maxLength > 1 else { return value }
        return String(value.prefix(maxLength - 1)) + "…"
    }
}

// MARK: - Entry

/// One recorded API failure, listed under 설정 › 정보 › 최근 오류 (README §3.5).
///
/// Exactly the three things README asks to keep — `code`, `message`, `X-Request-Id` — plus when it
/// happened. No URL, no headers, no request body, no account number. Every string is pushed through
/// ``SecretRedactor`` inside `init`, so there is no code path that can put a key or an access token
/// into the log even if a future error type were to carry one.
struct RecentError: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let code: String
    let message: String
    let requestId: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        code: String,
        message: String,
        requestId: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.code = SecretRedactor.sanitizeIdentifier(code, maxLength: 64)
        self.message = SecretRedactor.redact(message, maxLength: 300)
        self.requestId = requestId.map { SecretRedactor.sanitizeIdentifier($0, maxLength: 64) }
        self.timestamp = timestamp
    }
}

// MARK: - Log

/// A 20-entry ring buffer of the most recent API failures, in the App Group `UserDefaults` under
/// `"recentErrors.v1"` (README §3.5: "설정 › 정보 › 최근 오류").
///
/// Newest entry first. Writing is `NSLock`-serialized because the refresh that records an error can
/// run off the main actor, and a read-modify-write on `UserDefaults` is not atomic on its own.
///
/// Call ``record(_:at:)`` from wherever a `TossAPIError` is caught — the app's refresh path — and
/// never construct entries from anything but a `TossAPIError`, which by contract carries no secret.
final class RecentErrorLog: @unchecked Sendable {

    /// Versioned so a shape change can migrate instead of crashing on an old payload.
    static let storageKey = "recentErrors.v1"

    /// README's "최근 오류" list is a diagnostic aid, not history: 20 entries is plenty.
    static let maxEntries = 20

    /// The instance the app uses. Falls back to process memory when the App Group container is not
    /// available (previews, a simulator run without the entitlement) rather than dropping writes.
    static let shared = RecentErrorLog()

    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var memoryFallback: [RecentError] = []

    init(defaults: UserDefaults? = AppGroup.defaults) {
        self.defaults = defaults
    }

    // MARK: Writing

    func record(code: String, message: String, requestId: String? = nil, at timestamp: Date = Date()) {
        let entry = RecentError(code: code, message: message, requestId: requestId, timestamp: timestamp)
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeSubrange(Self.maxEntries...)
        }
        storeLocked(entries)
    }

    /// Records a `TossAPIError`.
    ///
    /// The associated values used here are a status code, an error code, a `requestId` and the
    /// API's own Korean message — never a credential. `invalidCredentials` carries the *name* of the
    /// field the server rejected (`client_id` / `client_secret`), never its value, and even that is
    /// mapped to a fixed Korean string rather than interpolated blindly.
    func record(_ error: TossAPIError, at timestamp: Date = Date()) {
        let code: String
        let message: String
        var requestId: String?

        switch error {
        case .invalidCredentials(let field):
            code = "invalid_client"
            switch field {
            case "client_id"?: message = "client_id 인증에 실패했습니다."
            case "client_secret"?: message = "client_secret 인증에 실패했습니다."
            default: message = "API 키 인증에 실패했습니다."
            }
        case .ipNotAllowed:
            code = "ip-not-allowed"
            message = "허용 IP에 등록되지 않은 기기입니다. (403)"
        case .unauthorized(let errorCode, let id):
            code = errorCode
            requestId = id
            message = error.userMessageKo
        case .rateLimited(let retryAfter):
            code = "rate-limited"
            message = "요청 한도를 초과했습니다. \(Int(retryAfter.rounded()))초 후 재시도합니다."
        case .server(let status, let errorCode, let serverMessage, let id):
            code = errorCode ?? "http-\(status)"
            requestId = id
            let trimmed = serverMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = trimmed.isEmpty ? error.userMessageKo : trimmed
        case .transport(let detail):
            code = "transport"
            message = detail.isEmpty ? error.userMessageKo : detail
        case .decoding(let detail):
            code = "decoding"
            message = detail.isEmpty ? error.userMessageKo : detail
        }

        record(code: code, message: message, requestId: requestId, at: timestamp)
    }

    /// Records a refresh that came back downgraded.
    ///
    /// `RefreshService.refresh()` never throws — it hands back the previous snapshot with only its
    /// `status` lowered — so on that path the underlying `TossAPIError` is gone by the time the app
    /// sees the result. This is the coarse-grained fallback for it: call it after a refresh whose
    /// snapshot came back with a status other than `.ok`, and the user still gets a dated entry in
    /// 최근 오류. `.ok` records nothing.
    ///
    /// Where the error object *is* in hand — the onboarding 연결 테스트, which calls
    /// `verifyConnection()` and catches — prefer ``record(_:at:)``: it carries the `code` and the
    /// `requestId` that README §3.5 actually asks for.
    func record(status: FetchStatus, at timestamp: Date = Date()) {
        switch status {
        case .ok:
            return
        case .staleNetwork:
            record(code: "stale-network",
                   message: "갱신에 실패했습니다. 마지막 값을 그대로 표시합니다.",
                   at: timestamp)
        case .authFailed:
            record(code: "auth-failed",
                   message: "API 키 인증에 실패했습니다. 키를 확인해주세요.",
                   at: timestamp)
        case .ipBlocked:
            record(code: "ip-not-allowed",
                   message: "허용 IP에 등록되지 않은 기기입니다. 토스증권에 이 기기의 IP를 등록해주세요.",
                   at: timestamp)
        }
    }

    // MARK: Reading

    /// Newest first, at most `limit` entries.
    func recent(limit: Int = RecentErrorLog.maxEntries) -> [RecentError] {
        lock.lock()
        defer { lock.unlock() }
        return Array(loadLocked().prefix(max(0, limit)))
    }

    /// Wipes the log. Part of 설정 › API 키 삭제 및 초기화, and available on its own in 정보.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        memoryFallback = []
        defaults?.removeObject(forKey: Self.storageKey)
    }

    // MARK: Storage

    private func loadLocked() -> [RecentError] {
        guard let defaults else { return memoryFallback }
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecentError].self, from: data)) ?? []
    }

    private func storeLocked(_ entries: [RecentError]) {
        guard let defaults else {
            memoryFallback = entries
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
