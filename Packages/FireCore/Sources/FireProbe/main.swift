//
//  FireProbe — read-only live check against the Toss Securities Open API.
//
//  README M1's definition of done is "print the real account valuation balance in the terminal".
//  This is that, and it doubles as the way to re-verify the integration whenever the API moves:
//  it exercises the exact same `TossClient` and `RefreshService` the app and the widget use, so a
//  green run here means the shipping code path works against production.
//
//  It calls only GET endpoints plus the token POST. There is no order code in FireCore to call.
//
//  Usage:
//      swift run --package-path Packages/FireCore FireProbe [path/to/.env]
//
//  Credentials come from TOSS_CLIENT_ID / TOSS_CLIENT_SECRET, or from a two-line .env
//  (line 1 = client_id, line 2 = client_secret; blank lines and # comments ignored).
//  Neither value is ever printed.
//

import Foundation
import FireCore

// MARK: - Credentials

/// Reads the two keys, preferring the environment so CI never needs a file on disk.
func loadCredentials(envPath: String?) -> TokenCredentials? {
    let environment = ProcessInfo.processInfo.environment
    if let id = environment["TOSS_CLIENT_ID"], let secret = environment["TOSS_CLIENT_SECRET"],
       !id.isEmpty, !secret.isEmpty {
        return TokenCredentials(clientId: id, clientSecret: secret)
    }

    let path = envPath ?? FileManager.default.currentDirectoryPath + "/.env"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

    let values = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        // Tolerates both the bare `value` form and a `name = value` form.
        .map { line -> String in
            guard let separator = line.firstIndex(of: "=") else { return line }
            return String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }

    guard values.count >= 2 else { return nil }
    return TokenCredentials(clientId: values[0], clientSecret: values[1])
}

/// Only ever shows the issuer prefix, never enough to use.
func fingerprint(_ value: String) -> String {
    let prefix = value.prefix(10)
    return "\(prefix)… (\(value.count) chars)"
}

// MARK: - Wiring

/// A `CredentialProviding` that hands over the pair we just read, so the probe never touches the
/// Keychain (which on macOS would need an entitlement the app has and a CLI does not).
struct StaticCredentials: CredentialProviding {
    let value: TokenCredentials
    func credentials() throws -> TokenCredentials? { value }
}

let arguments = CommandLine.arguments
guard let credentials = loadCredentials(envPath: arguments.count > 1 ? arguments[1] : nil) else {
    FileHandle.standardError.write(Data("""
        No credentials. Set TOSS_CLIENT_ID and TOSS_CLIENT_SECRET, or pass a two-line .env path.

        """.utf8))
    exit(2)
}

print("FIRE D-Day — live read-only API check")
print(String(repeating: "─", count: 62))
print("client_id     \(fingerprint(credentials.clientId))")
print("client_secret \(fingerprint(credentials.clientSecret))")
print("")

let client = TossClient(
    credentials: StaticCredentials(value: credentials),
    tokenCache: InMemoryTokenCache(),
    session: .fire(timeout: 15)
)

func explain(_ error: Error) -> String {
    guard let apiError = error as? TossAPIError else { return "\(error)" }
    return "\(apiError.userMessageKo)  [\(apiError)]"
}

// MARK: - 1. Accounts

let accounts: [TossAccount]
do {
    accounts = try await client.verifyConnection()
} catch {
    print("✗ 연결 실패: \(explain(error))")
    exit(1)
}

print("GET /api/v1/accounts")
guard !accounts.isEmpty else {
    print("  (no BROKERAGE accounts on this client)")
    exit(1)
}
for account in accounts {
    print("  seq \(account.accountSeq)  \(account.maskedAccountNo)  \(account.accountType.displayNameKo)")
}
print("")

// MARK: - 2. Exchange rate + holdings, through the real RefreshService

let settingsStore = InMemorySettingsStore()
let snapshotStore = InMemorySnapshotStore()

// A target that makes the percentage meaningful; the D-day maths is unit-tested separately.
var settings = Settings.fresh
settings.selectedAccountSeqs = accounts.map(\.accountSeq)
settings.targetAmount = 1_000_000_000
settings.onboardingCompleted = true
try settingsStore.save(settings)

do {
    let rate = try await client.exchangeRate(base: .usd, quote: .krw)
    print("GET /api/v1/exchange-rate?baseCurrency=USD&quoteCurrency=KRW")
    print("  rate \(rate.rate) KRW/USD")
    print("")

    print("GET /api/v1/holdings   (X-Tossinvest-Account per account)")
    for account in accounts {
        let holdings = try await client.holdings(accountSeq: account.accountSeq)
        let converted = holdings.marketValue.totalKRW(usdKrwRate: rate.rate)
        print("  seq \(account.accountSeq)  krw \(holdings.marketValue.krw)"
              + "  usd \(holdings.marketValue.usd)"
              + "  → ₩\(converted)  (\(holdings.itemCount) holdings)")
    }
    print("")
} catch {
    print("✗ 조회 실패: \(explain(error))")
    exit(1)
}

let service = RefreshService(client: client, settingsStore: settingsStore, snapshotStore: snapshotStore)
guard let snapshot = await service.refresh() else {
    print("✗ RefreshService returned no snapshot")
    exit(1)
}

print("RefreshService.refresh()")
print("  status        \(snapshot.status.rawValue)")
print("  krwAmount     \(snapshot.krwAmount)")
print("  usdAmount     \(snapshot.usdAmount)")
print("  usdKrwRate    \(snapshot.usdKrwRate)")
print("  currentAssets ₩\(snapshot.currentAssets)")
print("")

// MARK: - 3. What the screen and the widget would actually render

let now = Date()
let state = FireState.make(settings: settings, snapshot: snapshot, now: now)

print("Rendered (README §2.2 / §2.5)")
print(String(repeating: "─", count: 62))
print("  FIRE까지")
print("  \(FireFormatter.dDay(state.dDay))")
print("  \(FireFormatter.targetDate(state.targetDate))")
print("  \(FireFormatter.percent(state.progress))"
      + "   \(FireFormatter.amountKo(state.currentAssets)) / \(FireFormatter.amountKo(state.targetAmount))")
print("  남은 금액 \(state.isGoalReached ? "목표 달성" : FireFormatter.amountKo(state.remaining))")
print("  마지막 갱신 \(FireFormatter.refreshedAt(snapshot.fetchedAt, now: now))")
print("")
print("Widget (README §2.4)")
print("  small   \(FireFormatter.dDay(state.dDay)) / \(FireFormatter.percent(state.progress))")
print("  medium  \(FireFormatter.amountCompact(state.currentAssets)) / \(FireFormatter.amountCompact(state.targetAmount))")
print("")
print("✓ live check passed — read-only endpoints only")
