//
//  FireCalculator.swift
//  FireCore
//
//  README §1.1:
//      dDay      = targetDate - today          # 자정(KST) 기준
//      progress  = currentAssets / targetAmount
//      remaining = max(targetAmount - currentAssets, 0)
//
//  Every function here is a pure function of its arguments plus the injected
//  calendar. Nothing reads `Date()` or `TimeZone.current`.
//

import Foundation

public enum FireCalculator: Sendable {

    // MARK: - D-Day

    /// Whole days between the KST midnight of `now` and the KST midnight of `targetDate`.
    ///
    /// today → `0`, tomorrow → `1`, yesterday → `-1`.
    ///
    /// Both instants are normalized to the start of their KST day first and the
    /// difference is taken with `dateComponents(_:from:to:)`, so the result is
    /// exact across month, year and leap-day boundaries and is unaffected by the
    /// timezone of the device the caller runs on. Asia/Seoul has no DST, but the
    /// calendar does the arithmetic anyway — never `86_400`-second math.
    public static func dDay(targetDate: Date, now: Date, calendar: Calendar = .seoul) -> Int {
        let from = kstMidnight(of: now, calendar: calendar)
        let to = kstMidnight(of: targetDate, calendar: calendar)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    // MARK: - Progress

    /// `currentAssets / targetAmount`, may exceed `1.0` (README allows >100%).
    ///
    /// A non-positive target is not a goal, so it yields `0` instead of an
    /// infinity or a NaN that would poison the progress bar.
    ///
    /// This is the one and only place a `Double` is allowed to carry a money-derived
    /// value, and it is a ratio, not an amount.
    public static func progress(currentAssets: Int, targetAmount: Int) -> Double {
        guard targetAmount > 0 else { return 0 }
        return Double(currentAssets) / Double(targetAmount)
    }

    /// `max(targetAmount - currentAssets, 0)` — the 남은 금액 line on the main screen.
    ///
    /// The subtraction reports overflow rather than trapping, so an absurd pair of
    /// inputs (`targetAmount == .max`, `currentAssets == .min`) saturates instead of
    /// crashing the app.
    public static func remaining(currentAssets: Int, targetAmount: Int) -> Int {
        let (difference, overflowed) = targetAmount.subtractingReportingOverflow(currentAssets)
        guard !overflowed else {
            // The subtraction can only run off the positive end, and that needs a
            // negative `currentAssets`; the negative end saturates at the clamp.
            return currentAssets < 0 ? Int.max : 0
        }
        return max(difference, 0)
    }

    // MARK: - KST day boundaries

    /// KST midnight (00:00:00) of the day containing `date`.
    public static func kstMidnight(of date: Date, calendar: Calendar = .seoul) -> Date {
        calendar.startOfDay(for: date)
    }

    /// The next `count` KST midnights, strictly after `now`, ascending.
    ///
    /// Feeds the widget timeline (README §4.2): one entry per midnight for the
    /// next 7 days so the D-Day number rolls over at midnight even with no
    /// network. Returns `[]` for a non-positive `count`.
    public static func upcomingMidnights(from now: Date, count: Int, calendar: Calendar = .seoul) -> [Date] {
        guard count > 0 else { return [] }

        let base = kstMidnight(of: now, calendar: calendar)
        var midnights: [Date] = []
        midnights.reserveCapacity(count)

        // `base` is at or before `now`, so `base + 1 day` is always strictly after
        // `now`. The `> now` check and the offset ceiling are belt-and-braces for a
        // calendar anomaly that Asia/Seoul does not have.
        var offset = 1
        let maxOffset = count + 8
        while midnights.count < count && offset <= maxOffset {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: base) else { break }
            offset += 1
            guard candidate > now else { continue }
            midnights.append(candidate)
        }
        return midnights
    }
}
