#if canImport(Security)
import Foundation
import Security

/// The only failure a Keychain operation reports.
///
/// `status` carries the `OSStatus` **alone**. Nothing that touches key material — not the value,
/// not the account name it was stored under — is ever attached to an error, because errors get
/// logged, mailed and screenshotted (README §7).
public enum KeychainError: Error, Sendable, Equatable {
    case status(OSStatus)
    case encoding
}

/// `client_id`, `client_secret` and the cached access token, in the shared Keychain.
///
/// Every item is a `kSecClassGenericPassword` under one service, distinguished by
/// `kSecAttrAccount`, and protected with `kSecAttrAccessibleAfterFirstUnlock` so the widget can
/// refresh while the device is locked (README §7). With an access group the app and the widget see
/// the same items, which is what makes the single-token rule (`docs/api-notes.md` § Auth) workable.
///
/// The type is a value type holding two `String`s; the Keychain itself is the shared, thread-safe
/// state, so instances are freely `Sendable`.
public struct KeychainStore: CredentialProviding, TokenCaching, Sendable {
    /// `kSecAttrService` for every item this store owns.
    public static let defaultService = "com.jay-lab.firepeople.toss"

    /// `kSecAttrAccount` values. Stable strings: renaming one orphans the stored item.
    private enum Account {
        static let clientId = "clientId"
        static let clientSecret = "clientSecret"
        static let accessToken = "accessToken"
        static let all = [clientId, clientSecret, accessToken]
    }

    private let service: String
    private let accessGroup: String?

    /// - Parameter accessGroup: `nil` drops `kSecAttrAccessGroup` from every query. Required for
    ///   `swift test` on macOS, where the process carries no `keychain-access-groups` entitlement
    ///   and any query naming a group fails with `errSecMissingEntitlement`.
    public init(service: String = KeychainStore.defaultService,
                accessGroup: String? = AppGroup.keychainAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - CredentialProviding

    /// `nil` unless both halves are present and non-empty — a half-written pair is not usable, and
    /// the app treats `nil` as "onboarding step 2 is unfinished".
    public func credentials() throws -> TokenCredentials? {
        guard let idData = try read(Account.clientId),
              let secretData = try read(Account.clientSecret),
              let clientId = String(data: idData, encoding: .utf8),
              let clientSecret = String(data: secretData, encoding: .utf8),
              !clientId.isEmpty, !clientSecret.isEmpty
        else { return nil }
        return TokenCredentials(clientId: clientId, clientSecret: clientSecret)
    }

    /// Overwrites both halves. Called the moment onboarding step 2 accepts input (README §2.1),
    /// before the connection test, so an abandoned onboarding still resumes with the keys in place.
    public func saveCredentials(_ credentials: TokenCredentials) throws {
        guard let idData = credentials.clientId.data(using: .utf8),
              let secretData = credentials.clientSecret.data(using: .utf8)
        else { throw KeychainError.encoding }
        try write(idData, account: Account.clientId)
        try write(secretData, account: Account.clientSecret)
    }

    // MARK: - TokenCaching

    /// The shared access token, or `nil` when there is none.
    ///
    /// A payload that no longer decodes (older build, truncated write) also reads as `nil`: the
    /// client then issues a fresh token, which is strictly better than failing a refresh.
    public func loadToken() throws -> AccessToken? {
        guard let data = try read(Account.accessToken) else { return nil }
        return StorageCoding.decode(AccessToken.self, from: data)
    }

    public func saveToken(_ token: AccessToken) throws {
        // Any encoding failure is reported as `.encoding`; an `EncodingError` would carry a
        // debug description of the value being encoded, i.e. of the token.
        guard let data = try? StorageCoding.encode(token) else { throw KeychainError.encoding }
        try write(data, account: Account.accessToken)
    }

    public func clearToken() throws {
        try delete(Account.accessToken)
    }

    // MARK: - Reset

    /// Wipes every item this store owns — README §2.3 "API 키 삭제 및 초기화".
    ///
    /// Deletion is attempted for all three items even if one fails, so a partial failure cannot
    /// leave a secret behind; the first error is rethrown afterwards.
    public func clearAll() throws {
        var firstError: (any Error)?
        for account in Account.all {
            do {
                try delete(account)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    // MARK: - Keychain plumbing

    private func baseQuery(for account: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        // Access groups and `kSecAttrAccessible` exist only in the data-protection keychain, which
        // is opt-in on macOS and demands a `keychain-access-groups` entitlement. With no access
        // group — the `swift test` case — fall back to the file-based keychain so an unentitled
        // test binary can still read and write.
        query[kSecUseDataProtectionKeychain as String] = (accessGroup != nil)
        #endif
        return query
    }

    /// The queries to try, in order: the shared access group first, then the process's own
    /// keychain.
    ///
    /// The fallback exists because a build can legitimately lack the `keychain-access-groups`
    /// entitlement — every **simulator** build does, since no provisioning profile is applied, and
    /// so does a device build whose App ID has not had App Groups / Keychain Sharing enabled. In
    /// those builds every grouped `SecItem*` call returns `errSecMissingEntitlement` (-34018), and
    /// without this fallback onboarding dead-ends at "연결 테스트" with an opaque OSStatus even
    /// though the API call itself succeeded.
    ///
    /// This is a **degraded** mode, not an equivalent one: items written outside the group are
    /// invisible to the widget, so the widget cannot mint or share the access token and falls back
    /// to rendering the stored snapshot. Since only one token is valid per client
    /// (`docs/api-notes.md` § Auth), two processes holding private caches would revoke each other —
    /// which is exactly why the widget must not refresh when it cannot see the shared token.
    /// ``isSharedAccessGroupAvailable`` reports which mode is in effect so the UI can say so
    /// instead of leaving the user to wonder why the widget never updates.
    private func queries(for account: String) -> [[String: Any]] {
        guard let accessGroup else { return [baseQuery(for: account, accessGroup: nil)] }
        return [
            baseQuery(for: account, accessGroup: accessGroup),
            baseQuery(for: account, accessGroup: nil),
        ]
    }

    /// Whether this process can actually reach the shared access group.
    ///
    /// `false` means the app and the widget do **not** share credentials or the token: the widget
    /// will render the last snapshot but never refresh. Probed rather than assumed, because the
    /// entitlement is decided at signing time, not build time.
    public var isSharedAccessGroupAvailable: Bool {
        guard let accessGroup else { return false }
        var query = baseQuery(for: Account.clientId, accessGroup: accessGroup)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Both "found it" and "nothing stored yet" prove the group is reachable; only the
        // entitlement error proves it is not.
        return SecItemCopyMatching(query as CFDictionary, nil) != errSecMissingEntitlement
    }

    private var writeAttributes: [String: Any] {
        [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }

    /// Runs `operation` against each candidate query until one gets past the entitlement check.
    ///
    /// Only `errSecMissingEntitlement` advances to the next candidate; every other status is that
    /// candidate's real answer and is returned as-is. The last candidate's status is final.
    private func withCandidateQueries<T>(
        for account: String,
        _ operation: ([String: Any]) -> (status: OSStatus, value: T?)
    ) -> (status: OSStatus, value: T?) {
        let candidates = queries(for: account)
        var result: (status: OSStatus, value: T?) = (errSecMissingEntitlement, nil)
        for query in candidates {
            result = operation(query)
            if result.status != errSecMissingEntitlement { return result }
        }
        return result
    }

    private func read(_ account: String) throws -> Data? {
        let result = withCandidateQueries(for: account) { base -> (OSStatus, Data?) in
            var query = base
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        }

        switch result.status {
        case errSecSuccess:
            return result.value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(result.status)
        }
    }

    /// Update first, add when there is nothing to update: a plain `SecItemAdd` would fail with
    /// `errSecDuplicateItem` every time a key is re-entered (README §2.3 "API 키 재입력").
    private func write(_ data: Data, account: String) throws {
        var attributes = writeAttributes
        attributes[kSecValueData as String] = data
        let writeAttributes = attributes

        let result = withCandidateQueries(for: account) { query -> (OSStatus, Void?) in
            let updateStatus = SecItemUpdate(query as CFDictionary, writeAttributes as CFDictionary)
            guard updateStatus == errSecItemNotFound else { return (updateStatus, nil) }
            var addQuery = query
            addQuery.merge(writeAttributes) { _, new in new }
            return (SecItemAdd(addQuery as CFDictionary, nil), nil)
        }

        guard result.status == errSecSuccess else { throw KeychainError.status(result.status) }
    }

    private func delete(_ account: String) throws {
        // Delete from every reachable location, not just the first: a store that fell back to the
        // private keychain earlier may have left an item there that a later entitled build would
        // otherwise strand. README §2.3's reset has to leave nothing behind.
        var firstFailure: OSStatus?
        var sawReachableCandidate = false
        for query in queries(for: account) {
            let status = SecItemDelete(query as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                sawReachableCandidate = true
            case errSecMissingEntitlement:
                continue
            default:
                sawReachableCandidate = true
                firstFailure = firstFailure ?? status
            }
        }
        if let firstFailure { throw KeychainError.status(firstFailure) }
        guard sawReachableCandidate else { throw KeychainError.status(errSecMissingEntitlement) }
    }
}
#endif
