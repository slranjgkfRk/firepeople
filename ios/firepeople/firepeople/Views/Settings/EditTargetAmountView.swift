import SwiftUI
import FireCore

/// 설정 › 목표 금액 수정 — README §2.3 "즉시 반영, 위젯 갱신".
///
/// Digits only, thousands commas inserted as you type (README §2.1 [4]), saved on every accepted
/// keystroke. The widget reload is held until the screen closes: the value is already persisted, and
/// WidgetKit's reload budget is not something to spend once per digit.
struct EditTargetAmountView: View {

    @Environment(AppModel.self) private var model

    @State private var text = ""
    @State private var amountAtEntry: Int?
    @FocusState private var isFieldFocused: Bool

    /// Nine hundred trillion won is comfortably past anything real and keeps `Int` arithmetic sane.
    private static let maximumDigits = 15

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("0", text: $text)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.title2, design: .rounded).monospacedDigit())
                        .focused($isFieldFocused)
                        .accessibilityLabel("FIRE 목표 금액")

                    Text("원")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("FIRE 목표 금액")
            } footer: {
                Text("입력하는 즉시 저장됩니다. 화면을 나가면 위젯도 갱신됩니다.")
            }

            Section("미리보기") {
                LabeledContent("목표 금액", value: FireFormatter.amountKo(currentAmount))
                LabeledContent("현재 진행률", value: progressText)
                LabeledContent("남은 금액", value: remainingText)
            }
        }
        .navigationTitle("목표 금액 수정")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if amountAtEntry == nil {
                amountAtEntry = model.settings.targetAmount
                text = Self.formatted(model.settings.targetAmount)
            }
            isFieldFocused = true
        }
        .onChange(of: text) { _, newValue in
            apply(newValue)
        }
        .onDisappear {
            if amountAtEntry != model.settings.targetAmount {
                SettingsSideEffects.reloadWidget()
            }
        }
    }

    // MARK: - Editing

    private var currentAmount: Int {
        Int(text.filter(\.isNumber)) ?? 0
    }

    /// Normalizes what the user typed (digits only, capped, re-grouped) and saves it immediately.
    private func apply(_ raw: String) {
        let digits = String(raw.filter(\.isNumber).prefix(Self.maximumDigits))
        let amount = Int(digits) ?? 0
        let normalized = digits.isEmpty ? "" : Self.formatted(amount)

        if normalized != text {
            // Assigning re-enters `onChange`, but the second pass is already normalized and stops.
            text = normalized
        }

        guard amount != model.settings.targetAmount else { return }
        var updated = model.settings
        updated.targetAmount = amount
        model.settings = updated
        SettingsSideEffects.persist(updated)
    }

    // MARK: - Preview rows

    /// Reads the snapshot directly rather than a derived state so an empty target (0) still renders
    /// something sensible while the user is mid-edit.
    private var progressText: String {
        guard let assets = model.snapshot?.currentAssets else { return "--%" }
        guard currentAmount > 0 else { return "--%" }
        return FireFormatter.percent(
            FireCalculator.progress(currentAssets: assets, targetAmount: currentAmount)
        )
    }

    private var remainingText: String {
        guard let assets = model.snapshot?.currentAssets else { return "-" }
        let remaining = FireCalculator.remaining(currentAssets: assets, targetAmount: currentAmount)
        return remaining == 0 && currentAmount > 0 ? "목표 달성" : FireFormatter.amountKo(remaining)
    }

    // MARK: - Formatting

    /// `123450000` → `"123,450,000"`. Plain grouping, not the 억/만 body format — this is the field
    /// the user is typing into, and README §2.1 asks for "천 단위 콤마 자동".
    private static func formatted(_ amount: Int) -> String {
        guard amount > 0 else { return "" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: amount)) ?? String(amount)
    }
}
