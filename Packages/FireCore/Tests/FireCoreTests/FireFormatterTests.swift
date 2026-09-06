//
//  FireFormatterTests.swift
//  FireCoreTests
//
//  README §2.5 숫자 표기 규칙, row by row, plus the negative-number guards from the §9 matrix.
//  These strings are what the user actually reads on the main screen and on the widget, so every
//  example the README prints is asserted literally.
//

import XCTest
import FireCore

final class FireFormatterTests: XCTestCase {

    // MARK: - D-day  (`D-1,234`, `D-DAY`, `D+12`)

    func testDDayReadmeExamples() {
        XCTAssertEqual(FireFormatter.dDay(1234), "D-1,234")
        XCTAssertEqual(FireFormatter.dDay(0), "D-DAY")
        XCTAssertEqual(FireFormatter.dDay(-12), "D+12")
    }

    func testDDayGrouping() {
        XCTAssertEqual(FireFormatter.dDay(1), "D-1")
        XCTAssertEqual(FireFormatter.dDay(9), "D-9")
        XCTAssertEqual(FireFormatter.dDay(99), "D-99")
        XCTAssertEqual(FireFormatter.dDay(999), "D-999")
        XCTAssertEqual(FireFormatter.dDay(1000), "D-1,000")
        XCTAssertEqual(FireFormatter.dDay(1212), "D-1,212")
        XCTAssertEqual(FireFormatter.dDay(12345), "D-12,345")
        XCTAssertEqual(FireFormatter.dDay(1234567), "D-1,234,567")
    }

    func testDDayPastTheTargetDate() {
        // README §2.6 "목표일 경과": `D+n`, and the app keeps working.
        XCTAssertEqual(FireFormatter.dDay(-1), "D+1")
        XCTAssertEqual(FireFormatter.dDay(-1234), "D+1,234")
    }

    // MARK: - Body amounts  (억/만 단위, 만 미만 버림)

    func testAmountKoReadmeExamples() {
        XCTAssertEqual(FireFormatter.amountKo(123_450_000), "1억 2,345만원")
        XCTAssertEqual(FireFormatter.amountKo(76_550_000), "7,655만원")
        XCTAssertEqual(FireFormatter.amountKo(200_000_000), "2억원")
    }

    func testAmountKoTruncatesBelowTenThousandWon() {
        XCTAssertEqual(FireFormatter.amountKo(5_000), "0원")
        XCTAssertEqual(FireFormatter.amountKo(9_999), "0원")
        XCTAssertEqual(FireFormatter.amountKo(10_000), "1만원")
        XCTAssertEqual(FireFormatter.amountKo(19_999), "1만원")
        XCTAssertEqual(FireFormatter.amountKo(123_459_999), "1억 2,345만원",
                       "the 9,999원 tail is dropped, never rounded up")
    }

    func testAmountKoZeroAndNegative() {
        XCTAssertEqual(FireFormatter.amountKo(0), "0원")
        XCTAssertEqual(FireFormatter.amountKo(-1), "0원")
        XCTAssertEqual(FireFormatter.amountKo(-123_450_000), "0원")
        XCTAssertEqual(FireFormatter.amountKo(Int.min), "0원", "must not trap on negation")
    }

    func testAmountKoAcrossTheEokBoundary() {
        XCTAssertEqual(FireFormatter.amountKo(99_990_000), "9,999만원")
        XCTAssertEqual(FireFormatter.amountKo(100_000_000), "1억원")
        XCTAssertEqual(FireFormatter.amountKo(100_010_000), "1억 1만원")
        XCTAssertEqual(FireFormatter.amountKo(199_990_000), "1억 9,999만원")
        XCTAssertEqual(FireFormatter.amountKo(1_234_500_000), "12억 3,450만원")
    }

    /// The real recorded portfolio total (docs/api-notes.md § Live verification).
    func testAmountKoOfTheRecordedTotal() {
        XCTAssertEqual(FireFormatter.amountKo(30_371_787), "3,037만원")
    }

    // MARK: - Widget amounts  (`1.2억`, `7,655만`)

    func testAmountCompactReadmeExamples() {
        XCTAssertEqual(FireFormatter.amountCompact(123_450_000), "1.2억")
        XCTAssertEqual(FireFormatter.amountCompact(76_550_000), "7,655만")
    }

    func testAmountCompactTruncatesTowardZeroAtOneDecimal() {
        XCTAssertEqual(FireFormatter.amountCompact(100_000_000), "1.0억")
        XCTAssertEqual(FireFormatter.amountCompact(199_990_000), "1.9억",
                       "one decimal place, truncated — never 2.0억")
        XCTAssertEqual(FireFormatter.amountCompact(200_000_000), "2.0억")
        XCTAssertEqual(FireFormatter.amountCompact(1_234_500_000), "12.3억")
    }

    func testAmountCompactUnderOneEokUsesManUnits() {
        XCTAssertEqual(FireFormatter.amountCompact(99_999_999), "9,999만")
        XCTAssertEqual(FireFormatter.amountCompact(30_371_787), "3,037만")
        XCTAssertEqual(FireFormatter.amountCompact(10_000), "1만")
    }

    func testAmountCompactZeroAndNegative() {
        XCTAssertEqual(FireFormatter.amountCompact(0), "0원")
        XCTAssertEqual(FireFormatter.amountCompact(9_999), "0원")
        XCTAssertEqual(FireFormatter.amountCompact(-76_550_000), "0원")
        XCTAssertEqual(FireFormatter.amountCompact(Int.min), "0원")
    }

    // MARK: - Progress  (`61.2%`, `100.0%`, `103.7%`)

    func testPercentReadmeExamples() {
        XCTAssertEqual(FireFormatter.percent(0.612), "61.2%")
        XCTAssertEqual(FireFormatter.percent(1.0), "100.0%")
        XCTAssertEqual(FireFormatter.percent(1.037), "103.7%")
    }

    func testPercentAlwaysKeepsOneDecimalPlace() {
        XCTAssertEqual(FireFormatter.percent(0.0), "0.0%")
        XCTAssertEqual(FireFormatter.percent(0.5), "50.0%")
        XCTAssertEqual(FireFormatter.percent(0.6172), "61.7%")
        XCTAssertEqual(FireFormatter.percent(2.0), "200.0%")
    }

    func testPercentOfANonFiniteRatioDoesNotProduceNaNText() {
        XCTAssertEqual(FireFormatter.percent(.nan), "0.0%")
        XCTAssertEqual(FireFormatter.percent(.infinity), "0.0%")
    }

    // MARK: - Target date  (`yyyy.MM.dd (E)`)

    func testTargetDateFormat() {
        // 2029-12-31 really is a Monday; README §2.5's "(Wed)" is illustrative, not a real weekday.
        XCTAssertEqual(FireFormatter.targetDate(TestDate.kst("2029-12-31T00:00:00+09:00")),
                       "2029.12.31 (월)")
        // A genuine Wednesday, to pin the "(수)" the README prints.
        XCTAssertEqual(FireFormatter.targetDate(TestDate.kst("2029-12-26T00:00:00+09:00")),
                       "2029.12.26 (수)")
    }

    func testTargetDateZeroPadsMonthAndDay() {
        XCTAssertEqual(FireFormatter.targetDate(TestDate.kst("2027-01-01T00:00:00+09:00")),
                       "2027.01.01 (금)")
        XCTAssertEqual(FireFormatter.targetDate(TestDate.kst("2028-02-29T00:00:00+09:00")),
                       "2028.02.29 (화)")
    }

    func testTargetDateIsRenderedInSeoulNotUTC() {
        // 15:00 UTC is already the next day in Seoul; the date shown must be the Seoul one.
        XCTAssertEqual(FireFormatter.targetDate(TestDate.iso("2029-12-30T15:00:00Z")),
                       "2029.12.31 (월)")
    }

    // MARK: - Refresh timestamp  (`오늘 14:00` / `9.5 18:00`)

    func testRefreshedAtReadmeExamples() {
        let now = TestDate.kst("2026-09-06T20:00:00+09:00")

        XCTAssertEqual(FireFormatter.refreshedAt(TestDate.kst("2026-09-06T14:00:00+09:00"), now: now),
                       "오늘 14:00")
        XCTAssertEqual(FireFormatter.refreshedAt(TestDate.kst("2026-09-05T18:00:00+09:00"), now: now),
                       "9.5 18:00")
    }

    func testRefreshedAtComparesKstCalendarDaysNotElapsedHours() {
        // 10 minutes earlier, but on the previous KST day: not "오늘".
        let now = TestDate.kst("2026-09-06T00:10:00+09:00")
        XCTAssertEqual(FireFormatter.refreshedAt(TestDate.kst("2026-09-05T23:50:00+09:00"), now: now),
                       "9.5 23:50")
        XCTAssertEqual(FireFormatter.refreshedAt(TestDate.kst("2026-09-06T00:00:00+09:00"), now: now),
                       "오늘 00:00")
    }

    func testRefreshedAtZeroPadsTheTimeButNotTheDate() {
        let now = TestDate.kst("2026-09-06T20:00:00+09:00")
        XCTAssertEqual(FireFormatter.refreshedAt(TestDate.kst("2026-09-06T09:05:00+09:00"), now: now),
                       "오늘 09:05")
        XCTAssertEqual(FireFormatter.refreshedAt(TestDate.kst("2026-01-02T07:03:00+09:00"), now: now),
                       "1.2 07:03")
        XCTAssertEqual(FireFormatter.refreshedAt(TestDate.kst("2026-12-25T23:59:00+09:00"), now: now),
                       "12.25 23:59")
    }

    func testRefreshedAtIsAnchoredToSeoul() {
        // Both instants are the same KST day (2026-09-07) even though they straddle midnight UTC.
        let fetched = TestDate.iso("2026-09-06T15:30:00Z")   // KST 09-07 00:30
        let now = TestDate.iso("2026-09-07T09:00:00Z")       // KST 09-07 18:00
        XCTAssertEqual(FireFormatter.refreshedAt(fetched, now: now), "오늘 00:30")
    }

    // MARK: - The rest of the Korean UI vocabulary

    func testRefreshPolicyLabels() {
        XCTAssertEqual(RefreshPolicy.hourly.displayNameKo, "매시간")
        XCTAssertEqual(RefreshPolicy.daily.displayNameKo, "하루 1회")
        XCTAssertEqual(RefreshPolicy.hourly.interval, 3600)
        XCTAssertEqual(RefreshPolicy.daily.interval, 86400)
    }

    func testAccountTypeLabels() {
        XCTAssertEqual(AccountType.brokerage.displayNameKo, "종합매매")
        XCTAssertEqual(AccountType.overseasDerivatives.displayNameKo, "해외파생")
        XCTAssertEqual(AccountType.pensionSavings.displayNameKo, "연금저축")
        XCTAssertEqual(AccountType.reshoringInvestment.displayNameKo, "RIA")
        // api-notes: an enum value the server adds later must not break the screen.
        XCTAssertEqual(AccountType(rawValue: "SOMETHING_NEW").displayNameKo, "SOMETHING_NEW")
    }
}
