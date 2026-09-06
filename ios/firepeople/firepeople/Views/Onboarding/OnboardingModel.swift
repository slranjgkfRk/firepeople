//
//  OnboardingModel.swift
//  firepeople
//
//  README §2.1 온보딩 5단계의 상태와 부수효과를 전부 담당한다.
//
//  원칙
//  - client_id / client_secret 은 연결 테스트가 성공한 즉시 Keychain 에 저장한다 (README §2.1, §7).
//  - 비밀값은 절대 UserDefaults·로그·에러 메시지에 남기지 않는다. 진행 상태(단계/금액/날짜/선택계좌)만 저장한다.
//  - 중간 이탈 후 다시 실행하면 같은 단계에서 입력값을 그대로 들고 이어서 진행한다.
//  - 금액은 전부 Decimal / Int. Double 로 환산하지 않는다.
//

import Foundation
import Observation
import FireCore
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Step

enum OnboardingStep: Int, Codable, CaseIterable, Comparable, Sendable {
    case intro = 0
    case keyInput
    case accountSelect
    case goalInput
    case done

    static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 1…5 — 헤더의 "n / 5" 표기에 쓴다.
    var displayIndex: Int { rawValue + 1 }
    static var stepCount: Int { allCases.count }
}

// MARK: - Credential field

/// 어느 입력란이 틀렸는지 가리키기 위한 값. `TossAPIError.invalidCredentials(field:)` 에서 온다.
enum CredentialField: String, Hashable, Sendable {
    case clientId
    case clientSecret

    var apiName: String {
        switch self {
        case .clientId: "client_id"
        case .clientSecret: "client_secret"
        }
    }

    init?(apiName: String) {
        switch apiName {
        case "client_id": self = .clientId
        case "client_secret": self = .clientSecret
        default: return nil
        }
    }
}

// MARK: - Failure

/// 화면에 그대로 보여줄 실패 정보. README §2.1 "에러 코드 + 메시지 그대로 표시".
/// `message` 는 사람이 읽는 한 줄, `detail` 은 코드/requestId 같은 원문이다. 비밀값은 절대 담기지 않는다.
struct OnboardingFailure: Equatable, Sendable {
    var message: String
    var detail: String?
    var field: CredentialField?
    var needsIPRegistration: Bool

    init(message: String, detail: String? = nil, field: CredentialField? = nil, needsIPRegistration: Bool = false) {
        self.message = message
        self.detail = detail
        self.field = field
        self.needsIPRegistration = needsIPRegistration
    }

    init(_ error: Error) {
        if let apiError = error as? TossAPIError {
            self.init(message: apiError.userMessageKo,
                      detail: OnboardingFailure.detailText(for: apiError),
                      field: OnboardingFailure.credentialField(for: apiError),
                      needsIPRegistration: apiError == .ipNotAllowed)
        } else if let keychainError = error as? KeychainError {
            self.init(message: "기기 보안 저장소에 키를 저장하지 못했어요.",
                      detail: OnboardingFailure.detailText(for: keychainError))
        } else if error is CancellationError {
            self.init(message: "요청이 취소됐어요. 다시 시도해주세요.")
        } else {
            self.init(message: "알 수 없는 오류가 발생했어요.", detail: (error as NSError).localizedDescription)
        }
    }

    private static func detailText(for error: TossAPIError) -> String? {
        var parts: [String] = []
        switch error {
        case .invalidCredentials(let field):
            parts.append("invalid_client")
            if let field, !field.isEmpty { parts.append(field) }
        case .ipNotAllowed:
            parts.append("403")
            parts.append("ip-not-allowed")
        case .unauthorized(let code, let requestId):
            parts.append("401")
            if !code.isEmpty { parts.append(code) }
            if let requestId, !requestId.isEmpty { parts.append("requestId \(requestId)") }
        case .rateLimited(let retryAfter):
            parts.append("429")
            parts.append("retry-after \(Int(retryAfter.rounded()))s")
        case .server(let status, let code, let message, let requestId):
            parts.append("\(status)")
            if let code, !code.isEmpty { parts.append(code) }
            if let message, !message.isEmpty { parts.append(message) }
            if let requestId, !requestId.isEmpty { parts.append("requestId \(requestId)") }
        case .transport(let message):
            if !message.isEmpty { parts.append(message) }
        case .decoding(let message):
            parts.append("decoding")
            if !message.isEmpty { parts.append(message) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func detailText(for error: KeychainError) -> String? {
        switch error {
        case .status(let status): return "Keychain OSStatus \(status)"
        case .encoding: return "Keychain encoding"
        }
    }

    private static func credentialField(for error: TossAPIError) -> CredentialField? {
        guard case .invalidCredentials(let name) = error, let name else { return nil }
        return CredentialField(apiName: name)
    }
}

// MARK: - Account preview

/// 계좌 한 줄의 평가금액 미리보기 상태. 값은 전부 API 응답에서만 나온다.
enum AccountPreviewState: Equatable, Sendable {
    case loading
    case loaded(krwTotal: Int, itemCount: Int)
    case failed(String)
}

// MARK: - Partial progress persistence

/// 중간 이탈 대비 저장물. 비밀값은 들어가지 않는다 — 키는 Keychain 에만 있다.
struct OnboardingProgress: Codable, Equatable, Sendable {
    var step: Int
    var targetAmount: Int
    var targetDate: Date
    var selectedAccountSeqs: [Int]
}

protocol OnboardingProgressStoring {
    func load() -> OnboardingProgress?
    func save(_ progress: OnboardingProgress)
    func clear()
}

struct UserDefaultsOnboardingProgressStore: OnboardingProgressStoring {
    static let key = "onboarding.progress.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> OnboardingProgress? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(OnboardingProgress.self, from: data)
    }

    func save(_ progress: OnboardingProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

final class InMemoryOnboardingProgressStore: OnboardingProgressStoring {
    private var stored: OnboardingProgress?
    init(_ initial: OnboardingProgress? = nil) { stored = initial }
    func load() -> OnboardingProgress? { stored }
    func save(_ progress: OnboardingProgress) { stored = progress }
    func clear() { stored = nil }
}

// MARK: - Credentials + client seams

/// Keychain 을 그대로 쓰되, 프리뷰에서는 갈아끼울 수 있도록 최소한의 구멍만 낸다.
protocol OnboardingCredentialStore {
    func credentials() throws -> TokenCredentials?
    func saveCredentials(_ credentials: TokenCredentials) throws
}

extension KeychainStore: OnboardingCredentialStore {}

/// 온보딩이 쓰는 API 표면. 주문 계열은 애초에 존재하지 않는다 (README §3.4).
protocol OnboardingClient: TossReadOnlyAPI {
    func verifyConnection() async throws -> [TossAccount]
    func invalidateToken() async
}

extension TossClient: OnboardingClient {}

/// 아직 Keychain 에 넣기 전인, 방금 입력받은 키로 한 번 호출해보기 위한 provider.
struct StaticCredentialProvider: CredentialProviding, Sendable {
    let value: TokenCredentials
    init(_ value: TokenCredentials) { self.value = value }
    func credentials() throws -> TokenCredentials? { value }
}

// MARK: - Defaults (file scope so they can be default arguments of an internal init)

let onboardingDefaultClientFactory: @Sendable (TokenCredentials?) -> any OnboardingClient = { credentials in
    let keychain = KeychainStore()
    if let credentials {
        // 입력 중인 키를 검증하는 경로. 토큰은 앱/위젯이 공유하는 Keychain 캐시에 그대로 들어간다.
        return TossClient(credentials: StaticCredentialProvider(credentials), tokenCache: keychain)
    }
    return TossClient(credentials: keychain, tokenCache: keychain)
}

func onboardingDefaultSettingsStore() -> any SettingsStoring {
    UserDefaultsSettingsStore(defaults: AppGroup.defaults ?? .standard)
}

func onboardingDefaultSnapshotStore() -> any SnapshotStoring {
    UserDefaultsSnapshotStore(defaults: AppGroup.defaults ?? .standard)
}

func onboardingDefaultProgressStore() -> any OnboardingProgressStoring {
    UserDefaultsOnboardingProgressStore(defaults: AppGroup.defaults ?? .standard)
}

extension Notification.Name {
    /// 온보딩이 끝나 Settings.onboardingCompleted 가 true 로 저장된 직후 던진다.
    /// 앱 셸이 클로저 대신 이걸 구독해도 메인 화면으로 전환할 수 있다.
    static let fireOnboardingCompleted = Notification.Name("com.jay-lab.firepeople.onboardingCompleted")
}

// MARK: - Model

@MainActor
@Observable
final class OnboardingModel {

    // Dependencies
    private let credentialStore: any OnboardingCredentialStore
    private let settingsStore: any SettingsStoring
    private let snapshotStore: any SnapshotStoring
    private let progressStore: any OnboardingProgressStoring
    private let makeClient: @Sendable (TokenCredentials?) -> any OnboardingClient
    private let onCompleted: (@MainActor () -> Void)?

    // Navigation
    private(set) var step: OnboardingStep = .intro
    @ObservationIgnored private var hasStarted = false
    /// 설정 화면이 [2]/[3] 단계만 떼어 쓰는 중인지 (README §2.3 "온보딩 [2]/[3] 재사용").
    @ObservationIgnored private(set) var isSettingsReuse = false

    // [2] 키 입력
    var clientId: String = ""
    var clientSecret: String = ""
    private(set) var isTestingConnection = false
    private(set) var keyFailure: OnboardingFailure?
    private(set) var hasStoredCredentials = false

    // [3] 계좌 선택
    private(set) var accounts: [TossAccount] = []
    private(set) var selectedAccountSeqs: Set<Int> = []
    private(set) var accountPreviews: [Int: AccountPreviewState] = [:]
    private(set) var isLoadingAccounts = false
    private(set) var accountsFailure: OnboardingFailure?
    /// 미리보기 환산에 쓴 환율. API 가 준 값 그대로다.
    private(set) var usdKrwRate: Decimal?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var accountLoadGeneration = 0
    @ObservationIgnored private var didLoadAccounts = false

    // [4] 목표 입력
    private(set) var targetAmountText: String = ""
    private(set) var targetAmount: Int = 0
    private(set) var targetDate: Date = Settings.fresh.targetDate

    // [5] 완료
    private(set) var isFinishing = false
    private(set) var finishFailure: OnboardingFailure?
    private(set) var didComplete = false
    @ObservationIgnored private var finishTask: Task<Void, Never>?

    init(credentialStore: any OnboardingCredentialStore = KeychainStore(),
         settingsStore: any SettingsStoring = onboardingDefaultSettingsStore(),
         snapshotStore: any SnapshotStoring = onboardingDefaultSnapshotStore(),
         progressStore: any OnboardingProgressStoring = onboardingDefaultProgressStore(),
         makeClient: @escaping @Sendable (TokenCredentials?) -> any OnboardingClient = onboardingDefaultClientFactory,
         onCompleted: (@MainActor () -> Void)? = nil) {
        self.credentialStore = credentialStore
        self.settingsStore = settingsStore
        self.snapshotStore = snapshotStore
        self.progressStore = progressStore
        self.makeClient = makeClient
        self.onCompleted = onCompleted
    }

    // MARK: - Lifecycle

    /// 첫 표시에 한 번. 이전에 이탈한 지점과 입력값을 복원한다.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        hasStoredCredentials = ((try? credentialStore.credentials()) ?? nil) != nil

        // 아직 완료되지 않은 설정이 남아 있으면 값의 출발점으로 쓴다.
        if let settings = settingsStore.load(), !settings.onboardingCompleted {
            applyAmount(settings.targetAmount)
            targetDate = settings.targetDate
            selectedAccountSeqs = Set(settings.selectedAccountSeqs)
        }

        if let progress = progressStore.load() {
            applyAmount(progress.targetAmount)
            targetDate = progress.targetDate
            if !progress.selectedAccountSeqs.isEmpty {
                selectedAccountSeqs = Set(progress.selectedAccountSeqs)
            }
            step = restoredStep(from: progress)
        } else if hasStoredCredentials {
            // 키는 저장돼 있는데 진행 기록이 없다 — 키 입력까지는 끝난 상태다.
            step = .accountSelect
        }

        if targetDate < minimumTargetDate {
            targetDate = minimumTargetDate
        }
    }

    /// 설정 화면에서 [2] 키 입력 / [3] 계좌 선택을 단독으로 띄울 때의 진입점 (README §2.3).
    ///
    /// `start()` 와 달리 저장된 온보딩 진행 기록을 복원하지도, 새로 쓰지도 않는다. 이미 온보딩을
    /// 마친 사용자를 다시 흐름에 태우는 게 아니라 한 단계만 빌려 쓰는 것이기 때문이다.
    /// `preselecting` 은 현재 설정의 계좌 선택으로, 목록을 받아온 뒤에도 그대로 유지된다
    /// (`apply(accounts:)` 가 비어 있을 때만 전체 선택으로 되돌린다).
    func prepareForSettingsReuse(preselecting selected: [Int] = []) {
        guard !hasStarted else { return }
        hasStarted = true
        isSettingsReuse = true
        hasStoredCredentials = ((try? credentialStore.credentials()) ?? nil) != nil
        selectedAccountSeqs = Set(selected)
    }

    private func restoredStep(from progress: OnboardingProgress) -> OnboardingStep {
        var restored = OnboardingStep(rawValue: progress.step) ?? .intro
        // 완료 단계는 네트워크·저장을 실행하는 단계라 자동 재실행하지 않고 직전 단계에서 다시 확인받는다.
        if restored == .done { restored = .goalInput }
        // 키가 없으면 계좌 조회 자체가 불가능하다.
        if restored > .keyInput, !hasStoredCredentials { restored = .keyInput }
        return restored
    }

    // MARK: - Navigation

    var canGoBack: Bool { step != .intro && !isFinishing && !didComplete }

    func goBack() {
        guard canGoBack, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }

    func continueFromIntro() { go(to: .keyInput) }

    func continueFromAccounts() {
        guard !selectedAccountSeqs.isEmpty else { return }
        go(to: .goalInput)
    }

    func continueFromGoal() {
        guard canFinishGoal else { return }
        go(to: .done)
    }

    private func go(to newStep: OnboardingStep) {
        step = newStep
        persistProgress()
    }

    // MARK: - [2] 연결 테스트

    var canTestConnection: Bool {
        !isTestingConnection
            && !OnboardingModel.trim(clientId).isEmpty
            && !OnboardingModel.trim(clientSecret).isEmpty
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testConnection() async {
        let id = OnboardingModel.trim(clientId)
        let secret = OnboardingModel.trim(clientSecret)

        guard !id.isEmpty else {
            keyFailure = OnboardingFailure(message: "client_id 를 입력해주세요.", field: .clientId)
            return
        }
        guard !secret.isEmpty else {
            keyFailure = OnboardingFailure(message: "client_secret 를 입력해주세요.", field: .clientSecret)
            return
        }
        guard !isTestingConnection else { return }

        isTestingConnection = true
        keyFailure = nil
        defer { isTestingConnection = false }

        let credentials = TokenCredentials(clientId: id, clientSecret: secret)
        let client = makeClient(credentials)
        // 이전에 다른 키로 받아둔 토큰이 캐시에 남아 있으면 방금 입력한 키를 검증하지 못한다.
        await client.invalidateToken()

        do {
            let fetched = try await client.verifyConnection()
            // 성공 시점에 바로 Keychain 으로 (README §2.1 "키는 Keychain 에 즉시 저장").
            try credentialStore.saveCredentials(credentials)
            hasStoredCredentials = true
            apply(accounts: fetched)
            go(to: .accountSelect)
        } catch {
            keyFailure = OnboardingFailure(error)
        }
    }

    // MARK: - [3] 계좌 선택

    /// 계좌 화면이 나타날 때마다 호출해도 안전하다. 이미 목록이 있으면 미리보기만 채운다.
    func prepareAccountStep() {
        guard accountTask == nil else { return }
        let needsAccounts = !didLoadAccounts && accountsFailure == nil
        let needsPreviews = !accounts.isEmpty
            && (accountPreviews.count != accounts.count || accountPreviews.values.contains(.loading))
        guard needsAccounts || needsPreviews else { return }
        startAccountTask(loadingList: needsAccounts)
    }

    /// 계좌 목록부터 다시 (실패 후 재시도 버튼).
    func reloadAccounts() {
        accountsFailure = nil
        startAccountTask(loadingList: true)
    }

    /// 목록은 그대로 두고 평가금액 미리보기만 다시.
    func reloadPreviews() {
        guard !accounts.isEmpty else { return }
        startAccountTask(loadingList: false, resetPreviews: true)
    }

    var hasFailedPreview: Bool {
        accountPreviews.values.contains { if case .failed = $0 { return true } else { return false } }
    }

    private func startAccountTask(loadingList: Bool, resetPreviews: Bool = false) {
        accountTask?.cancel()
        accountLoadGeneration += 1
        let generation = accountLoadGeneration
        accountTask = Task { [self] in
            if loadingList {
                await loadAccounts()
            } else {
                await loadPreviews(resetting: resetPreviews)
            }
            // 그 사이에 다른 작업이 시작됐다면 그쪽 핸들을 지우면 안 된다.
            if generation == accountLoadGeneration { accountTask = nil }
        }
    }

    func toggleAccount(_ accountSeq: Int) {
        if selectedAccountSeqs.contains(accountSeq) {
            selectedAccountSeqs.remove(accountSeq)
        } else {
            selectedAccountSeqs.insert(accountSeq)
        }
        persistProgress()
    }

    func isSelected(_ accountSeq: Int) -> Bool { selectedAccountSeqs.contains(accountSeq) }

    /// 선택한 계좌들의 미리보기 합계. 전부 불러온 경우에만 값이 나온다 (부분 합계는 틀린 숫자다).
    var selectedPreviewTotal: Int? {
        guard !selectedAccountSeqs.isEmpty else { return nil }
        var total = 0
        for seq in selectedAccountSeqs {
            guard case .some(.loaded(let krwTotal, _)) = accountPreviews[seq] else { return nil }
            total += krwTotal
        }
        return total
    }

    private func loadAccounts() async {
        isLoadingAccounts = true
        accountsFailure = nil

        let client = makeClient(nil)
        do {
            let fetched = try await client.accounts()
            apply(accounts: fetched)
            isLoadingAccounts = false
        } catch {
            accountsFailure = OnboardingFailure(error)
            isLoadingAccounts = false
            return
        }
        await loadPreviews(client: client)
    }

    private func loadPreviews(client: (any OnboardingClient)? = nil, resetting: Bool = false) async {
        let list = accounts
        guard !list.isEmpty else { return }
        let client = client ?? makeClient(nil)

        for account in list where resetting || accountPreviews[account.accountSeq] == nil {
            accountPreviews[account.accountSeq] = .loading
        }

        let rate: Decimal
        do {
            let exchangeRate = try await client.exchangeRate(base: .usd, quote: .krw)
            rate = exchangeRate.rate
            usdKrwRate = rate
        } catch {
            let failure = OnboardingFailure(error)
            for account in list {
                accountPreviews[account.accountSeq] = .failed(failure.message)
            }
            return
        }

        // 직렬 호출. 계좌 도메인은 초당 1회 제한이라 절대 병렬로 부채질하지 않는다 (docs/api-notes.md).
        for account in list {
            do {
                let holdings = try await client.holdings(accountSeq: account.accountSeq)
                accountPreviews[account.accountSeq] = .loaded(
                    krwTotal: holdings.marketValue.totalKRW(usdKrwRate: rate),
                    itemCount: holdings.itemCount
                )
            } catch is CancellationError {
                accountPreviews[account.accountSeq] = nil
                return
            } catch {
                accountPreviews[account.accountSeq] = .failed(OnboardingFailure(error).message)
            }
        }
    }

    private func apply(accounts fetched: [TossAccount]) {
        accounts = fetched
        didLoadAccounts = true
        accountPreviews = accountPreviews.filter { key, _ in fetched.contains { $0.accountSeq == key } }
        let available = Set(fetched.map(\.accountSeq))
        selectedAccountSeqs.formIntersection(available)
        // README §2.1 — 기본 전체 선택.
        if selectedAccountSeqs.isEmpty { selectedAccountSeqs = available }
        persistProgress()
    }

    // MARK: - [4] 목표 입력

    /// 오늘 이후만 고를 수 있다 (README §2.1). KST 자정 기준.
    var minimumTargetDate: Date {
        let todayMidnight = FireCalculator.kstMidnight(of: Date())
        return Calendar.seoul.date(byAdding: .day, value: 1, to: todayMidnight)
            ?? todayMidnight.addingTimeInterval(86_400)
    }

    var canFinishGoal: Bool { targetAmount > 0 }

    func dDayPreview(now: Date = Date()) -> Int {
        FireCalculator.dDay(targetDate: targetDate, now: now)
    }

    func setTargetAmountText(_ text: String) {
        applyAmount(AmountInput.value(from: text))
        persistProgress()
    }

    func addToTargetAmount(_ delta: Int) {
        let next = targetAmount.addingReportingOverflow(delta)
        applyAmount(next.overflow ? targetAmount : next.partialValue)
        persistProgress()
    }

    func setTargetDate(_ date: Date) {
        targetDate = max(date, minimumTargetDate)
        persistProgress()
    }

    private func applyAmount(_ amount: Int) {
        let clamped = min(max(amount, 0), AmountInput.maximum)
        targetAmount = clamped
        targetAmountText = clamped == 0 ? "" : AmountInput.grouped(clamped)
    }

    // MARK: - [5] 완료

    /// 설정 저장 → 첫 스냅샷 → 위젯 갱신 → 메인으로 (README §2.1 [5]).
    func startFinishing() {
        guard finishTask == nil, !didComplete else { return }
        finishTask = Task { [self] in
            await finish()
            finishTask = nil
        }
    }

    func retryFinishing() {
        finishFailure = nil
        startFinishing()
    }

    /// 앱 셸이 onCompleted 를 붙이지 못한 경우를 위한 수동 탈출구.
    func openMainScreen() { onCompleted?() }

    private func finish() async {
        isFinishing = true
        finishFailure = nil
        defer { isFinishing = false }

        var settings = settingsStore.load() ?? .fresh
        settings.targetAmount = targetAmount
        settings.targetDate = targetDate
        settings.selectedAccountSeqs = selectedAccountSeqs.sorted()
        settings.onboardingCompleted = true

        do {
            try settingsStore.save(settings)
        } catch {
            finishFailure = OnboardingFailure(error)
            return
        }

        // 첫 스냅샷. 실패해도 온보딩은 끝난다 — 메인이 "스냅샷 없음" 상태로 재시도를 안내한다 (README §2.6).
        let service = RefreshService(client: makeClient(nil),
                                     settingsStore: settingsStore,
                                     snapshotStore: snapshotStore)
        await service.refresh()

        reloadWidgets()
        progressStore.clear()
        didComplete = true
        NotificationCenter.default.post(name: .fireOnboardingCompleted, object: nil)
        onCompleted?()
    }

    private func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: - Progress persistence

    private func persistProgress() {
        // 설정 화면에서 단계를 단독 재사용할 때는 온보딩 진행 기록을 건드리지 않는다.
        // 이미 끝난 온보딩의 이력을 되살려 놓으면 초기화 후 재진입이 엉뚱한 단계에서 시작한다.
        guard !isSettingsReuse else { return }
        progressStore.save(OnboardingProgress(step: step.rawValue,
                                              targetAmount: targetAmount,
                                              targetDate: targetDate,
                                              selectedAccountSeqs: selectedAccountSeqs.sorted()))
    }
}

// MARK: - Amount input formatting

/// 입력창은 천 단위 콤마가 붙은 문자열, 실제 값은 Int (README §2.1 [4]).
enum AmountInput {
    /// 15자리. Int 오버플로 걱정 없이 표기 가능한 상한.
    static let maximum = 999_999_999_999_999

    static func value(from text: String) -> Int {
        let digits = text.filter(\.isNumber).prefix(15)
        return Int(digits) ?? 0
    }

    static func grouped(_ value: Int) -> String {
        grouped(digits: String(max(value, 0)))
    }

    static func grouped(digits: String) -> String {
        let characters = Array(digits)
        var result = ""
        result.reserveCapacity(characters.count + characters.count / 3)
        for (index, character) in characters.enumerated() {
            if index > 0, (characters.count - index).isMultiple(of: 3) { result.append(",") }
            result.append(character)
        }
        return result
    }
}

/// Decimal 을 Double 로 떨어뜨리지 않고 표기한다 (환율 표시용).
enum DecimalDisplay {
    static func string(_ value: Decimal, fractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }
}

// MARK: - SwiftUI preview support

#if DEBUG
/// 프리뷰 전용. 네트워크도 Keychain 도 건드리지 않는다 — 계좌/금액을 지어내지 않기 위해
/// 조회 계열은 빈 목록이나 명시적인 오류만 돌려준다.
struct PreviewOnboardingClient: OnboardingClient {
    private static let notAvailable = TossAPIError.transport("미리보기에서는 네트워크를 호출하지 않아요.")

    func verifyConnection() async throws -> [TossAccount] { [] }
    func invalidateToken() async {}
    func accounts() async throws -> [TossAccount] { [] }
    func holdings(accountSeq: Int) async throws -> HoldingsOverview { throw Self.notAvailable }
    func exchangeRate(base: Currency, quote: Currency) async throws -> ExchangeRate { throw Self.notAvailable }
    func cashBuyingPower(accountSeq: Int, currency: Currency) async throws -> Decimal { throw Self.notAvailable }
}

final class PreviewCredentialStore: OnboardingCredentialStore {
    private var stored: TokenCredentials?
    init(_ initial: TokenCredentials? = nil) { stored = initial }
    func credentials() throws -> TokenCredentials? { stored }
    func saveCredentials(_ credentials: TokenCredentials) throws { stored = credentials }
}

extension OnboardingModel {
    static func previewModel(step: OnboardingStep = .intro) -> OnboardingModel {
        let model = OnboardingModel(credentialStore: PreviewCredentialStore(),
                                    settingsStore: InMemorySettingsStore(),
                                    snapshotStore: InMemorySnapshotStore(),
                                    progressStore: InMemoryOnboardingProgressStore(
                                        OnboardingProgress(step: step.rawValue,
                                                           targetAmount: 0,
                                                           targetDate: Settings.fresh.targetDate,
                                                           selectedAccountSeqs: [])),
                                    makeClient: { _ in PreviewOnboardingClient() })
        model.start()
        return model
    }
}
#endif
