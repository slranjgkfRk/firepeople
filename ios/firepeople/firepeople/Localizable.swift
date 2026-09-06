//
//  Localizable.swift
//  firepeople
//
//  The app is Korean-only (README §6 `Localizable (ko only)`), so the strings live here as plain
//  static constants instead of in a `.strings` catalogue: one file, compile-time checked, no key
//  typos, no runtime lookup that can silently fall back to the key itself.
//
//  Wording that README §2 spells out is reproduced verbatim (`FIRE까지`, `목표 달성`, `마지막 갱신`,
//  `갱신 실패`, `API 키를 확인해주세요`, every settings row title, …). Do not paraphrase those.
//  Every UI slice in this target should reference these constants rather than re-typing literals.
//

import Foundation

/// Every user-visible string in the app target.
///
/// `L` is a shorthand alias for the same enum, so `Strings.fireUntil` and `L.fireUntil` both work.
enum Strings {

    // MARK: - Main screen (README §2.2)

    /// The label above the D-day number.
    static let fireUntil = "FIRE까지"
    /// Prefix of the 남은 금액 line: `남은 금액 7,655만원`.
    static let remainingPrefix = "남은 금액"
    /// README §2.6 — replaces the 남은 금액 line once progress reaches 100%.
    static let goalReached = "목표 달성"
    /// Prefix of the footer line: `마지막 갱신 오늘 14:00`.
    static let lastUpdatedPrefix = "마지막 갱신"
    /// Footer text before the very first successful refresh.
    static let neverUpdated = "아직 갱신되지 않았어요"
    /// README §2.6 — the no-snapshot state's retry button.
    static let retry = "다시 시도"
    /// README §2.6 — stands in for the percentage while there is no snapshot.
    static let percentPlaceholder = "--%"
    /// Stands in for an amount that has never been fetched.
    static let amountPlaceholder = "--"
    /// Separates 현재 금액 from 목표 금액 on the amounts line.
    static let amountSeparator = "/"
    static let refreshing = "갱신 중"

    // MARK: - Banners (README §2.6)

    /// Leading half of `갱신 실패 · 마지막 갱신 3시간 전`.
    static let bannerRefreshFailed = "갱신 실패"
    /// 401 / revoked key. Tapping opens 설정.
    static let bannerAuthFailed = "API 키를 확인해주세요"
    /// 403. The keys are fine; the caller's IP is not on the allow-list
    /// (WTS 설정 → Open API → 허용 IP 관리). Tapping opens 설정.
    static let bannerIPBlocked = "토스증권에 이 기기의 IP를 등록해주세요"
    /// Shown once after the target date passes; tapping opens 설정 to change the date.
    static let bannerTargetPassed = "목표일이 지났어요. 새 목표일을 정해보세요"
    static let bannerDismiss = "배너 닫기"

    /// `갱신 실패 · 마지막 갱신 3시간 전` — README §2.6's network-failure banner.
    static func bannerRefreshFailedLine(lastUpdated: Date, now: Date) -> String {
        "\(bannerRefreshFailed) · \(lastUpdatedPrefix) \(agoKo(lastUpdated, now: now))"
    }

    // MARK: - Settings (README §2.3)

    static let settings = "설정"
    static let settingsEditTargetAmount = "목표 금액 수정"
    static let settingsEditTargetDate = "FIRE 예정일 수정"
    static let settingsReselectAccounts = "계좌 다시 선택"
    static let settingsRefreshPolicy = "갱신 주기"
    static let settingsReenterKeys = "API 키 재입력"
    static let settingsReset = "API 키 삭제 및 초기화"
    static let settingsWidgetGuide = "위젯 추가 방법"
    static let settingsAbout = "정보"
    static let settingsHideAmountInWidget = "위젯에 금액 숨기기"
    static let settingsIncludeCash = "예수금 포함"
    static let settingsVersion = "버전"
    /// README §2.3 — the disclaimer the 정보 row must state.
    static let aboutReadOnly = "읽기 전용 API만 사용합니다"
    static let resetConfirmTitle = "API 키를 삭제하고 초기화할까요?"
    static let resetConfirmMessage = "Keychain에 저장된 키와 설정, 스냅샷이 모두 지워지고 온보딩부터 다시 시작합니다."
    static let resetConfirmAction = "삭제하고 초기화"

    // MARK: - Onboarding (README §2.1)

    static let onboardingIntroTitle = "FIRE까지 남은 날을 세어 드려요"
    static let onboardingIntroBody = "토스증권 Open API 키가 있어야 계좌 평가금액을 불러올 수 있어요."
    /// README §2.1 requires this sentence on the intro step.
    /// (`docs/api-notes.md` records that issuance was immediate in practice, but the spec's wording
    /// stands — it sets the right expectation and costs nothing if issuance is instant.)
    static let onboardingIssuanceNotice = "발급까지 며칠 걸릴 수 있음"
    static let onboardingIssuanceGuide = "토스증권 WTS → 설정 → Open API 에서 발급할 수 있어요."
    static let onboardingIPNotice = "설정 → Open API → 허용 IP 관리에 현재 IP를 등록해야 조회가 됩니다."
    static let onboardingKeyTitle = "API 키 입력"
    static let clientIdLabel = "client_id"
    static let clientSecretLabel = "client_secret"
    static let testConnection = "연결 테스트"
    static let testConnectionSucceeded = "연결에 성공했어요"
    static let onboardingAccountsTitle = "계좌 선택"
    static let onboardingAccountsSubtitle = "합산할 계좌를 골라주세요. 여러 개 선택할 수 있어요."
    static let onboardingGoalTitle = "목표 입력"
    static let targetAmountLabel = "FIRE 목표 금액"
    static let targetDateLabel = "FIRE 예정일"
    static let onboardingDoneTitle = "준비 끝!"
    static let onboardingDoneBody = "이제 홈 화면에 위젯을 올려두면 매일 숫자가 줄어드는 걸 볼 수 있어요."

    // MARK: - Generic actions

    static let next = "다음"
    static let back = "이전"
    static let done = "완료"
    static let start = "시작하기"
    static let cancel = "취소"
    static let confirm = "확인"
    static let close = "닫기"

    // MARK: - Accessibility

    static let progressAccessibilityLabel = "목표 달성률"
    static let settingsAccessibilityLabel = "설정 열기"
    static let refreshAccessibilityLabel = "지금 갱신"

    /// `D-1,234` reads terribly out loud; spell the countdown instead.
    static func dDayAccessibilityLabel(_ days: Int) -> String {
        if days == 0 { return "오늘이 FIRE 목표일" }
        if days > 0 { return "FIRE까지 \(days)일 남음" }
        return "FIRE 목표일에서 \(-days)일 지남"
    }

    // MARK: - Relative time

    /// `방금 전` / `12분 전` / `3시간 전` / `4일 전` — hand-rolled so the output is Korean whatever the
    /// device locale is set to, matching README §2.6's `마지막 갱신 3시간 전`.
    /// A future date (clock skew) reads as `방금 전` rather than a negative number.
    static func agoKo(_ date: Date, now: Date) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "방금 전" }
        if minutes < 60 { return "\(minutes)분 전" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)시간 전" }

        let days = hours / 24
        if days < 30 { return "\(days)일 전" }

        let months = days / 30
        if months < 12 { return "\(months)개월 전" }
        return "\(months / 12)년 전"
    }
}

/// Shorthand: `L.fireUntil` == `Strings.fireUntil`.
typealias L = Strings
