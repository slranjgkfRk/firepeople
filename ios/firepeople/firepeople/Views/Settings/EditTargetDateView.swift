import SwiftUI
import FireCore

/// 설정 › FIRE 예정일 수정 — README §2.3 "즉시 반영, 위젯 갱신".
///
/// The picker runs in the device's calendar, but the stored date is a **KST** midnight (README
/// §1.1: the D-day must not wobble when the phone travels). The two are bridged by carrying only
/// the year/month/day across and rebuilding the instant at noon Seoul time, which keeps the day
/// identical for every device time zone — a straight `Date` hand-off would land on the previous day
/// anywhere east of Seoul.
struct EditTargetDateView: View {

    @Environment(AppModel.self) private var model

    @State private var pickedDate = Date()
    @State private var dateAtEntry: Date?

    var body: some View {
        Form {
            Section {
                DatePicker(
                    "FIRE 예정일",
                    selection: $pickedDate,
                    in: earliestSelectableDate...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "ko_KR"))
            } footer: {
                Text("고르는 즉시 저장됩니다. 화면을 나가면 위젯도 갱신됩니다.")
            }

            Section("미리보기") {
                LabeledContent("예정일", value: FireFormatter.targetDate(seoulDate(from: pickedDate)))
                LabeledContent("남은 날짜", value: FireFormatter.dDay(dDayPreview))
            }
        }
        .navigationTitle("FIRE 예정일 수정")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if dateAtEntry == nil {
                dateAtEntry = model.settings.targetDate
                pickedDate = max(deviceDate(from: model.settings.targetDate), earliestSelectableDate)
            }
        }
        .onChange(of: pickedDate) { _, newValue in
            apply(newValue)
        }
        .onDisappear {
            if dateAtEntry != model.settings.targetDate {
                SettingsSideEffects.reloadWidget()
            }
        }
    }

    // MARK: - Editing

    /// Today is selectable — that is the `D-DAY` state (README §2.6). Anything earlier is not: a
    /// target date already in the past is exactly what this screen exists to fix.
    private var earliestSelectableDate: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var dDayPreview: Int {
        FireCalculator.dDay(targetDate: seoulDate(from: pickedDate), now: Date())
    }

    private func apply(_ newValue: Date) {
        let normalized = FireCalculator.kstMidnight(of: seoulDate(from: newValue))
        guard normalized != model.settings.targetDate else { return }
        var updated = model.settings
        updated.targetDate = normalized
        model.settings = updated
        SettingsSideEffects.persist(updated)
    }

    // MARK: - Time-zone bridging

    /// The picked calendar day, as an instant at 12:00 Asia/Seoul. `Settings.targetDate` snaps that
    /// to the KST midnight of the same day; noon leaves room for the snap in either direction.
    private func seoulDate(from deviceDate: Date) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: deviceDate)
        components.hour = 12
        return Calendar.seoul.date(from: components) ?? deviceDate
    }

    /// The inverse: the stored KST day, as an instant the device's own calendar reads as that day.
    private func deviceDate(from seoulDate: Date) -> Date {
        var components = Calendar.seoul.dateComponents([.year, .month, .day], from: seoulDate)
        components.hour = 12
        return Calendar.current.date(from: components) ?? seoulDate
    }
}
