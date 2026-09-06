# FIRE D-Day

A personal countdown app that fetches Toss Securities account evaluation balances to display **the remaining days (D-Day) and progress percentage (%) toward the FIRE goal**. Directly adopts the UX of military discharge countdown apps. Just one main screen and one home widget—nothing more.

> This document serves as the single source of truth for development. If decisions change during implementation, update this document before modifying code. `[TODO]` tags indicate items to fill before or during development, and `[TBD]` tags indicate undecided items.

---

## 0. Overview at a Glance

| Item | Description |
| --- | --- |
| Purpose | Display FIRE target date D-Day + asset progress % on a single screen and widget |
| Target User | Just myself (no public release planned, though the "enter personal API key" flow is built like a general user app) |
| Data Source | Toss Securities Open API — account valuation balance only |
| Platform | iOS first → Android upon completion |
| Backend | None. App calls the API directly and stores data only on-device |
| Refresh | Hourly or once daily (selectable in settings) |
| Trading / Orders | Never. Read-only API only |

---

## 1. Product Definition

### 1.1 Core Concepts and Formulas

The user enters only two values:

| Name | Key | Description |
| --- | --- | --- |
| FIRE Target Amount | `targetAmount` | KRW integer. Entered manually (no automated calculators like the 4% rule) |
| Target FIRE Date | `targetDate` | Date. Equivalent to the "discharge date" in military countdown apps |

The API provides only one value:

| Name | Key | Description |
| --- | --- | --- |
| Current Assets | `currentAssets` | Total evaluation balance (KRW converted) across selected Toss Securities accounts |

Formulas:

```
dDay        = targetDate - today            # In days, based on midnight (KST)
progress    = currentAssets / targetAmount  # 0.0 ~ ∞, values over 100.0% allowed for display
remaining   = max(targetAmount - currentAssets, 0)
```

- Progress is **asset-based**, unlike military countdown apps which track "days elapsed / total service days".
- D-Day and progress are independent of each other. Asset growth does not alter the D-Day. (See §12 TBD for automated projected date calculation).
- `today` is fixed to midnight in the **Asia/Seoul** timezone, rather than the device's local time, so numbers remain stable even when accessed abroad.

### 1.2 Non-Goals (What NOT to Build)

- API calls that alter account state, such as orders, modifications, or cancellations
- Manual asset inputs (savings deposits, pensions, real estate, etc.)
- Per-ticker profit/loss screens (Toss Securities app already handles this)
- Emotional or gamification elements like rank systems, motivational quotes, or shareable cards
- Backend servers, user logins, accounts, or push notification servers
- Advertisements or analytics SDKs

---

## 2. Screens and UX

Strictly follows the structure of military discharge countdown apps: **A single number dominates the screen; everything else is secondary.**

### 2.1 Onboarding (First-time launch only)

```
[1] Guide        Explanation that Toss Securities Open API keys are required + where to issue them
                 (WTS 설정 > Open API — issuance is immediate)
                 Must also state that the device's public IP has to be registered under
                 설정 > Open API > 허용 IP 관리, or every call fails with 403
[2] Key Input    Enter client_id / client_secret → [Test Connection] button
                 Success: Navigate to account selection / Failure: Display error code + message as-is
[3] Account Select Checkboxes for accounts returned by API (multi-select supported, all selected by default)
                 Preview of current valuation balance next to each account
[4] Goal Input   FIRE Target Amount (KRW, auto-formatting with thousands commas)
                 Target FIRE Date (DatePicker, future dates only)
[5] Complete     Navigate to main screen. Concurrently saves first snapshot + refreshes widget
```

- Onboarding supports backward navigation. If abandoned halfway, it resumes on next launch (retains entered values, immediately saves keys to Keychain).
- Key input fields use secure text entry. Pasting is permitted.

### 2.2 Main Screen

```
┌──────────────────────────────┐
│  Until FIRE                  │
│                              │
│         D-1,234              │  ← Takes up 60% of screen height. This is the core app.
│                              │
│  2029.12.31 (Wed)            │
│                              │
│  ████████████░░░░░░░  61.2%  │  ← Progress bar + percentage
│  ₩123,450,000 / ₩200,000,000 │
│  Remaining: ₩76,550,000      │
│                              │
│  Last updated Today 14:00    │
│                        ⚙     │
└──────────────────────────────┘
```

- Manual refresh via pull-to-refresh.
- Auto-refreshes on entering foreground if the last refresh is older than the configured refresh interval.
- Displays a small spinner during refresh without clearing the numbers. Preserving previous values is the rule.
- Dark mode support (follows system setting).

### 2.3 Settings Screen

| Item | Action |
| --- | --- |
| Edit Target Amount | Immediate update, triggers widget reload |
| Edit Target Date | Immediate update, triggers widget reload |
| Reselect Accounts | Reuses Onboarding step [3] |
| Refresh Interval | Toggle: `Hourly` / `Once daily` |
| Re-enter API Keys | Reuses Onboarding step [2] |
| Delete API Keys & Reset App | Confirmation dialog → Wipe Keychain, snapshots, and settings entirely → Return to onboarding |
| How to Add Widget | Text guide |
| About | Version, explicit disclaimer: "Uses read-only APIs exclusively" |

### 2.4 Home Widget (Required)

| Size | Content |
| --- | --- |
| Small | `D-1,234` prominent, smaller `61.2%` below |
| Medium | Left: `D-1,234` + target date; Right: progress bar + % + `₩1.2억 / 2억` (or abbreviated amount) |
| Lock Screen (iOS) | `[TBD]` Circular gauge with %, or inline text `D-1,234 · 61%` |

- Tapping the widget opens the main app screen.
- The widget **must automatically update the D-Day number at midnight**, even without a network connection. (See §4.2)
- To accommodate privacy concerns regarding exposed financial amounts on widgets, provide a `Hide amounts on widget` toggle in Settings (default: OFF). When enabled, removes the amount row in Medium widget, leaving only the percentage.

### 2.5 Number Formatting Rules

| Value | Format | Example |
| --- | --- | --- |
| D-day | `D-` + thousands separator | `D-1,234`, `D-DAY`, `D+12` |
| Amount (Body text) | 100M/10K KRW units (억/만 단위), truncate below 10K | `1억 2,345만원`, `7,655만원`, `2억원` |
| Amount (Widget abbreviated) | Hundred-million unit with 1 decimal place; ten-thousand unit if under 100M | `1.2억`, `7,655만` |
| Progress | 1 decimal place | `61.2%`, `100.0%`, `103.7%` |
| Date | `yyyy.MM.dd (E)` | `2029.12.31 (Wed)` |
| Refresh Timestamp | `Today HH:mm` if today, else `M.d HH:mm` | `Today 14:00`, `9.5 18:00` |

### 2.6 UI States

| State / Scenario | Display |
| --- | --- |
| Progress ≥ 100% | Full progress bar + color change; remaining amount text → `Goal Reached` (`목표 달성`) |
| Target Date Arrived | `D-DAY` |
| Target Date Passed | `D+n` (app continues to function; shows a one-time banner suggesting target date update) |
| Refresh Failed (Network) | Preserves last snapshot + top banner: `Refresh failed · Last updated 3 hours ago` |
| 401 / Revoked Key | Preserves last snapshot + banner: `Please check your API key` → tap to open Settings |
| 403 / IP Not Allowed | Preserves last snapshot + banner: `Register this device's IP in Toss Securities` → tap to open Settings. Never retried — it cannot succeed until the user acts |
| 429 | Not shown to user. Backs off and retries automatically according to `Retry-After` (§3.5) |
| No Snapshot (Failure immediately after onboarding) | Displays `D-day`, `--%` in place of progress, and a retry button |

---

## 3. Toss Securities Open API Integration

### 3.1 Key Issuance

> **Verified 2026-09-06** against spec v1.2.14. Full working notes: [`docs/api-notes.md`](docs/api-notes.md).

- Issued in the Toss Securities WTS: **설정 → Open API**. Contrary to the original assumption, issuance is **immediate** — there is no review queue, so M0 is not a scheduling risk.
- Issued credentials: `client_id` (observed prefix `tsck_live_`) and `client_secret` (prefix `tssk_live_`).
- **Allowed-IP registration is mandatory.** 설정 → Open API → 허용 IP 관리. A call from an unregistered IP fails with **403**, no matter how correct the keys are. This is a distinct failure from 401 and the UI must say so.
- Official docs: https://developers.tossinvest.com — machine-readable spec at `https://openapi.tossinvest.com/openapi-docs/latest/openapi.json`.
- No pricing; limits are per-second TPS quotas per client × API group (§3.5).

### 3.2 Authentication

- Base URL: `https://openapi.tossinvest.com`
- `POST /oauth2/token`, `application/x-www-form-urlencoded`, `grant_type=client_credentials` + `client_id` + `client_secret`.
- Response is the **OAuth2 standard shape, not the common `result` envelope**: `{ access_token, token_type: "Bearer", expires_in }`. Measured lifetime is **86400s (24h)**. No refresh token.
- Subsequent calls: `Authorization: Bearer {access_token}`. Account/asset endpoints additionally need `X-Tossinvest-Account: {accountSeq}`; `GET /api/v1/accounts` does **not**.
- **Only one access token is valid per client at a time — issuing a new one immediately revokes the previous one.** The app and the widget are separate processes on the same client, so they must share a single cached token (Keychain, shared access group) and must never refresh independently. Two independent caches would revoke each other on every refresh. Reissue 60s before expiry.

### 3.3 Utilized APIs (All Read-Only)

| Purpose | Endpoint | Fields Used | Trigger |
| --- | --- | --- | --- |
| Account List | `GET /api/v1/accounts` | `accountSeq`, `accountNo`, `accountType` | Onboarding, reselecting accounts |
| Holdings Balance | `GET /api/v1/holdings` (+ `X-Tossinvest-Account`) | `marketValue.amount.krw`, `marketValue.amount.usd` | Every refresh, per selected account |
| Exchange Rate | `GET /api/v1/exchange-rate?baseCurrency=USD&quoteCurrency=KRW` | `rate` | Every refresh, once |
| Buying Power (Optional) | `GET /api/v1/buying-power?currency=…` (+ `X-Tossinvest-Account`) | `cashBuyingPower` | Only when `includeCash` is ON (§12) |

- **Correction to the original draft.** There is no `marketValue.total.krw` field and the API performs **no** currency conversion. `holdings` splits value by trading currency into `marketValue.amount.krw` and `marketValue.amount.usd`. Converting therefore *is* the app's job, using the API's own `exchange-rate` endpoint — the earlier claim that "the app does not calculate exchange rates" was wrong.
- `currentAssets = Σ(marketValue.amount.krw) + Σ(marketValue.amount.usd) × usdKrwRate`, rounded half-up to a whole won. The rate used is stored in the snapshot so the widget can re-render offline.
- The response's `amount` (pre-cost) is used, not `amountAfterCost` — `amount` is what the Toss app shows as 평가금액.
- **Every money value arrives as a decimal string** (`"22417.561095"`), and quantities can be fractional. Parse to `Decimal`; `Double` loses won-level precision on a 9-figure portfolio.
- A currency bucket is `null` when nothing is held in it; that means 0.

### 3.4 Unused APIs

Order creation, modification, and cancellation in the `order` domain, as well as the entirety of the `market` domain (quotes, order books, candles, exchange rates). **Do not implement any order-related methods in the API client code at all.** Eliminates any possibility of accidental execution.

### 3.5 Rate Limits and Error Handling

| Scenario | Handling |
| --- | --- |
| 429 | Wait for `Retry-After` seconds specified in response headers/body and retry, up to 3 attempts. If exceeded, abandon current refresh and retry on next schedule. |
| 401 | Reissue token once and retry. If 401 persists, transition state to "Check API Key". |
| **403** | **IP not on the allowed list. No retry — it will never succeed. Banner directs the user to 설정 > Open API > 허용 IP 관리.** |
| 5xx / Timeout | Abandon current refresh, retain existing snapshot. |
| Other 4xx | Log error `code`, `message`, and `X-Request-Id` locally (viewable under Settings > About > Recent Errors). |

- Error envelope is `{"error": {requestId, code, message, data}}`, where `requestId` mirrors the `X-Request-Id` header. `message` may be empty by policy, so map user-facing text from `code`. The token endpoint is the exception: it returns the OAuth2 shape `{"error", "error_description"}`, and `error_description` names which of `client_id` / `client_secret` failed — worth surfacing, since it points at the exact field to fix.
- Measured per-second quotas, per client × group: `AUTH` 5 · **`ACCOUNT` 1** · `ASSET` 5 · `MARKET_INFO` 3 · `ORDER_INFO` 6. `ACCOUNT` at 1 rps is the binding constraint, so account calls are serialized (this matters in onboarding, where each account gets a balance preview).
- Every response carries `X-RateLimit-Limit` / `-Remaining` / `-Reset`; 429 adds `Retry-After`.
- Request timeouts: App 15s, Widget 10s.
- A refresh with N selected accounts costs N holdings calls + 1 exchange-rate call, so 1-3 requests per hour total. Hitting a limit is highly improbable; exponential backoff with jitter is enforced anyway to prevent retry storms.

---

## 4. Data Flow and Refresh

### 4.1 Architecture & Flow

```
[Triggers]
  App enters foreground / Pull-to-refresh / Widget timeline request / (Optional) BGAppRefresh
        │
        ▼
  RefreshService.refresh()
        │
        ├─ 1. Obtain token (Cache or reissue)
        ├─ 2. Fetch holdings for each selected account (parallel)
        ├─ 3. Sum up → currentAssets
        ├─ 4. Generate Snapshot, persist to App Group storage
        └─ 5. WidgetCenter.reloadAllTimelines()
        │
        ▼
  [Views / Widgets] Render purely from Snapshot + Settings. Never make direct API calls.
```

Both app and widget invoke the **same** `RefreshService` from the **same** `FireCore` module, preventing duplicate logic.

### 4.2 Refresh Policies

| Setting | Widget Timeline Reload Policy | App Foreground Auto-Refresh Condition |
| --- | --- | --- |
| Hourly | `.after(now + 1h)` | Last refresh > 1 hour ago |
| Once Daily | `.after(next 18:00 KST)` | Last refresh > 24 hours ago |

- On widget timeline request, attempt `refresh()`; if it fails, render with the existing cached snapshot.
- **Midnight D-Day Transition**: Pre-populate the timeline with midnight entries for the next 7 days starting from today. Assets stay on the same snapshot value while D-Day decrements by 1 each day. Ensures accurate display even without network connectivity.
- Given iOS widget reload budgets (approx. 40-70 reloads/day), the hourly policy may see individual reloads deferred by the OS. It is understood as an approximate interval rather than a guaranteed schedule.
- `BGAppRefreshTask` serves as an auxiliary mechanism only; do not rely on it since iOS does not guarantee execution schedules.

### 4.3 Storage Models

```swift
// Persisted as JSON in App Group container. Keychain stored separately.
struct Settings: Codable {
    var targetAmount: Int            // KRW
    var targetDate: Date             // Normalized to KST midnight
    var selectedAccountSeqs: [Int]
    var refreshPolicy: RefreshPolicy // .hourly | .daily
    var hideAmountInWidget: Bool
    var includeCash: Bool            // Include uninvested cash / deposits; default: false
}

struct Snapshot: Codable {
    var currentAssets: Int           // KRW, the number the whole app renders
    var perAccount: [Int: Int]       // accountSeq → KRW-converted market value
    var krwAmount: Decimal           // Σ marketValue.amount.krw
    var usdAmount: Decimal           // Σ marketValue.amount.usd
    var usdKrwRate: Decimal          // rate used for the conversion; kept so the widget renders offline
    var cashKRW: Int?                // nil unless Settings.includeCash
    var fetchedAt: Date
    var status: FetchStatus          // .ok | .staleNetwork | .authFailed | .ipBlocked
}

// Keychain (Shared access group, AfterFirstUnlock)
//   toss.clientId, toss.clientSecret, toss.accessToken, toss.tokenExpiresAt
```

---

## 5. Tech Stack

### 5.1 iOS (Proposed — Finalized upon start)

| Domain | Choice | Rationale |
| --- | --- | --- |
| Language / UI | Swift 5.10+, SwiftUI | With widgets being mandatory, native provides the least friction |
| Minimum Target | iOS 17 | SwiftData, modern WidgetKit APIs; personal project with no backward-compatibility baggage |
| Widget | WidgetKit (App Group + Keychain Sharing) | |
| Networking | URLSession + async/await | Zero external dependencies |
| Storage | App Group `UserDefaults` or JSON file (Settings, Snapshot), Keychain (Secrets) | SwiftData is overkill |
| Background | BGAppRefreshTask (Auxiliary) | |
| Third-party | None | Personal project, minimize maintenance overhead |

### 5.2 Android (Post-iOS completion)

| Domain | Choice |
| --- | --- |
| Language / UI | Kotlin, Jetpack Compose |
| Widget | Glance |
| Background | WorkManager (PeriodicWorkRequest, min 15m → 1h / 24h configured) |
| Storage | DataStore (Settings, Snapshot), EncryptedSharedPreferences / Keystore (Secrets) |
| Networking | OkHttp + kotlinx.serialization |

Since calculation logic and API client specs for `FireCore` are language-neutral as documented in §1.1, §3, and §4, **translate directly into Kotlin**. Code sharing (via KMP) is avoided—for an app of this size, direct porting is much cheaper.

### 5.3 Evaluated and Discarded Options

- **Flutter / React Native**: Widgets require native code on both platforms anyway. Developing the two platforms concurrently is not planned, yielding no tangible benefit.
- **Kotlin Multiplatform**: The shared logic amounts to ~300 lines. The toolchain overhead outweighs the gains.
- **Backend Proxy for Key Storage**: Server maintenance cost + transmitting keys off-device poses greater security risks. Keeping keys on-device locally is the correct choice for personal use.

---

## 6. Project Structure

The Xcode target keeps the name it was created with, `firepeople`; the product is "FIRE D-Day".

```
firePeople/
├── README.md                    ← This document
├── readme_ko.md                 ← Korean original, kept in sync
├── .env                         # Local credentials for manual API checks. Git-ignored, never read by the app
├── Packages/
│   └── FireCore/                # Platform-independent logic (Swift Package, no dependencies)
│       ├── Sources/FireCore/
│       │   ├── Models/          # DTOs, Settings, Snapshot, FireState, Decimal decoding
│       │   ├── API/             # TossClient, TossEndpoint, TossAPIError (read-only surface)
│       │   ├── Domain/          # FireCalculator, FireFormatter, Calendar+Seoul
│       │   ├── Storage/         # Settings/Snapshot stores, KeychainStore, AppGroup
│       │   └── RefreshService.swift
│       └── Tests/FireCoreTests/
│           ├── Fixtures/        # Real recorded API responses (only accountNo masked)
│           └── *Tests.swift
├── ios/firepeople/
│   ├── firepeople.xcodeproj
│   ├── firepeople.entitlements      # App Group + Keychain sharing
│   ├── FireWidget.entitlements
│   ├── FireWidget-Info.plist
│   ├── firepeople/              # App target (filesystem-synchronized group)
│   │   ├── firepeopleApp.swift, AppModel.swift, Localizable.swift
│   │   ├── Views/Onboarding/    # Intro, KeyInput, AccountSelect, GoalInput
│   │   ├── Views/MainView.swift, Views/Settings/, Views/Components/
│   │   └── Support/WidgetRefresher.swift
│   └── FireWidget/              # WidgetKit extension target
│       ├── FireWidgetBundle.swift, FireWidget.swift
│       ├── FireTimelineProvider.swift   # Midnight entry generation + refresh attempts
│       └── FireWidgetEntryView.swift, LockScreenWidgetViews.swift
├── android/                     # Post-M5
└── docs/
    └── api-notes.md             # Endpoint/field records verified against the live API
```

`FireCore` is attached to both targets as a local Swift package (`../../Packages/FireCore`). It imports
nothing but `Foundation` — no WidgetKit, no SwiftUI — which is what lets `swift test` run it without Xcode.

---

## 7. Security

- Store `client_id` / `client_secret` / access token **strictly in Keychain**. Use `kSecAttrAccessibleAfterFirstUnlock` (widget needs to refresh even while device is locked) with a shared access group between app and widget.
- **Access-group fallback.** A build that carries no `keychain-access-groups` entitlement — *every* simulator build, since no provisioning profile is applied, and any device build whose App ID lacks the capability — fails every grouped `SecItem*` call with `errSecMissingEntitlement` (−34018). `KeychainStore` retries such calls against the process's own keychain rather than dead-ending onboarding at 연결 테스트 on an opaque OSStatus. This is a **degraded** mode: items outside the group are invisible to the widget, so the widget renders the stored snapshot and never refreshes. `KeychainStore.isSharedAccessGroupAvailable` reports which mode is in effect. On a properly provisioned device the group is used and nothing changes.
- Never write keys to UserDefaults, logs, crash reports, or screenshots. Mask them even in debug logs.
- The API client exposes **only lookup methods in the account domain**. Order-placing code paths do not exist in the codebase.
- Key leakage implies a third party could query or place orders on the account. Guide users in Settings to perform `Settings > Delete API Keys` and revoke the keys on Toss Securities before uninstalling the app.
- Network traffic communicates solely with `https://openapi.tossinvest.com`. No ATS (App Transport Security) exceptions.
- `[TBD]` Face ID lock on app launch — minimal practical benefit since percentage is already visible on the home widget. Default: Not implemented.

---

## 8. Development Environment & Getting Started

### Prerequisites

- macOS + Xcode 16 or later
- iOS 17 or later physical device (widget refresh behavior is unreliable in simulator)
- Toss Securities Open API keys (issued and ready)
- Apple Developer account (requires App Groups, Keychain Sharing capabilities — free personal team account can deploy to device, but requires re-signing every 7 days)

> **One-time signing step before the first device build.** The project declares an App Group and a
> widget extension, and the existing team profile covers neither, so a device build fails with
> *"Provisioning profile … doesn't include the App Groups capability"* and *"No profiles for
> 'com.jay-lab.firepeople.FireWidget' were found"*. Fix it once, either by opening the project in
> Xcode and letting Signing & Capabilities register both (it needs your Apple ID), or with
> `xcodebuild … -allowProvisioningUpdates`. Simulator builds need none of this, but run in the
> degraded Keychain mode described in §7.

### Local Setup & Running

```bash
git clone <repo>
cd firePeople
open ios/firepeople/firepeople.xcodeproj
# 1. App Groups (group.com.jay-lab.firepeople.shared) and Keychain Sharing are already declared
#    in firepeople.entitlements / FireWidget.entitlements — just confirm the signing team resolves
# 2. Select a physical device → Run
# 3. Register your public IP in Toss Securities WTS: 설정 > Open API > 허용 IP 관리
# 4. Enter keys during app onboarding (do not store keys in env vars or plist)
```

### Running Tests

```bash
swift test --package-path Packages/FireCore
```

`FireCore` must run via `swift test` without Xcode. All network requests are mocked using `URLProtocol`.

---

## 9. Test Coverage

| Target | Details |
| --- | --- |
| `FireCalculator` | D-Day boundaries (today, target date, past), progress 0% / 100% / over 100%, zero target amount guard, KST midnight normalization, leap/year boundaries |
| `Formatters` | Entire span of Korean hundred-million/ten-thousand formatting, widget abbreviations, negative number guards |
| `TossClient` | Token issuance, caching, re-issuance 60s before expiry, 401 handling (1 reissue attempt), 429 Retry-After backoff, multi-account aggregation, error handling on missing fields |
| `TimelineProvider` | Generating 7-day midnight entries, fallback when snapshot is absent |
| Manual | Widget refresh on physical device, midnight transition, widget rendering in airplane mode, returning to onboarding after key deletion |

---

## 10. Roadmap

| Milestone | Scope | Definition of Done |
| --- | --- | --- |
| **M0** | Apply for API keys; review official documentation and fill §3 `[TODO]` items | Save actual response JSON under `Fixtures/` |
| **M1** | `FireCore`: Models, calculator, formatters, API client, storage | All `swift test` pass; print real account valuation balance in terminal |
| **M2** | iOS App: Onboarding + Main screen | Enter keys on physical device → D-Day and % displayed |
| **M3** | Widget Small/Medium + Timeline + Refresh policies | D-Day updates past midnight on home screen; % updates after 1 hour |
| **M4** | Settings screen, complete error states, dark mode, polishing | Verify all states in §2.6 table by reproducing them |
| **M5** | Android Port (Compose + Glance) | Identical UI and identical calculation results as iOS |
| Later | Lock Screen widget, projected arrival date calculator, asset history chart | When needed |

Do not write UI code before M1 is completed. The UI is meaningless unless calculations and API integrations are accurate.

---

## 11. Decision Log

| Date | Decision | Rationale |
| --- | --- | --- |
| 2026-09-06 | D-Day is a user-defined fixed date; progress is % based on assets | Fixed target date preserves the feeling of a countdown, similar to military countdown apps |
| 2026-09-06 | Target amount is manual entry only | Calculators like the 4% rule are out of scope |
| 2026-09-06 | Assets = Toss Securities account evaluation amount only | Manually tracked assets create maintenance burden |
| 2026-09-06 | iOS first, Android follows upon completion | Avoid concurrent development |
| 2026-09-06 | Personal use, no server, keys stored in device Keychain | Simplest and safest architecture |
| 2026-09-06 | Refresh intervals: selectable between hourly / once daily, independent of market close | Exact execution time is non-critical |
| 2026-09-06 | No gamification/emotional fluff; adopt only the UX structure | Keeps app focused and minimal |
| 2026-09-06 | Widgets are mandatory | The widget is the core value proposition of military countdown apps |
| 2026-09-06 | Native (SwiftUI → Kotlin), no cross-platform frameworks | See §5.3 |
| 2026-09-06 | KRW conversion is done in-app from `GET /api/v1/exchange-rate` | The API splits holdings by trading currency and converts nothing. §3.3's original `marketValue.total.krw` does not exist |
| 2026-09-06 | Money is `Decimal` end to end, never `Double` | The API sends decimal strings with 6 places; `Double` loses won-level precision on a 9-figure total |
| 2026-09-06 | One access token, cached in the shared Keychain, refreshed under a lock | The server keeps exactly one valid token per client — an app and a widget refreshing independently would revoke each other |
| 2026-09-06 | 403 is a first-class UI state, separate from 401 | The allowed-IP list is mandatory, and "wrong key" advice would send the user down the wrong path |
| 2026-09-06 | Xcode target stays `firepeople`; `FireCore` lives at the repo root | The scaffold already existed under that name; renaming buys nothing, and a root-level package keeps `swift test --package-path Packages/FireCore` working |
| 2026-09-06 | Keychain falls back to the private keychain when the access group is not entitled | Found by running onboarding in the simulator: the API call succeeded and then the key save failed with −34018, dead-ending the flow. Degrading (and reporting it) beats blocking the whole app on a capability the simulator can never have |

---

## 12. TBD Items (With Defaults)

If left undecided, default values are adopted.

| Item | Options | Default |
| --- | --- | --- |
| Include uninvested cash / deposits | Stock market value only / Sum cash deposits | **Stock market value only**. Option provided via `includeCash` toggle in Settings |
| Multiple accounts handling | Aggregate / Single selection | **Aggregate all selected accounts** |
| Lock screen widget | Build / Skip | Build after M3 if time permits |
| Automated projected FIRE date | Calculate using monthly deposit & expected return | **Skip**. Consider later |
| Face ID app lock | Enable / Disable | Disable |
| Project name | `FIRE D-Day` (tentative) | Update here and Xcode target name if changed |
| Android minimum SDK | | Decide at M5 start (based on Glance requirements) |

---

## 13. References

- Toss Securities Open API Official Documentation — https://developers.tossinvest.com
  - Agent index: https://developers.tossinvest.com/llms.txt
  - Overview: https://openapi.tossinvest.com/openapi-docs/overview.md
  - **Canonical spec (source of truth): https://openapi.tossinvest.com/openapi-docs/latest/openapi.json**
- Unofficial Python SDK `tossinvest-core` (for endpoint & field references): https://github.com/gunhoon/tossinvest-core
- Apple WidgetKit — Keeping a widget up to date (reload budget documentation)
- Android Glance — App widget guide
