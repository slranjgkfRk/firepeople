# Toss Securities Open API — verified notes

Source of truth: `https://openapi.tossinvest.com/openapi-docs/latest/openapi.json` (**spec v1.2.14**).
Human overview: `https://openapi.tossinvest.com/openapi-docs/overview.md`.
Agent index: `https://developers.tossinvest.com/llms.txt`.

Everything below was verified against the **live** API on 2026-09-06 with the project's own
credentials. Only read-only (`GET`) endpoints plus `POST /oauth2/token` were called.

## Base

| | |
| --- | --- |
| REST | `https://openapi.tossinvest.com` |
| WebSocket | `wss://openapi-ws.tossinvest.com/ws/v1` (unused) |

## Credentials

Issued in Toss Securities **WTS → 설정 → Open API**. Two values, distinguishable by prefix:

| Value | Prefix seen | Length |
| --- | --- | --- |
| `client_id` | `tsck_live_` | 32 |
| `client_secret` | `tssk_live_` | 53 |

The spec's *examples* show `c_…` / `s_…`; the real issued values use the `tsck_`/`tssk_` prefixes.
Do not validate key format in the app beyond "non-empty" — prefixes are not contractual.

**Allowed-IP list.** WTS → 설정 → Open API → 허용 IP 관리. Calls from an unregistered IP are
rejected with **403**, not 401. Distinguish these in the UI: 403 = register your IP, 401 = wrong key.

## Auth — `POST /oauth2/token`

Rate-limit group `AUTH` (5 rps). `Content-Type: application/x-www-form-urlencoded`,
body `grant_type=client_credentials&client_id=…&client_secret=…`.

Success (**OAuth2 shape, not the common envelope**):

```json
{ "access_token": "<JWT>", "token_type": "Bearer", "expires_in": 86399 }
```

- Measured lifetime **86400s (24h)**, not the 3600s quoted by third-party blog posts.
- No refresh token. Re-POST the same endpoint to renew.
- **Only one valid access token exists per client. Re-issuing immediately invalidates the previous
  one.** This is the single most important operational fact for this app: the app and the widget are
  separate processes sharing one client, so they *must* share one cached token through the shared
  Keychain, and must not refresh concurrently. Independent refreshing would make the two processes
  perpetually revoke each other.

Failure uses the OAuth2 error shape — identify by `error`, not `code`:

```json
{ "error": "invalid_client", "error_description": "Client authentication failed: client_secret" }
```

`error_description` names the field that failed (`client_id` vs `client_secret`), which is what
distinguishes "wrong id" from "wrong secret". `401` also returns `WWW-Authenticate: Basic realm="openapi"`.

## Calling other endpoints

`Authorization: Bearer {access_token}` on every request. Account/asset/order endpoints additionally
require `X-Tossinvest-Account: {accountSeq}`. `GET /api/v1/accounts` does **not** take that header.

Common success envelope: `{"result": …}`. Common error envelope (4xx/5xx):

```json
{ "error": { "requestId": "…", "code": "invalid-token", "message": "유효하지 않은 토큰입니다." } }
```

`requestId` equals the `X-Request-Id` response header. `code` is a flat string; treat unknown codes
as generic. `message` may be empty by policy — map from `code`, don't display `message` blindly.

## Endpoints this app uses (all read-only)

### `GET /api/v1/accounts` — group `ACCOUNT`, **1 rps**

Returns only `BROKERAGE` accounts today; `[]` if none. `accountSeq` feeds `X-Tossinvest-Account`.

```json
{ "result": [ { "accountNo": "1300*******", "accountSeq": 1, "accountType": "BROKERAGE" } ] }
```

`accountType` enum: `BROKERAGE | OVERSEAS_DERIVATIVES | PENSION_SAVINGS | RESHORING_INVESTMENT`.
Decode unknown values without failing.

### `GET /api/v1/holdings` — group `ASSET`, 5 rps

Requires `X-Tossinvest-Account`. Optional `?symbol=`. KR + US equities only.

> **This is where the README was wrong.** README §3.3 specified `marketValue.total.krw` and stated
> "the app does not calculate exchange rates". No such field exists. The real response splits value
> by **trading currency** and performs **no** KRW conversion:

```json
{ "result": {
    "totalPurchaseAmount": { "krw": "38115", "usd": "20821.471188" },
    "marketValue": {
      "amount":          { "krw": "38585", "usd": "22417.561095" },
      "amountAfterCost": { "krw": "38580", "usd": "22375.101095" } },
    "profitLoss": { "amount": {…}, "amountAfterCost": {…}, "rate": "-0.0192", "rateAfterCost": "-0.0211" },
    "dailyProfitLoss": { "amount": {…}, "rate": "…" },
    "items": [ { "symbol": "005930", "name": "…", "marketCountry": "KR", "currency": "KRW",
                 "quantity": "100", "lastPrice": "72000", "averagePurchasePrice": "65000",
                 "marketValue": { "purchaseAmount": "…", "amount": "…", "amountAfterCost": "…" },
                 "profitLoss": {…}, "dailyProfitLoss": {…}, "cost": { "commission": "…", "tax": "…" } } ] } }
```

Consequences for `FireCore`:

- **Every money field is a decimal *string*.** Parse to `Decimal`, never `Double` — `quantity` can be
  fractional (`86.107735` observed) and USD sums carry 6 decimal places.
- A currency bucket is `null` when nothing is held in it. `null` ≠ `0` on input; both mean 0 in the sum.
- `currentAssets` therefore needs the FX endpoint:
  `currentAssets = marketValue.amount.krw + marketValue.amount.usd × usdKrwRate`
- `amount` vs `amountAfterCost`: the app uses **`amount`** (pre-cost market value), matching what the
  Toss app shows as 평가금액.
- Top-level `profitLoss.rate` is a KRW-converted whole-portfolio rate and can have the opposite sign
  of the per-currency amounts (observed: amounts positive, `rate` −0.0192). The app does not use it.

### `GET /api/v1/exchange-rate` — group `MARKET_INFO`, 3 rps

Required query params `baseCurrency` + `quoteCurrency` (`KRW` | `USD`). No account header.

```json
{ "result": { "baseCurrency": "USD", "quoteCurrency": "KRW", "rate": "1353.1", "midRate": "1352.6",
              "basisPoint": "4", "rateChangeType": "EQUAL",
              "validFrom": "2026-09-06T17:51:58.000+09:00", "validUntil": "2026-09-06T17:56:56.000+09:00" } }
```

Refreshed every minute; reference rate, not the dealing rate. Use `rate`. Cache it with the snapshot
so the widget can re-render offline.

### `GET /api/v1/buying-power` — group `ORDER_INFO`, 6 rps (3 rps 09:00–09:10 KST)

Requires `X-Tossinvest-Account` and `currency`. Only called when `includeCash` is on.

```json
{ "result": { "currency": "KRW", "cashBuyingPower": "50" } }
```

Cash-inclusive total adds `cashBuyingPower(KRW) + cashBuyingPower(USD) × usdKrwRate`.

### Endpoints deliberately absent from the client

`POST /api/v1/orders`, `/orders/{id}/modify`, `/orders/{id}/cancel`, all `/conditional-orders`,
`/sellable-quantity`, `/commissions`, and the whole market-data group. Per README §3.4 there is no
code path that can place an order.

## Rate limits & retries

Every response (200 and 429) carries `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`.
429 adds `Retry-After` (seconds) and `error.data.retryAfterSeconds`. Groups used by this app:
`AUTH` 5 rps · `ACCOUNT` **1 rps** · `ASSET` 5 rps · `MARKET_INFO` 3 rps · `ORDER_INFO` 6 rps.

`ACCOUNT` at 1 rps is the binding constraint at onboarding — serialize account calls.
Per-refresh cost with N selected accounts: 1 × holdings per account (`ASSET`) + 1 × FX, so N+1
requests, well inside every limit.

## Live verification, 2026-09-06 17:51 KST

| | |
| --- | --- |
| Accounts | 1 × `BROKERAGE`, `accountSeq = 1` |
| `marketValue.amount.krw` | `38585` |
| `marketValue.amount.usd` | `22417.561095` |
| USD→KRW `rate` | `1353.1` |
| **`currentAssets`** | `38585 + 22417.561095 × 1353.1` = **`30371787` KRW** |

Recorded responses live in `Packages/FireCore/Tests/FireCoreTests/Fixtures/` and drive the
`URLProtocol` tests. Only `accountNo` is masked; every amount is the real response.
