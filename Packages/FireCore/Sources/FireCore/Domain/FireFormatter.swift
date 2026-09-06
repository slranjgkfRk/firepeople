//
//  FireFormatter.swift
//  FireCore
//
//  README §2.5 숫자 표기 규칙 — the single place every number in the app and the
//  widget is turned into Korean text.
//
//  | 값          | 표기                               | 예                              |
//  | D-day      | `D-` + 천 단위 콤마                   | `D-1,234`, `D-DAY`, `D+12`     |
//  | 금액 (본문)    | 억/만 단위, 만 미만 버림                  | `1억 2,345만원`, `7,655만원`, `2억원` |
//  | 금액 (위젯 축약) | 소수점 한 자리 억 단위, 1억 미만은 만 단위        | `1.2억`, `7,655만`               |
//  | 진행률        | 소수점 한 자리                         | `61.2%`, `100.0%`, `103.7%`    |
//  | 날짜         | `yyyy.MM.dd (E)`                  | `2029.12.31 (수)`               |
//  | 갱신 시각      | 오늘이면 `오늘 HH:mm`, 아니면 `M.d HH:mm`  | `오늘 14:00`, `9.5 18:00`        |
//
//  Digits are assembled by hand rather than by `NumberFormatter`/`DateFormatter`
//  so the output is byte-identical regardless of the device locale (a ko_KR user
//  with Arabic numerals disabled, a test host in another timezone, …) and so
//  nothing here is a non-`Sendable` shared object.
//

import Foundation

public enum FireFormatter: Sendable {

    // MARK: - D-Day

    /// `0` → `"D-DAY"`, `1234` → `"D-1,234"`, `-12` → `"D+12"`.
    public static func dDay(_ days: Int) -> String {
        if days == 0 { return "D-DAY" }
        let sign = days > 0 ? "-" : "+"
        return "D\(sign)\(grouped(days.magnitude))"
    }

    // MARK: - Amounts

    /// 본문 금액. 만 미만은 버린다.
    ///
    /// `123450000` → `"1억 2,345만원"`, `76550000` → `"7,655만원"`,
    /// `200000000` → `"2억원"`, `5000` → `"0원"`, `0` → `"0원"`.
    /// A negative amount is not a thing the app can own, so it clamps to `"0원"`.
    public static func amountKo(_ won: Int) -> String {
        let man = max(won, 0) / 10_000          // 만 미만 버림
        if man == 0 { return "0원" }

        let eok = man / 10_000
        let rest = man % 10_000

        if eok > 0 && rest > 0 { return "\(eok)억 \(grouped(UInt(rest)))만원" }
        if eok > 0 { return "\(eok)억원" }
        return "\(grouped(UInt(man)))만원"
    }

    /// 위젯 축약 금액.
    ///
    /// `123450000` → `"1.2억"` (버림), `200000000` → `"2.0억"`,
    /// `76550000` → `"7,655만"`, `0` → `"0원"`.
    public static func amountCompact(_ won: Int) -> String {
        let clamped = max(won, 0)
        if clamped >= 100_000_000 {
            let tenthsOfEok = clamped / 10_000_000     // truncated toward zero
            return "\(tenthsOfEok / 10).\(tenthsOfEok % 10)억"
        }
        let man = clamped / 10_000
        if man == 0 { return "0원" }
        return "\(grouped(UInt(man)))만"
    }

    // MARK: - Progress

    /// 진행률, 소수점 한 자리. `0.612` → `"61.2%"`, `1.0` → `"100.0%"`,
    /// `1.037` → `"103.7%"`, `0.6125` → `"61.3%"` (half-up, not banker's rounding).
    public static func percent(_ progress: Double) -> String {
        guard progress.isFinite else { return "0.0%" }

        // One decimal place of a percentage == tenths of a percent == ratio × 1000.
        let tenths = (progress * 1000).rounded(.toNearestOrAwayFromZero)
        let bounded = Int(min(max(tenths, -1e15), 1e15))

        let sign = bounded < 0 ? "-" : ""
        let magnitude = bounded.magnitude
        return "\(sign)\(magnitude / 10).\(magnitude % 10)%"
    }

    // MARK: - Dates

    /// `"2029.12.31 (수)"` — Gregorian, Asia/Seoul, Korean one-letter weekday.
    public static func targetDate(_ date: Date) -> String {
        let calendar = Calendar.seoul
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        return "\(zeroPadded(year, width: 4)).\(zeroPadded(month, width: 2)).\(zeroPadded(day, width: 2)) (\(weekdaySymbolKo(parts.weekday)))"
    }

    /// 마지막 갱신 시각. Same KST calendar day as `now` → `"오늘 14:00"`,
    /// otherwise `"9.5 18:00"`. The comparison is by KST calendar day, never by
    /// elapsed hours, so 23:50 → 00:10 is "어제" and not "오늘".
    public static func refreshedAt(_ date: Date, now: Date) -> String {
        let calendar = Calendar.seoul
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let time = "\(zeroPadded(parts.hour ?? 0, width: 2)):\(zeroPadded(parts.minute ?? 0, width: 2))"

        if calendar.isDate(date, inSameDayAs: now) { return "오늘 \(time)" }
        return "\(parts.month ?? 1).\(parts.day ?? 1) \(time)"
    }

    // MARK: - Digit plumbing

    /// Thousands separator every three digits, e.g. `1234` → `"1,234"`.
    /// Takes a magnitude so `Int.min` cannot trap on negation.
    private static func grouped(_ magnitude: UInt) -> String {
        let digits = String(magnitude)
        guard digits.count > 3 else { return digits }

        var out = ""
        out.reserveCapacity(digits.count + (digits.count - 1) / 3)
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return out
    }

    private static func zeroPadded(_ value: Int, width: Int) -> String {
        let digits = String(value.magnitude)
        let padding = width - digits.count
        let body = padding > 0 ? String(repeating: "0", count: padding) + digits : digits
        return value < 0 ? "-" + body : body
    }

    /// `Calendar` weekday is 1-based starting at Sunday.
    private static func weekdaySymbolKo(_ weekday: Int?) -> String {
        let symbols = ["일", "월", "화", "수", "목", "금", "토"]
        let index = (weekday ?? 1) - 1
        guard symbols.indices.contains(index) else { return symbols[0] }
        return symbols[index]
    }
}
