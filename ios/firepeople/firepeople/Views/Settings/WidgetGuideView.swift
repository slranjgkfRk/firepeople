import SwiftUI

/// 설정 › 위젯 추가 방법 — README §2.3 "텍스트 안내".
///
/// Plain text, no screenshots: the steps are short and Apple moves the artwork around every
/// release, but the gesture has not changed since iOS 14.
struct WidgetGuideView: View {

    private static let homeScreenSteps = [
        "홈 화면의 빈 곳을 길게 누릅니다. 아이콘이 흔들리기 시작합니다.",
        "왼쪽 위 편집 버튼(또는 ＋)을 누릅니다.",
        "‘위젯’을 고른 뒤 검색창에 FIRE D-Day 를 입력합니다.",
        "작은 크기 또는 중간 크기를 고르고 ‘위젯 추가’를 누릅니다.",
        "원하는 자리로 끌어다 놓고 ‘완료’를 누릅니다."
    ]

    private static let lockScreenSteps = [
        "잠금 화면을 길게 누른 뒤 ‘사용자화’를 누릅니다.",
        "‘잠금 화면’을 고르고 시계 아래(또는 위)의 위젯 영역을 누릅니다.",
        "목록에서 FIRE D-Day 를 고릅니다. 원형 게이지와 가로형 두 가지가 있습니다.",
        "‘완료’를 눌러 저장합니다."
    ]

    private static let notes = [
        "위젯을 탭하면 앱 메인 화면이 열립니다.",
        "D-day 숫자는 네트워크가 없어도 매일 자정(한국 시간)에 하루씩 줄어듭니다.",
        "금액과 진행률은 설정한 갱신 주기에 맞춰 새로 불러옵니다. iOS가 갱신 시점을 조절하기 때문에 정확히 그 시각은 아닐 수 있습니다.",
        "금액을 보이고 싶지 않으면 설정에서 ‘위젯에 금액 숨기기’를 켜세요."
    ]

    var body: some View {
        List {
            Section("홈 화면에 추가하기") {
                ForEach(Array(Self.homeScreenSteps.enumerated()), id: \.offset) { index, step in
                    StepRow(number: index + 1, text: step)
                }
            }

            Section("잠금 화면에 추가하기") {
                ForEach(Array(Self.lockScreenSteps.enumerated()), id: \.offset) { index, step in
                    StepRow(number: index + 1, text: step)
                }
            }

            Section("알아두면 좋은 점") {
                ForEach(Self.notes, id: \.self) { note in
                    Label {
                        Text(note)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("위젯 추가 방법")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A numbered step. The number sits in a fixed-width circle so the text of every row lines up.
private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.background)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.secondary))
                .accessibilityHidden(true)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number)단계. \(text)")
    }
}

#Preview {
    NavigationStack {
        WidgetGuideView()
    }
}
