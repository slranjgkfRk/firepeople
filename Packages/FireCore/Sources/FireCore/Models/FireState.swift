import Foundation

/// Everything a view needs, already computed. The app screens and the widget read this and nothing
/// else — no view touches `Snapshot` or `Settings` directly, so both processes render identically.
public struct FireState: Sendable, Equatable {

    /// Days until 예정일: `0` on the day itself, negative once it has passed.
    public let dDay: Int

    /// `currentAssets / targetAmount`. The one place a `Double` is allowed — it drives a progress
    /// bar, never an amount. May exceed 1.0.
    public let progress: Double

    /// Won.
    public let currentAssets: Int

    /// Won.
    public let targetAmount: Int

    /// `max(targetAmount - currentAssets, 0)`, in won.
    public let remaining: Int

    /// KST midnight of 예정일.
    public let targetDate: Date

    /// `nil` when no snapshot has ever been stored — README §2.6's "--%" state.
    public let fetchedAt: Date?

    public let status: FetchStatus

    public init(
        dDay: Int,
        progress: Double,
        currentAssets: Int,
        targetAmount: Int,
        remaining: Int,
        targetDate: Date,
        fetchedAt: Date?,
        status: FetchStatus
    ) {
        self.dDay = dDay
        self.progress = progress
        self.currentAssets = currentAssets
        self.targetAmount = targetAmount
        self.remaining = remaining
        self.targetDate = targetDate
        self.fetchedAt = fetchedAt
        self.status = status
    }

    /// `false` -> show "--%" and a retry button instead of the progress row.
    public var hasSnapshot: Bool { fetchedAt != nil }

    /// `true` -> full bar, colour change, "목표 달성" in place of the remaining amount (README §2.6).
    public var isGoalReached: Bool { progress >= 1.0 }

    /// The single place a view's numbers come from.
    ///
    /// With no snapshot the money side reads zero and the status is `.ok` — there has been no failed
    /// fetch to report — but the D-day, 예정일 and 목표 금액 still come from the user's settings, which
    /// is what README §2.6 shows: a real D-day next to "--%".
    public static func make(settings: Settings, snapshot: Snapshot?, now: Date) -> FireState {
        let currentAssets = snapshot?.currentAssets ?? 0
        return FireState(
            dDay: FireCalculator.dDay(targetDate: settings.targetDate, now: now),
            progress: FireCalculator.progress(
                currentAssets: currentAssets,
                targetAmount: settings.targetAmount
            ),
            currentAssets: currentAssets,
            targetAmount: settings.targetAmount,
            remaining: FireCalculator.remaining(
                currentAssets: currentAssets,
                targetAmount: settings.targetAmount
            ),
            targetDate: settings.targetDate,
            fetchedAt: snapshot?.fetchedAt,
            status: snapshot?.status ?? .ok
        )
    }
}
