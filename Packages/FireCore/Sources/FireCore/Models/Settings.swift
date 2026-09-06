import Foundation

/// How often the app and the widget try to pull a fresh snapshot (README §4.2).
public enum RefreshPolicy: String, Codable, Sendable, CaseIterable, Hashable {
    case hourly
    case daily

    /// The staleness threshold, in seconds.
    public var interval: TimeInterval {
        switch self {
        case .hourly: return 3600
        case .daily: return 86400
        }
    }

    /// Settings-row label, README §2.3.
    public var displayNameKo: String {
        switch self {
        case .hourly: return "매시간"
        case .daily: return "하루 1회"
        }
    }
}

/// Everything the user chose. Persisted as JSON in the App Group container; secrets live in the
/// Keychain and never here (README §7).
public struct Settings: Codable, Sendable, Equatable {

    /// FIRE 목표 금액, in won.
    public var targetAmount: Int

    /// FIRE 예정일. Always kept at KST midnight so the D-day never wobbles with the device's time
    /// zone — assigning any instant of a day snaps it to that day's midnight in Seoul.
    public var targetDate: Date {
        didSet {
            // Assigning inside `didSet` does not re-enter it, so this normalizes exactly once.
            targetDate = FireCalculator.kstMidnight(of: targetDate)
        }
    }

    /// The accounts whose 평가금액 are summed. Empty means "nothing selected yet".
    public var selectedAccountSeqs: [Int]

    public var refreshPolicy: RefreshPolicy

    /// README §2.4 — hides the amount row on the medium widget, leaving the percentage.
    public var hideAmountInWidget: Bool

    /// README §12 — adds `cashBuyingPower` to the total. Default off: stock market value only.
    public var includeCash: Bool

    /// Onboarding runs until this is true; it resumes where the user left off (README §2.1).
    public var onboardingCompleted: Bool

    public init(
        targetAmount: Int = 0,
        targetDate: Date = Settings.defaultTargetDate(),
        selectedAccountSeqs: [Int] = [],
        refreshPolicy: RefreshPolicy = .hourly,
        hideAmountInWidget: Bool = false,
        includeCash: Bool = false,
        onboardingCompleted: Bool = false
    ) {
        self.targetAmount = targetAmount
        // Property observers do not run during initialization, so normalize by hand here.
        self.targetDate = FireCalculator.kstMidnight(of: targetDate)
        self.selectedAccountSeqs = selectedAccountSeqs
        self.refreshPolicy = refreshPolicy
        self.hideAmountInWidget = hideAmountInWidget
        self.includeCash = includeCash
        self.onboardingCompleted = onboardingCompleted
    }

    /// A fresh install: nothing entered, target date ten years out at KST midnight.
    public static var fresh: Settings { Settings() }

    /// KST midnight, ten years from `now` — the starting point a user drags the date picker from.
    public static func defaultTargetDate(from now: Date = Date()) -> Date {
        let calendar = Calendar.seoul
        let today = FireCalculator.kstMidnight(of: now, calendar: calendar)
        guard let tenYearsOut = calendar.date(byAdding: .year, value: 10, to: today) else {
            return today
        }
        return FireCalculator.kstMidnight(of: tenYearsOut, calendar: calendar)
    }

    private enum CodingKeys: String, CodingKey {
        case targetAmount
        case targetDate
        case selectedAccountSeqs
        case refreshPolicy
        case hideAmountInWidget
        case includeCash
        case onboardingCompleted
    }

    /// Hand-written so that a stored payload missing a key (an older build's) still loads with a
    /// sensible default instead of throwing away everything the user configured.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedPolicy = try container.decodeIfPresent(String.self, forKey: .refreshPolicy)
        self.init(
            targetAmount: try container.decodeIfPresent(Int.self, forKey: .targetAmount) ?? 0,
            targetDate: try container.decodeIfPresent(Date.self, forKey: .targetDate)
                ?? Settings.defaultTargetDate(),
            selectedAccountSeqs: try container.decodeIfPresent([Int].self, forKey: .selectedAccountSeqs) ?? [],
            refreshPolicy: storedPolicy.flatMap(RefreshPolicy.init(rawValue:)) ?? .hourly,
            hideAmountInWidget: try container.decodeIfPresent(Bool.self, forKey: .hideAmountInWidget) ?? false,
            includeCash: try container.decodeIfPresent(Bool.self, forKey: .includeCash) ?? false,
            onboardingCompleted: try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetAmount, forKey: .targetAmount)
        try container.encode(targetDate, forKey: .targetDate)
        try container.encode(selectedAccountSeqs, forKey: .selectedAccountSeqs)
        try container.encode(refreshPolicy.rawValue, forKey: .refreshPolicy)
        try container.encode(hideAmountInWidget, forKey: .hideAmountInWidget)
        try container.encode(includeCash, forKey: .includeCash)
        try container.encode(onboardingCompleted, forKey: .onboardingCompleted)
    }
}
