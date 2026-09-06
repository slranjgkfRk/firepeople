//
//  FireCalculatorTests.swift
//  FireCoreTests
//
//  README §9 test matrix, `FireCalculator` row: D-day boundaries (today / the target day / a past
//  target), progress 0% / 100% / over 100%, the zero-target guard, KST midnight normalisation and
//  the leap-day and year boundaries.
//
//  Every date is written as an explicit ISO-8601 instant with an explicit offset, so the assertions
//  hold whatever timezone, locale or clock the machine running `swift test` happens to have.
//

import XCTest
import FireCore

final class FireCalculatorTests: XCTestCase {

    // MARK: - D-day: the ordinary cases

    func testDDayIsZeroOnTheTargetDayWhateverTheTimeOfDay() {
        let target = TestDate.kst("2029-12-31T00:00:00+09:00")

        for wallClock in ["2029-12-31T00:00:00+09:00",
                          "2029-12-31T09:00:00+09:00",
                          "2029-12-31T23:59:59+09:00"] {
            XCTAssertEqual(
                FireCalculator.dDay(targetDate: target, now: TestDate.kst(wallClock)),
                0,
                "D-DAY must hold for the whole KST day, not just its midnight (\(wallClock))"
            )
        }
    }

    func testDDayIsOneTomorrowAndMinusOneYesterday() {
        let target = TestDate.kst("2026-09-07T00:00:00+09:00")

        XCTAssertEqual(FireCalculator.dDay(targetDate: target,
                                           now: TestDate.kst("2026-09-06T23:59:59+09:00")), 1)
        XCTAssertEqual(FireCalculator.dDay(targetDate: TestDate.kst("2026-09-05T00:00:00+09:00"),
                                           now: TestDate.kst("2026-09-06T00:00:01+09:00")), -1)
    }

    func testDDayCountsWholeDaysToADistantTarget() {
        // 2026-09-06 → 2029-12-31: three years (2028 is a leap year) plus 116 days.
        XCTAssertEqual(
            FireCalculator.dDay(targetDate: TestDate.kst("2029-12-31T00:00:00+09:00"),
                                now: TestDate.kst("2026-09-06T17:51:00+09:00")),
            1212
        )
    }

    func testDDayGoesNegativeOnceTheTargetHasPassed() {
        // README §2.6: the app keeps working and shows `D+n`.
        let target = TestDate.kst("2026-09-01T00:00:00+09:00")

        XCTAssertEqual(FireCalculator.dDay(targetDate: target,
                                           now: TestDate.kst("2026-09-06T08:00:00+09:00")), -5)
        XCTAssertEqual(FireCalculator.dDay(targetDate: target,
                                           now: TestDate.kst("2027-09-01T00:00:00+09:00")), -365)
    }

    // MARK: - D-day: boundaries

    func testDDayCrossesAMonthBoundary() {
        XCTAssertEqual(
            FireCalculator.dDay(targetDate: TestDate.kst("2026-10-01T00:00:00+09:00"),
                                now: TestDate.kst("2026-09-30T23:30:00+09:00")),
            1
        )
        // September has 30 days.
        XCTAssertEqual(
            FireCalculator.dDay(targetDate: TestDate.kst("2026-10-01T00:00:00+09:00"),
                                now: TestDate.kst("2026-09-01T00:00:00+09:00")),
            30
        )
    }

    func testDDayCrossesAYearBoundary() {
        XCTAssertEqual(
            FireCalculator.dDay(targetDate: TestDate.kst("2027-01-01T00:00:00+09:00"),
                                now: TestDate.kst("2026-12-31T23:59:00+09:00")),
            1
        )
        // 2026 is not a leap year.
        XCTAssertEqual(
            FireCalculator.dDay(targetDate: TestDate.kst("2027-01-01T00:00:00+09:00"),
                                now: TestDate.kst("2026-01-01T00:00:00+09:00")),
            365
        )
    }

    func testDDayHandlesALeapDayTarget() {
        let leapDay = TestDate.kst("2028-02-29T00:00:00+09:00")

        XCTAssertEqual(FireCalculator.dDay(targetDate: leapDay,
                                           now: TestDate.kst("2028-02-28T09:00:00+09:00")), 1)
        XCTAssertEqual(FireCalculator.dDay(targetDate: leapDay,
                                           now: TestDate.kst("2028-02-29T12:00:00+09:00")), 0)
        XCTAssertEqual(FireCalculator.dDay(targetDate: leapDay,
                                           now: TestDate.kst("2028-03-01T00:30:00+09:00")), -1)
        // January 31 → February 29 is 29 days only in a leap year.
        XCTAssertEqual(FireCalculator.dDay(targetDate: leapDay,
                                           now: TestDate.kst("2028-01-31T00:00:00+09:00")), 29)
    }

    func testDDayHandlesTheNonLeapEndOfFebruary() {
        XCTAssertEqual(
            FireCalculator.dDay(targetDate: TestDate.kst("2027-03-01T00:00:00+09:00"),
                                now: TestDate.kst("2027-02-28T22:00:00+09:00")),
            1
        )
    }

    // MARK: - D-day: independent of the device timezone (README §1.1)

    /// 15:00 UTC is already the next calendar day in Seoul while still being the previous one in
    /// New York, so a naive device-local calculation and the KST one disagree. The app must always
    /// answer the KST one.
    func testDDayUsesSeoulNotTheDeviceCalendar() {
        let now = TestDate.iso("2026-09-06T15:30:00Z")     // KST 09-07 00:30 · EDT 09-06 11:30
        let target = TestDate.iso("2026-09-09T10:00:00Z")  // KST 09-09 19:00 · EDT 09-09 06:00

        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!

        XCTAssertEqual(FireCalculator.dDay(targetDate: target, now: now, calendar: newYork), 3,
                       "sanity: a device-local calculation would say 3")
        XCTAssertEqual(FireCalculator.dDay(targetDate: target, now: now), 2,
                       "the app must answer in KST, whatever the device thinks the date is")
    }

    /// The same property from the other side: switch the *process* timezone and the answer must not
    /// move, because `FireCalculator` never reads `TimeZone.current`.
    func testDDayIsUnchangedByTheProcessTimeZone() {
        let now = TestDate.iso("2026-09-06T15:30:00Z")
        let target = TestDate.iso("2026-09-09T10:00:00Z")

        for identifier in ["Asia/Seoul", "America/New_York", "UTC", "Pacific/Kiritimati"] {
            withProcessTimeZone(identifier) {
                XCTAssertEqual(FireCalculator.dDay(targetDate: target, now: now), 2,
                               "D-day moved when the device timezone was \(identifier)")
                XCTAssertEqual(FireCalculator.kstMidnight(of: now),
                               TestDate.kst("2026-09-07T00:00:00+09:00"),
                               "KST midnight moved when the device timezone was \(identifier)")
            }
        }
    }

    func testSeoulCalendarIsGregorianKST() {
        XCTAssertEqual(Calendar.seoul.timeZone.identifier, "Asia/Seoul")
        XCTAssertEqual(Calendar.seoul.identifier, .gregorian)
        XCTAssertEqual(TimeZone.seoul.secondsFromGMT(), 9 * 3600, "KST is UTC+9 and has no DST")
    }

    // MARK: - Progress

    func testProgressAtZero() {
        XCTAssertEqual(FireCalculator.progress(currentAssets: 0, targetAmount: 200_000_000), 0.0)
    }

    func testProgressAtExactlyOneHundredPercent() {
        XCTAssertEqual(FireCalculator.progress(currentAssets: 200_000_000, targetAmount: 200_000_000), 1.0)
    }

    func testProgressOverOneHundredPercentIsNotClamped() {
        // README §1.1 explicitly allows >100% for display.
        XCTAssertEqual(
            FireCalculator.progress(currentAssets: 207_400_000, targetAmount: 200_000_000),
            1.037,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            FireCalculator.progress(currentAssets: 123_450_000, targetAmount: 200_000_000),
            0.61725,
            accuracy: 1e-12
        )
    }

    func testProgressGuardsAZeroOrNegativeTarget() {
        // Nothing may divide by zero and hand a NaN or an infinity to the progress bar.
        for target in [0, -1, Int.min] {
            let value = FireCalculator.progress(currentAssets: 30_371_787, targetAmount: target)
            XCTAssertEqual(value, 0.0, "target \(target) must yield 0, got \(value)")
            XCTAssertTrue(value.isFinite)
        }
    }

    // MARK: - Remaining

    func testRemaining() {
        XCTAssertEqual(FireCalculator.remaining(currentAssets: 123_450_000, targetAmount: 200_000_000),
                       76_550_000)
        XCTAssertEqual(FireCalculator.remaining(currentAssets: 200_000_000, targetAmount: 200_000_000), 0)
        XCTAssertEqual(FireCalculator.remaining(currentAssets: 250_000_000, targetAmount: 200_000_000), 0,
                       "past the goal there is nothing remaining, never a negative amount")
        XCTAssertEqual(FireCalculator.remaining(currentAssets: 0, targetAmount: 0), 0)
    }

    // MARK: - KST midnight

    func testKstMidnightNormalisesAnyInstantOfTheKstDay() {
        let expected = TestDate.kst("2026-09-06T00:00:00+09:00")

        for wallClock in ["2026-09-06T00:00:00+09:00",
                          "2026-09-06T00:00:01+09:00",
                          "2026-09-06T14:30:00+09:00",
                          "2026-09-06T23:59:59+09:00"] {
            XCTAssertEqual(FireCalculator.kstMidnight(of: TestDate.kst(wallClock)), expected, wallClock)
        }
    }

    func testKstMidnightIsIdempotentAndAnchoredToSeoulNotUTC() {
        // 2026-09-05T15:30:00Z is already 2026-09-06 in Seoul.
        let instant = TestDate.iso("2026-09-05T15:30:00Z")
        let midnight = FireCalculator.kstMidnight(of: instant)

        XCTAssertEqual(midnight, TestDate.kst("2026-09-06T00:00:00+09:00"))
        XCTAssertEqual(FireCalculator.kstMidnight(of: midnight), midnight, "must be idempotent")
        XCTAssertEqual(midnight, TestDate.iso("2026-09-05T15:00:00Z"), "KST midnight is 15:00 UTC")
    }

    // MARK: - Widget timeline midnights (README §4.2)

    func testUpcomingMidnightsAreSevenAscendingStrictlyFutureKstMidnights() {
        let now = TestDate.kst("2026-09-06T14:30:00+09:00")
        let midnights = FireCalculator.upcomingMidnights(from: now, count: 7)

        XCTAssertEqual(midnights.count, 7)
        XCTAssertEqual(midnights, [
            TestDate.kst("2026-09-07T00:00:00+09:00"),
            TestDate.kst("2026-09-08T00:00:00+09:00"),
            TestDate.kst("2026-09-09T00:00:00+09:00"),
            TestDate.kst("2026-09-10T00:00:00+09:00"),
            TestDate.kst("2026-09-11T00:00:00+09:00"),
            TestDate.kst("2026-09-12T00:00:00+09:00"),
            TestDate.kst("2026-09-13T00:00:00+09:00")
        ])

        for (index, midnight) in midnights.enumerated() {
            XCTAssertGreaterThan(midnight, now, "entry \(index) must be strictly in the future")
            XCTAssertEqual(FireCalculator.kstMidnight(of: midnight), midnight,
                           "entry \(index) must itself be a KST midnight")
            if index > 0 {
                XCTAssertEqual(midnight.timeIntervalSince(midnights[index - 1]), 86_400,
                               "KST has no DST, so consecutive midnights are exactly 24h apart")
            }
        }
    }

    func testUpcomingMidnightsSkipTheCurrentMidnightEvenAtMidnightExactly() {
        let now = TestDate.kst("2026-09-06T00:00:00+09:00")
        let midnights = FireCalculator.upcomingMidnights(from: now, count: 7)

        XCTAssertEqual(midnights.first, TestDate.kst("2026-09-07T00:00:00+09:00"),
                       "the timeline starts with the *next* midnight, never with this one")
        XCTAssertEqual(midnights.count, 7)
    }

    func testUpcomingMidnightsCrossMonthYearAndLeapDayBoundaries() {
        XCTAssertEqual(
            FireCalculator.upcomingMidnights(from: TestDate.kst("2026-12-30T23:00:00+09:00"), count: 3),
            [TestDate.kst("2026-12-31T00:00:00+09:00"),
             TestDate.kst("2027-01-01T00:00:00+09:00"),
             TestDate.kst("2027-01-02T00:00:00+09:00")]
        )
        XCTAssertEqual(
            FireCalculator.upcomingMidnights(from: TestDate.kst("2028-02-27T12:00:00+09:00"), count: 3),
            [TestDate.kst("2028-02-28T00:00:00+09:00"),
             TestDate.kst("2028-02-29T00:00:00+09:00"),
             TestDate.kst("2028-03-01T00:00:00+09:00")]
        )
    }

    func testUpcomingMidnightsWithANonPositiveCountIsEmpty() {
        let now = TestDate.kst("2026-09-06T14:30:00+09:00")
        XCTAssertEqual(FireCalculator.upcomingMidnights(from: now, count: 0), [])
        XCTAssertEqual(FireCalculator.upcomingMidnights(from: now, count: -1), [])
    }

    // MARK: - FireState (what the views actually read)

    func testFireStateComposesTheCalculatorOutputs() {
        let settings = Settings(
            targetAmount: 200_000_000,
            targetDate: TestDate.kst("2029-12-31T00:00:00+09:00"),
            selectedAccountSeqs: [1],
            onboardingCompleted: true
        )
        let fetchedAt = TestDate.kst("2026-09-06T17:51:58+09:00")
        let snapshot = Snapshot(
            currentAssets: 123_450_000,
            perAccount: [1: 123_450_000],
            krwAmount: 38585,
            usdAmount: Decimal(string: "22417.561095")!,
            usdKrwRate: Decimal(string: "1353.1")!,
            cashKRW: nil,
            fetchedAt: fetchedAt,
            status: .ok
        )

        let state = FireState.make(settings: settings,
                                   snapshot: snapshot,
                                   now: TestDate.kst("2026-09-06T18:00:00+09:00"))

        XCTAssertEqual(state.dDay, 1212)
        XCTAssertEqual(state.progress, 0.61725, accuracy: 1e-12)
        XCTAssertEqual(state.currentAssets, 123_450_000)
        XCTAssertEqual(state.targetAmount, 200_000_000)
        XCTAssertEqual(state.remaining, 76_550_000)
        XCTAssertEqual(state.targetDate, TestDate.kst("2029-12-31T00:00:00+09:00"))
        XCTAssertEqual(state.fetchedAt, fetchedAt)
        XCTAssertEqual(state.status, .ok)
        XCTAssertTrue(state.hasSnapshot)
        XCTAssertFalse(state.isGoalReached)
    }

    func testFireStateWithoutASnapshotStillHasADDay() {
        // README §2.6 "스냅샷 없음": a real D-day next to `--%` and a retry button.
        let settings = Settings(
            targetAmount: 200_000_000,
            targetDate: TestDate.kst("2029-12-31T00:00:00+09:00"),
            onboardingCompleted: true
        )
        let state = FireState.make(settings: settings,
                                   snapshot: nil,
                                   now: TestDate.kst("2026-09-06T18:00:00+09:00"))

        XCTAssertEqual(state.dDay, 1212)
        XCTAssertNil(state.fetchedAt)
        XCTAssertFalse(state.hasSnapshot)
        XCTAssertEqual(state.currentAssets, 0)
        XCTAssertEqual(state.progress, 0)
        XCTAssertEqual(state.remaining, 200_000_000)
        XCTAssertFalse(state.isGoalReached)
    }

    func testFireStateIsGoalReachedAtExactlyOneHundredPercent() {
        let settings = Settings(targetAmount: 30_371_787,
                                targetDate: TestDate.kst("2029-12-31T00:00:00+09:00"))
        let snapshot = Snapshot(
            currentAssets: 30_371_787,
            perAccount: [1: 30_371_787],
            krwAmount: 38585,
            usdAmount: Decimal(string: "22417.561095")!,
            usdKrwRate: Decimal(string: "1353.1")!,
            cashKRW: nil,
            fetchedAt: TestDate.kst("2026-09-06T17:51:58+09:00"),
            status: .ok
        )

        let state = FireState.make(settings: settings,
                                   snapshot: snapshot,
                                   now: TestDate.kst("2026-09-06T18:00:00+09:00"))

        XCTAssertEqual(state.progress, 1.0)
        XCTAssertTrue(state.isGoalReached)
        XCTAssertEqual(state.remaining, 0)
    }

    // MARK: - Helpers

    /// Runs `body` with the process timezone switched. Restores it afterwards even on failure.
    /// If the platform refuses the switch the assertions inside still hold — they are supposed to
    /// be timezone-independent — so this never fails for an environmental reason.
    private func withProcessTimeZone(_ identifier: String, _ body: () -> Void) {
        let previous = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", identifier, 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let previous {
                setenv("TZ", previous, 1)
            } else {
                unsetenv("TZ")
            }
            NSTimeZone.resetSystemTimeZone()
        }
        body()
    }
}
