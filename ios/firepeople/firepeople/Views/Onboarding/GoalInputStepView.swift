//
//  GoalInputStepView.swift
//  firepeople
//
//  온보딩 [4] 목표 입력 — FIRE 목표 금액(원 단위, 천 단위 콤마 자동)과 FIRE 예정일(오늘 이후만).
//  고르는 즉시 아래에서 D-day 가 살아 움직인다. 이 앱이 결국 보여줄 숫자를 미리 보는 화면이다.
//

import SwiftUI
import FireCore

struct GoalInputStepView: View {

    let model: OnboardingModel
    @FocusState private var amountFocused: Bool

    private static let quickAdds: [(label: String, value: Int)] = [
        ("+1,000만", 10_000_000),
        ("+1억", 100_000_000),
        ("+10억", 1_000_000_000)
    ]

    var body: some View {
        OnboardingStepScaffold(
            title: "FIRE 목표를 정해주세요",
            subtitle: "목표 금액과 예정일 두 가지만 있으면 돼요. 나중에 설정에서 언제든 바꿀 수 있어요."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                amountCard
                dateCard
                dDayCard
            }
        } footer: {
            Button("완료") {
                amountFocused = false
                model.continueFromGoal()
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(!model.canFinishGoal)

            if !model.canFinishGoal {
                Text("목표 금액을 입력해주세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 목표 금액

    private var amountCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("FIRE 목표 금액")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("0", text: amountBinding)
                        .keyboardType(.numberPad)
                        .font(.title2.bold().monospacedDigit())
                        .focused($amountFocused)
                        .multilineTextAlignment(.trailing)
                    Text("원")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(amountFocused ? Color.accentColor : .clear, lineWidth: 1)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("입력 완료") { amountFocused = false }
                    }
                }

                HStack(spacing: 8) {
                    ForEach(Self.quickAdds, id: \.value) { quickAdd in
                        Button(quickAdd.label) {
                            model.addToTargetAmount(quickAdd.value)
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                    Spacer(minLength: 0)
                }

                if model.targetAmount > 0 {
                    Text(FireFormatter.amountKo(model.targetAmount))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var amountBinding: Binding<String> {
        Binding(get: { model.targetAmountText },
                set: { model.setTargetAmountText($0) })
    }

    // MARK: - 예정일

    private var dateCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("FIRE 예정일")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                DatePicker("FIRE 예정일",
                           selection: dateBinding,
                           in: model.minimumTargetDate...,
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.calendar, .seoul)
                    .environment(\.timeZone, .seoul)
                    .tint(Color.accentColor)

                Text("오늘 이후 날짜만 고를 수 있어요. 날짜는 한국 시간 자정을 기준으로 세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { model.targetDate },
                set: { model.setTargetDate($0) })
    }

    // MARK: - 미리보기

    private var dDayCard: some View {
        OnboardingCard(padding: 20) {
            VStack(spacing: 8) {
                Text("FIRE까지")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(FireFormatter.dDay(model.dDayPreview()))
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.targetDate)

                Text(FireFormatter.targetDate(model.targetDate))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

#if DEBUG
#Preview("목표 입력") {
    GoalInputStepView(model: OnboardingModel.previewModel())
        .background(Color(uiColor: .systemGroupedBackground))
}
#endif
