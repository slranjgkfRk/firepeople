# FIRE D-Day

토스증권 계좌 평가액을 읽어와 **FIRE 목표까지 남은 날짜(D-day)와 진행률(%)** 을 보여주는 개인용 카운트다운 앱. 군대 전역일 카운트 앱의 UX를 그대로 가져온다. 메인 화면 하나, 홈 위젯 하나. 그 이상은 만들지 않는다.

> 이 문서는 개발의 기준점이다. 구현 중 결정이 바뀌면 코드보다 이 문서를 먼저 고친다. `[TODO]` 표시는 착수 전/중에 채워야 하는 항목, `[결정필요]` 는 아직 정하지 않은 항목이다.

---

## 0. 한눈에 보기


| 항목     | 내용                                                 |
| ------ | -------------------------------------------------- |
| 목적     | FIRE 목표일 D-day + 자산 진행률 % 를 한 화면·위젯으로 보여준다         |
| 사용자    | 나 한 명 (배포 목적 없음, 단 "본인 API 키 입력" 흐름은 일반 유저용처럼 만든다) |
| 데이터 소스 | 토스증권 Open API — 계좌 평가금액만                           |
| 플랫폼    | iOS 우선 → 완료 후 Android                              |
| 백엔드    | 없음. 앱이 API를 직접 호출하고 기기 안에서만 저장                     |
| 갱신     | 매시간 또는 하루 1회 (설정에서 선택)                             |
| 주문/매매  | 절대 안 함. 읽기 전용 API만 사용                              |


---

## 1. 제품 정의

### 1.1 핵심 개념과 계산식

사용자가 입력하는 값은 딱 두 개다.


| 이름         | 키              | 설명                               |
| ---------- | -------------- | -------------------------------- |
| FIRE 목표 금액 | `targetAmount` | KRW 정수. 직접 입력 (4% 룰 같은 자동 계산 없음) |
| FIRE 예정일   | `targetDate`   | 날짜. 군대 앱의 "전역일"에 해당              |


API에서 가져오는 값은 하나다.


| 이름    | 키               | 설명                                  |
| ----- | --------------- | ----------------------------------- |
| 현재 자산 | `currentAssets` | 선택한 토스증권 계좌들의 **총 평가금액(KRW 환산)** 합계 |


계산식:

```
dDay        = targetDate - today            # 일 단위, 자정 기준 (KST)
progress    = currentAssets / targetAmount  # 0.0 ~ ∞, 표시 시 100.0% 초과 허용
remaining   = max(targetAmount - currentAssets, 0)

```

- 진행률은 **자산 기준**이다. 군대 앱처럼 "지난 날짜 / 전체 복무일"이 아니다.
- D-day와 진행률은 서로 독립이다. 자산이 늘어도 D-day는 안 움직인다. (예상 도달일 자동 계산은 §12 미결정 사항 참고)
- `today` 는 기기 로컬 날짜가 아니라 **Asia/Seoul 자정** 기준으로 고정한다. 해외에서 열어도 숫자가 안 흔들리게.

### 1.2 하지 않는 것

- 주문, 정정, 취소 등 계좌 상태를 바꾸는 API 호출
- 예금·연금·부동산 등 수동 자산 입력
- 종목별 수익률 화면 (토스증권 앱이 이미 함)
- 계급 시스템, 명언, 공유 이미지 같은 감성 요소
- 서버, 로그인, 계정, 푸시 서버
- 광고, 분석 SDK

---

## 2. 화면과 UX

군대 전역일 앱의 구조를 그대로 따른다: **숫자 하나가 화면을 지배하고, 나머지는 보조.**

### 2.1 온보딩 (첫 실행 1회)

```
[1] 안내        토스증권 Open API 키가 필요하다는 설명 + 발급 위치 (WTS 설정 > Open API, 즉시 발급)
                기기 공인 IP를 설정 > Open API > 허용 IP 관리에 등록해야 한다는 문구 필수
                (등록 안 하면 모든 호출이 403)
[2] 키 입력     client_id / client_secret 입력 → [연결 테스트] 버튼
                성공: 계좌 목록 화면으로 / 실패: 에러 코드 + 메시지 그대로 표시
[3] 계좌 선택   API가 준 계좌 목록 체크박스 (복수 선택 가능, 기본 전체 선택)
                각 계좌 옆에 현재 평가금액 미리보기
[4] 목표 입력   FIRE 목표 금액 (원 단위, 천 단위 콤마 자동)
                FIRE 예정일 (DatePicker, 오늘 이후만)
[5] 완료        메인 화면으로. 동시에 첫 스냅샷 저장 + 위젯 갱신

```

- 온보딩은 뒤로가기 가능, 중간 이탈 시 다음 실행에 이어서 진행 (입력값은 유지, 키는 Keychain에 즉시 저장).
- 키 입력 필드는 secure text. 붙여넣기 허용.

### 2.2 메인 화면

```
┌──────────────────────────────┐
│  FIRE까지                      │
│                              │
│         D-1,234              │  ← 화면의 60% 크기. 이게 앱이다
│                              │
│  2029.12.31 (수)              │
│                              │
│  ████████████░░░░░░░  61.2%  │  ← 진행률 바 + %
│  1억 2,345만원 / 2억원         │
│  남은 금액 7,655만원           │
│                              │
│  마지막 갱신 오늘 14:00        │
│                        ⚙     │
└──────────────────────────────┘

```

- Pull-to-refresh 로 수동 갱신.
- 앱 포그라운드 진입 시 마지막 갱신이 설정 주기보다 오래됐으면 자동 갱신.
- 갱신 중에는 숫자를 지우지 않고 작은 스피너만 보여준다. 이전 값 유지가 원칙.
- 다크 모드 대응 (시스템 따름).

### 2.3 설정 화면


| 항목             | 동작                                       |
| -------------- | ---------------------------------------- |
| 목표 금액 수정       | 즉시 반영, 위젯 갱신                             |
| FIRE 예정일 수정    | 즉시 반영, 위젯 갱신                             |
| 계좌 다시 선택       | 온보딩 [3] 재사용                              |
| 갱신 주기          | `매시간` / `하루 1회` 토글                       |
| API 키 재입력      | 온보딩 [2] 재사용                              |
| API 키 삭제 및 초기화 | 확인 다이얼로그 → Keychain·스냅샷·설정 전부 삭제 → 온보딩으로 |
| 위젯 추가 방법       | 텍스트 안내                                   |
| 정보             | 버전, "읽기 전용 API만 사용합니다" 명시                |


### 2.4 홈 위젯 (필수)


| 크기                | 내용                                              |
| ----------------- | ----------------------------------------------- |
| Small             | `D-1,234` 크게, 아래 `61.2%` 작게                     |
| Medium            | 왼쪽 `D-1,234` + 예정일, 오른쪽 진행률 바 + % + `1.2억 / 2억` |
| Lock Screen (iOS) | `[결정필요]` 원형 게이지에 %, 또는 인라인 텍스트 `D-1,234 · 61%`  |


- 위젯을 탭하면 앱 메인으로.
- 위젯은 **자정 기준으로 D-day 숫자가 자동으로 바뀌어야** 한다. 네트워크가 없어도. (§4.2 참고)
- 위젯에 금액이 노출되는 게 싫을 수 있으니 설정에 `위젯에 금액 숨기기` 토글 하나 둔다 (기본 OFF). 켜면 Medium에서 금액 줄 제거, % 만 남김.

### 2.5 숫자 표기 규칙


| 값          | 표기                                 | 예                              |
| ---------- | ---------------------------------- | ------------------------------ |
| D-day      | `D-` + 천 단위 콤마                     | `D-1,234`, `D-DAY`, `D+12`     |
| 금액 (본문)    | 억/만 단위, 만 미만 버림                    | `1억 2,345만원`, `7,655만원`, `2억원` |
| 금액 (위젯 축약) | 소수점 한 자리 억 단위, 1억 미만은 만 단위         | `1.2억`, `7,655만`               |
| 진행률        | 소수점 한 자리                           | `61.2%`, `100.0%`, `103.7%`    |
| 날짜         | [`yyyy.MM](http://yyyy.MM).dd (E)` | `2029.12.31 (수)`               |
| 갱신 시각      | 오늘이면 `오늘 HH:mm`, 아니면 `M.d HH:mm`   | `오늘 14:00`, `9.5 18:00`        |


### 2.6 상태별 표시


| 상황                 | 표시                                             |
| ------------------ | ---------------------------------------------- |
| 진행률 ≥ 100%         | 진행률 바 가득 + 색 변경, 남은 금액 줄 → `목표 달성`             |
| 목표일 당일             | `D-DAY`                                        |
| 목표일 지남             | `D+n` (앱은 계속 동작, 목표일 수정 유도 배너 1회)              |
| 갱신 실패 (네트워크)       | 마지막 스냅샷 유지 + 상단에 `갱신 실패 · 마지막 갱신 3시간 전`        |
| 401 / 키 폐기         | 마지막 스냅샷 유지 + `API 키를 확인해주세요` 배너 → 탭하면 설정       |
| 403 / IP 미등록       | 마지막 스냅샷 유지 + `토스증권에 이 기기의 IP를 등록해주세요` 배너 → 탭하면 설정. 재시도 안 함 |
| 429                | 사용자에게 안 보여줌. Retry-After 만큼 대기 후 자동 재시도 (§3.5) |
| 스냅샷 없음 (온보딩 직후 실패) | `D-day` 는 표시, 진행률 자리에 `--%` 와 재시도 버튼           |


---

## 3. 토스증권 Open API 연동

### 3.1 발급

> **2026-09-06 실제 API로 검증 완료** (스펙 v1.2.14). 상세 기록: [`docs/api-notes.md`](docs/api-notes.md)

- 토스증권 WTS **설정 → Open API** 에서 발급. 초안의 가정과 달리 **심사 대기 없이 즉시 발급**된다. M0가 일정 리스크가 아니다.
- 발급물: `client_id` (실제 접두사 `tsck_live_`), `client_secret` (접두사 `tssk_live_`)
- **허용 IP 등록이 필수다.** 설정 → Open API → 허용 IP 관리. 등록 안 된 IP에서 호출하면 키가 아무리 맞아도 **403**. 401과 완전히 다른 실패이고 UI도 다르게 안내해야 한다.
- 공식 문서: https://developers.tossinvest.com — 기계 판독용 스펙은 `https://openapi.tossinvest.com/openapi-docs/latest/openapi.json`
- 요금 없음. 한도는 클라이언트 × API 그룹 단위 초당 TPS (§3.5)

### 3.2 인증

- Base URL: [`https://openapi.tossinvest.com`](https://openapi.tossinvest.com)
- `POST /oauth2/token`, `application/x-www-form-urlencoded`, `grant_type=client_credentials` + `client_id` + `client_secret`
- 응답은 공통 `result` envelope 이 아니라 **OAuth2 표준 형식**: `{ access_token, token_type: "Bearer", expires_in }`. 실측 수명 **86400초(24시간)**. refresh token 없음.
- 이후 호출: `Authorization: Bearer {access_token}`. 계좌·자산 엔드포인트는 `X-Tossinvest-Account: {accountSeq}` 도 필요하지만 `GET /api/v1/accounts` 는 **필요 없다**.
- **클라이언트당 유효한 토큰은 1개뿐이고, 새로 발급하면 이전 토큰이 즉시 무효화된다.** 앱과 위젯은 같은 클라이언트를 쓰는 별개 프로세스이므로, 토큰 캐시 하나를 Keychain(공유 access group)으로 공유하고 재발급을 직렬화해야 한다. 각자 캐시를 들면 갱신할 때마다 서로의 토큰을 죽인다. 만료 60초 전에 재발급.

### 3.3 사용하는 API (전부 읽기 전용)


| 용도 | 엔드포인트 | 사용하는 응답 필드 | 호출 시점 |
| --- | --- | --- | --- |
| 계좌 목록 | `GET /api/v1/accounts` | `accountSeq`, `accountNo`, `accountType` | 온보딩, 계좌 재선택 |
| 보유 현황 | `GET /api/v1/holdings` (+ `X-Tossinvest-Account`) | `marketValue.amount.krw`, `marketValue.amount.usd` | 매 갱신, 선택 계좌 수만큼 |
| 환율 | `GET /api/v1/exchange-rate?baseCurrency=USD&quoteCurrency=KRW` | `rate` | 매 갱신, 1회 |
| 매수가능금액 (옵션) | `GET /api/v1/buying-power?currency=…` (+ `X-Tossinvest-Account`) | `cashBuyingPower` | 예수금 포함 옵션 켰을 때만 (§12) |


- **초안 수정.** `marketValue.total.krw` 같은 필드는 존재하지 않고, API는 환산을 **전혀 해주지 않는다.** `holdings` 는 거래 통화별로 `marketValue.amount.krw` 와 `marketValue.amount.usd` 로 쪼개서 준다. 따라서 환산은 앱의 몫이고, API가 주는 `exchange-rate` 엔드포인트를 쓴다. "앱에서 환율 계산 안 한다"는 초안의 문장은 틀렸다.
- `currentAssets = Σ(marketValue.amount.krw) + Σ(marketValue.amount.usd) × usdKrwRate`, 원 단위 반올림. 사용한 환율은 스냅샷에 저장해서 위젯이 오프라인에서도 다시 그릴 수 있게 한다.
- 비용 차감 전 값인 `amount` 를 쓴다 (`amountAfterCost` 아님). 토스 앱이 평가금액으로 보여주는 게 `amount` 다.
- **금액은 전부 소수 문자열로 온다** (`"22417.561095"`), 수량도 소수가 가능하다. `Decimal` 로 파싱한다. 9자리 자산에서 `Double` 은 원 단위 정밀도를 잃는다.
- 보유가 없는 통화는 `null` 로 오고, 이는 0을 뜻한다.

### 3.4 사용하지 않는 API

`order` 도메인의 주문 생성·정정·취소, `market` 도메인 전체(시세, 호가, 캔들, 환율). API 클라이언트 코드에 **주문 관련 메서드를 아예 구현하지 않는다.** 실수로 호출할 경로 자체를 없앤다.

### 3.5 Rate limit과 에러 처리


| 상황         | 처리                                                                                |
| ---------- | --------------------------------------------------------------------------------- |
| 429        | 응답 헤더/본문의 `Retry-After` 초만큼 대기 후 재시도, 최대 3회. 초과 시 이번 갱신 포기, 다음 주기에 재시도            |
| 401        | 토큰 1회 재발급 후 재시도. 또 401이면 "키 확인" 상태로 전환                                            |
| **403**    | **허용 IP 미등록. 재시도 안 한다 — 성공할 수 없다. 배너로 설정 > Open API > 허용 IP 관리 안내**              |
| 5xx / 타임아웃 | 이번 갱신 포기, 스냅샷 유지                                                                  |
| 4xx 기타     | 에러 `code`, `message`, `X-Request-Id` 를 로컬 로그에 남김 (설정 &gt; 정보 &gt; 최근 오류에서 볼 수 있게) |


- 요청 타임아웃: 앱 15초, 위젯 10초
- 시간당 1~3회 호출이 전부라 한도에 걸릴 일은 거의 없다. 다만 재시도 루프가 폭주하지 않도록 백오프는 반드시 둔다.

---

## 4. 데이터 흐름과 갱신

### 4.1 흐름

```
[트리거]
  앱 포그라운드 진입 / Pull-to-refresh / 위젯 타임라인 요청 / (옵션) BGAppRefresh
        │
        ▼
  RefreshService.refresh()
        │
        ├─ 1. 토큰 확보 (캐시 or 재발급)
        ├─ 2. 선택 계좌별 보유 현황 조회 (병렬)
        ├─ 3. 합산 → currentAssets
        ├─ 4. Snapshot 생성, App Group 저장소에 저장
        └─ 5. WidgetCenter.reloadAllTimelines()
        │
        ▼
  [뷰 / 위젯]  Snapshot + Settings 만 읽어서 렌더링. 직접 API 호출 안 함.

```

앱과 위젯은 **같은** `FireCore` **모듈의 같은** `RefreshService` 를 호출한다. 로직이 두 벌 생기지 않게.

### 4.2 갱신 정책


| 설정    | 위젯 타임라인 reload policy  | 앱 포그라운드 자동 갱신 조건 |
| ----- | ---------------------- | ---------------- |
| 매시간   | `.after(now + 1h)`     | 마지막 갱신 &gt; 1시간  |
| 하루 1회 | `.after(다음 18:00 KST)` | 마지막 갱신 &gt; 24시간 |


- 위젯 타임라인 요청 시 `refresh()` 를 시도하고, 실패하면 저장된 스냅샷으로 렌더링한다.
- **D-day 자정 전환**: 타임라인에 오늘부터 7일치 자정 엔트리를 미리 넣는다. 자산은 같은 스냅샷 값, D-day만 하루씩 감소. 네트워크 없이도 숫자가 맞는다.
- iOS 위젯 갱신 예산(일 40~70회)을 고려하면 매시간 정책은 시스템이 일부 건너뛸 수 있다. 정확한 시간을 보장하는 게 아니라 "대략 그 정도"임을 전제한다.
- BGAppRefreshTask는 보조 수단. iOS가 스케줄을 보장하지 않으므로 의존하지 않는다.

### 4.3 저장 모델

```swift
// App Group 컨테이너에 JSON으로 저장. Keychain 은 별도.
struct Settings: Codable {
    var targetAmount: Int            // KRW
    var targetDate: Date             // KST 자정으로 정규화
    var selectedAccountSeqs: [Int]
    var refreshPolicy: RefreshPolicy // .hourly | .daily
    var hideAmountInWidget: Bool
    var includeCash: Bool            // 예수금 포함 여부, 기본 false
}

struct Snapshot: Codable {
    var currentAssets: Int           // KRW
    var perAccount: [Int: Int]       // accountSeq → KRW 환산 평가금액
    var krwAmount: Decimal           // Σ marketValue.amount.krw
    var usdAmount: Decimal           // Σ marketValue.amount.usd
    var usdKrwRate: Decimal          // 환산에 쓴 환율. 위젯 오프라인 렌더링용으로 보관
    var cashKRW: Int?                // Settings.includeCash 일 때만
    var fetchedAt: Date
    var status: FetchStatus          // .ok | .staleNetwork | .authFailed | .ipBlocked
}

// Keychain (access group 공유, AfterFirstUnlock)
//   toss.clientId, toss.clientSecret, toss.accessToken, toss.tokenExpiresAt

```

---

## 5. 기술 스택

### 5.1 iOS (제안 — 착수 시 확정)


| 영역    | 선택                                                                      | 이유                                            |
| ----- | ----------------------------------------------------------------------- | --------------------------------------------- |
| 언어/UI | Swift 5.10+, SwiftUI                                                    | 위젯이 필수라 네이티브가 가장 덜 싸운다                        |
| 최소 버전 | iOS 17                                                                  | SwiftData·최신 WidgetKit API, 개인용이라 하위 호환 부담 없음 |
| 위젯    | WidgetKit (App Group + Keychain Sharing)                                |                                               |
| 네트워크  | URLSession + async/await                                                | 외부 의존성 0                                      |
| 저장    | App Group `UserDefaults` 또는 JSON 파일 (Settings, Snapshot), Keychain (비밀) | SwiftData는 과함                                 |
| 백그라운드 | BGAppRefreshTask (보조)                                                   |                                               |
| 서드파티  | 없음                                                                      | 개인 프로젝트, 유지보수 최소화                             |


### 5.2 Android (iOS 완료 후)


| 영역    | 선택                                                                         |
| ----- | -------------------------------------------------------------------------- |
| 언어/UI | Kotlin, Jetpack Compose                                                    |
| 위젯    | Glance                                                                     |
| 백그라운드 | WorkManager (PeriodicWorkRequest, 최소 15분 → 1시간/24시간 설정)                    |
| 저장    | DataStore (Settings, Snapshot), EncryptedSharedPreferences / Keystore (비밀) |
| 네트워크  | OkHttp + kotlinx.serialization                                             |


`FireCore` 의 계산 로직과 API 클라이언트는 언어 중립적으로 이 문서(§1.1, §3, §4)에 스펙이 있으므로 **Kotlin으로 그대로 번역**한다. 코드 공유(KMP)는 하지 않는다 — 앱 크기가 작아서 번역이 더 싸다.

### 5.3 검토 후 보류

- **Flutter / React Native**: 위젯은 어차피 양쪽 네이티브 코드 필요. 두 플랫폼을 동시에 만드는 것도 아니라 이득이 없음.
- **Kotlin Multiplatform**: 공유할 로직이 300줄 안팎. 툴체인 비용이 더 큼.
- **백엔드 프록시로 키 보관**: 서버 운영 비용 + 키가 기기를 떠나는 게 오히려 더 위험. 개인용이므로 기기 로컬이 정답.

---

## 6. 프로젝트 구조

```
FireDDay/
├── README.md                    ← 이 문서
├── FireDDay.xcodeproj
├── App/                         # iOS 앱 타깃
│   ├── FireDDayApp.swift
│   ├── Views/
│   │   ├── Onboarding/          # Intro, KeyInput, AccountSelect, GoalInput
│   │   ├── MainView.swift
│   │   └── SettingsView.swift
│   ├── ViewModels/
│   └── Resources/               # Assets, Localizable (ko만)
├── Widget/                      # WidgetKit 익스텐션
│   ├── FireWidget.swift         # Small / Medium
│   ├── TimelineProvider.swift   # 자정 엔트리 생성 + refresh 시도
│   └── LockScreenWidget.swift   # [결정필요]
├── Packages/
│   └── FireCore/                # 플랫폼 독립 로직 (Swift Package)
│       ├── Sources/FireCore/
│       │   ├── API/             # TossClient, TokenStore, Endpoints(account만), Models
│       │   ├── Domain/          # FireCalculator, Formatters(억/만, D-day)
│       │   ├── Storage/         # SettingsStore, SnapshotStore, KeychainStore
│       │   └── RefreshService.swift
│       └── Tests/FireCoreTests/
│           ├── Fixtures/        # 실제 API 응답 JSON (민감정보 마스킹)
│           ├── FireCalculatorTests.swift
│           └── TossClientTests.swift
├── android/                     # M5 이후
└── docs/
    └── api-notes.md             # 공식 문서에서 확인한 엔드포인트/필드 기록

```

---

## 7. 보안

- 접근 그룹 폴백: `keychain-access-groups` 엔타이틀먼트가 없는 빌드 — **모든 시뮬레이터 빌드**(프로비저닝 프로파일이 적용되지 않는다)와 App ID에 해당 capability를 켜지 않은 기기 빌드 — 에서는 그룹을 지정한 `SecItem*` 호출이 전부 `errSecMissingEntitlement`(−34018)로 실패한다. `KeychainStore` 는 이때 프로세스 자체 Keychain 으로 재시도한다. 그렇지 않으면 API 호출은 성공했는데 키 저장에서 막혀 온보딩이 정체불명의 OSStatus 로 끝난다. 단 이건 **동등한 동작이 아니라 축소된 동작**이다: 그룹 밖에 저장된 항목은 위젯이 볼 수 없어서 위젯은 저장된 스냅샷만 그리고 갱신은 못 한다. 어느 모드인지는 `KeychainStore.isSharedAccessGroupAvailable` 로 알 수 있다. 정상 프로비저닝된 기기에서는 그룹을 그대로 쓴다.
- `client_id` / `client_secret` / access token 은 **Keychain 에만** 저장. `kSecAttrAccessibleAfterFirstUnlock` (위젯이 잠금 상태에서도 갱신 가능해야 함), 위젯과 공유하는 access group 사용.
- UserDefaults, 로그, 크래시 리포트, 스크린샷 어디에도 키를 남기지 않는다. 디버그 로그에서도 마스킹.
- API 클라이언트는 **account 도메인의 조회 메서드만** 가진다. 주문 경로는 코드에 존재하지 않는다.
- 키 유출 = 제3자가 내 계좌를 조회·주문할 수 있다는 뜻. 앱 삭제 전 `설정 > API 키 삭제`, 그리고 토스증권 쪽에서 키 폐기까지 하도록 설정 화면에 안내.
- 네트워크는 [`https://openapi.tossinvest.com`](https://openapi.tossinvest.com) 하나만. ATS 예외 없음.
- `[결정필요]` 앱 진입 시 Face ID 잠금 — 위젯에 어차피 % 가 보이므로 실익이 적다. 기본 미구현.

---

## 8. 개발 환경과 시작하기

### 요구사항

- macOS + Xcode 16 이상
- iOS 17 이상 실기기 (위젯 갱신 동작은 시뮬레이터에서 신뢰할 수 없음)
- 토스증권 Open API 키 (발급 완료 상태)
- Apple Developer 계정 (App Group, Keychain Sharing capability 필요 — 무료 계정으로도 실기기 설치 가능하나 7일마다 재서명)

> **첫 실기기 빌드 전 1회 서명 작업.** 이 프로젝트는 App Group 과 위젯 익스텐션을 선언하는데 기존 팀 프로파일은 둘 다 포함하지 않는다. 그래서 실기기 빌드가 *"Provisioning profile … doesn't include the App Groups capability"*, *"No profiles for 'com.jay-lab.firepeople.FireWidget' were found"* 로 실패한다. Xcode 에서 프로젝트를 열고 Signing & Capabilities 가 둘 다 등록하게 하거나(Apple ID 로그인 필요), `xcodebuild … -allowProvisioningUpdates` 로 한 번만 해결하면 된다. 시뮬레이터는 이 과정이 필요 없지만 §7 의 축소된 Keychain 모드로 동작한다.

### 로컬 실행

```bash
git clone <repo>
cd FireDDay
open FireDDay.xcodeproj
# 1. Signing & Capabilities: App Groups(group.<bundle>.shared), Keychain Sharing 활성화
# 2. 실기기 선택 → Run
# 3. 앱 온보딩에서 키 입력 (환경변수/plist 에 키를 넣지 않는다)

```

### 테스트 실행

```bash
swift test --package-path Packages/FireCore

```

`FireCore` 는 Xcode 없이 `swift test` 로 돌아가야 한다. 네트워크 호출은 전부 `URLProtocol` 목으로 대체.

---

## 9. 테스트 범위


| 대상                 | 내용                                                                                 |
| ------------------ | ---------------------------------------------------------------------------------- |
| `FireCalculator`   | D-day 경계(오늘·당일·지남), 진행률 0%/100%/초과, 목표 금액 0 방어, KST 자정 정규화, 연도 넘김                  |
| `Formatters`       | 억/만 표기 전 구간, 위젯 축약, 음수 방어                                                          |
| `TossClient`       | 토큰 발급·캐시·만료 60초 전 재발급, 401 → 재발급 1회, 429 → Retry-After 대기, 다중 계좌 합산, 필드 누락 시 실패 처리 |
| `TimelineProvider` | 7일치 자정 엔트리 생성, 스냅샷 없을 때 fallback                                                   |
| 수동                 | 위젯 실기기 갱신, 자정 전환, 기내 모드에서 위젯 표시, 키 삭제 후 온보딩 복귀                                     |


---

## 10. 로드맵


| 마일스톤   | 내용                                       | 완료 기준                                  |
| ------ | ---------------------------------------- | -------------------------------------- |
| **M0** | API 키 발급 신청, 공식 문서 읽고 §3 `[TODO]` 채우기    | 실제 응답 JSON을 `Fixtures/` 에 저장           |
| **M1** | `FireCore`: 모델, 계산기, 포매터, API 클라이언트, 저장소 | `swift test` 전부 통과, 터미널에서 실제 계좌 평가액 출력 |
| **M2** | iOS 앱: 온보딩 + 메인 화면                       | 실기기에서 키 입력 → D-day와 % 표시               |
| **M3** | 위젯 Small/Medium + 타임라인 + 갱신 정책           | 홈 화면에서 자정 넘기면 D-day 바뀜, 1시간 후 % 갱신됨    |
| **M4** | 설정 화면, 에러 상태 전부, 다크 모드, 폴리싱              | §2.6 표의 모든 상태를 실제로 재현해서 확인             |
| **M5** | Android 포팅 (Compose + Glance)            | iOS와 동일 화면·동일 계산 결과                    |
| 이후     | 잠금화면 위젯, 예상 도달일 계산, 자산 히스토리 그래프          | 필요할 때                                  |


M1이 끝나기 전에는 UI 코드를 쓰지 않는다. 계산과 API가 맞아야 화면이 의미가 있다.

---

## 11. 결정 기록


| 날짜         | 결정                                        | 이유                           |
| ---------- | ----------------------------------------- | ---------------------------- |
| 2026-09-06 | D-day는 사용자가 정한 고정 날짜, 진행률은 자산 기준 %        | 군대 앱처럼 날짜가 고정돼야 카운트다운의 맛이 산다 |
| 2026-09-06 | 목표 금액은 직접 입력만                             | 4% 룰 등 계산기는 범위 밖             |
| 2026-09-06 | 자산 = 토스증권 계좌 평가액만                         | 수동 입력 자산은 관리 부담              |
| 2026-09-06 | iOS 먼저, 끝나면 Android                       | 동시 개발 안 함                    |
| 2026-09-06 | 개인용, 서버 없음, 키는 기기 Keychain                |                              |
| 2026-09-06 | 갱신 주기 매시간/하루 1회 선택식, 장 마감 시각과 무관          | 정확한 시각은 중요하지 않음              |
| 2026-09-06 | 감성 요소 없음, UX 구조만 차용                       |                              |
| 2026-09-06 | 위젯 필수                                     | 군대 앱의 핵심이 위젯                 |
| 2026-09-06 | 네이티브 (SwiftUI → Kotlin), 크로스플랫폼 프레임워크 안 씀 | §5.3                         |
| 2026-09-06 | KRW 환산은 `GET /api/v1/exchange-rate` 로 앱에서 직접 | API가 통화별로 쪼개서 주고 환산은 안 해준다. §3.3의 `marketValue.total.krw` 는 없는 필드 |
| 2026-09-06 | 금액은 끝까지 `Decimal`, `Double` 금지 | API가 소수점 6자리 문자열로 준다. 9자리 자산에서 `Double` 은 원 단위가 깨진다 |
| 2026-09-06 | 토큰 1개를 공유 Keychain에 캐시하고 재발급은 락으로 직렬화 | 서버가 클라이언트당 토큰 1개만 유지한다. 앱과 위젯이 따로 갱신하면 서로 무효화한다 |
| 2026-09-06 | 403은 401과 별개의 UI 상태 | 허용 IP 등록이 필수라서, "키 확인" 안내를 하면 엉뚱한 곳을 보게 된다 |
| 2026-09-06 | Xcode 타깃명은 `firepeople` 유지, `FireCore` 는 저장소 루트 | 스캐폴드가 이미 그 이름이고, 루트에 두면 `swift test --package-path Packages/FireCore` 가 그대로 동작한다 |
| 2026-09-06 | 접근 그룹 엔타이틀먼트가 없으면 Keychain 을 프로세스 자체 저장소로 폴백 | 시뮬레이터에서 온보딩을 직접 돌려보다 발견. API 호출은 성공했는데 키 저장이 −34018 로 실패하며 흐름이 막혔다. 시뮬레이터가 절대 가질 수 없는 capability 때문에 앱 전체를 막느니, 축소 동작으로 내려가고 그 사실을 알리는 편이 낫다 |


---

## 12. 미결정 사항 (기본값 포함)

결정 안 하면 기본값으로 간다.


| 항목            | 선택지                 | 기본값                                      |
| ------------- | ------------------- | ---------------------------------------- |
| 예수금(현금) 포함 여부 | 주식 평가액만 / 예수금 합산    | **주식 평가액만**. 설정에 `includeCash` 토글로 옵션 제공 |
| 여러 계좌 처리      | 합산 / 하나만 선택         | **선택한 계좌 전부 합산**                         |
| 잠금화면 위젯       | 만든다 / 안 만든다         | M3 이후 여유 있으면                             |
| 예상 도달일 자동 계산  | 월 납입액·기대수익률 입력받아 계산 | **안 함**. 이후 고려                           |
| Face ID 앱 잠금  |                     | 안 함                                      |
| 프로젝트 이름       | `FIRE D-Day` (가칭)   | 바꾸려면 여기와 Xcode 타깃명 같이 수정                 |
| Android 최소 버전 |                     | M5 착수 시 결정 (Glance 요구사항 기준)              |


---

## 13. 참고

- 토스증권 Open API 공식 문서 — https://developers.tossinvest.com
  - 에이전트용 색인: https://developers.tossinvest.com/llms.txt
  - 개요: https://openapi.tossinvest.com/openapi-docs/overview.md
  - **정본 스펙: https://openapi.tossinvest.com/openapi-docs/latest/openapi.json**
- 비공식 Python SDK `tossinvest-core` (엔드포인트·필드명 참고용): [https://github.com/gunhoon/tossinvest-core](https://github.com/gunhoon/tossinvest-core)
- Apple WidgetKit — Keeping a widget up to date (갱신 예산 설명)
- Android Glance — App widget 가이드

