//
//  Calendar+Seoul.swift
//  FireCore
//
//  Every date the app shows is anchored to Asia/Seoul, never to the device
//  timezone, so the numbers stay stable when the user is abroad (README §1.1).
//

import Foundation

extension TimeZone {
    /// `Asia/Seoul` (KST, UTC+9, no DST).
    ///
    /// The identifier is part of the IANA database shipped with every Apple
    /// platform and with corelibs-foundation, so the force unwrap cannot fail.
    public static var seoul: TimeZone {
        TimeZone(identifier: "Asia/Seoul")!
    }
}

extension Calendar {
    /// A Gregorian calendar pinned to `Asia/Seoul` and `ko_KR`.
    ///
    /// Deliberately built from scratch instead of `Calendar.current`: the whole
    /// domain layer must be a pure function of its inputs, so no calendar,
    /// timezone or locale preference of the running device may leak in.
    public static var seoul: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .seoul
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }
}
