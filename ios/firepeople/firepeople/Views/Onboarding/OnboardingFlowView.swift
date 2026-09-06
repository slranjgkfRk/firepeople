//
//  OnboardingFlowView.swift
//  firepeople
//
//  README §2.1 온보딩 컨테이너. 5단계 + 뒤로가기 + 이어서 진행.
//
//  앱 셸에서 쓰는 법 (셋 중 아무거나):
//      OnboardingFlowView()                                  // 스스로 저장소를 만든다
//      OnboardingFlowView { appModel.onboardingDidFinish() }  // 완료 시 라우팅 콜백
//      OnboardingFlowView(model: OnboardingModel(settingsStore: ..., onCompleted: ...))
//  완료 시 Settings.onboardingCompleted = true 로 저장하고 `.fireOnboardingCompleted` 알림도 던진다.
//

import SwiftUI
import FireCore

struct OnboardingFlowView: View {

    @State private var model: OnboardingModel

    init(onCompleted: (@MainActor () -> Void)? = nil) {
        _model = State(initialValue: OnboardingModel(onCompleted: onCompleted))
    }

    init(model: OnboardingModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .animation(.easeInOut(duration: 0.22), value: model.step)
        .task { model.start() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .tint(.primary)
            .opacity(model.canGoBack ? 1 : 0)
            .disabled(!model.canGoBack)
            .accessibilityLabel("이전 단계")

            stepIndicator

            Text("\(model.step.displayIndex) / \(OnboardingStep.stepCount)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
    }

    private var stepIndicator: some View {
        HStack(spacing: 4) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step <= model.step ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                    .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("\(OnboardingStep.stepCount)단계 중 \(model.step.displayIndex)단계")
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .intro:
            IntroStepView(model: model)
        case .keyInput:
            KeyInputStepView(model: model)
        case .accountSelect:
            AccountSelectStepView(model: model)
        case .goalInput:
            GoalInputStepView(model: model)
        case .done:
            OnboardingDoneStepView(model: model)
        }
    }
}

// MARK: - [5] 완료

/// 설정 저장 → 첫 스냅샷 → 위젯 갱신 → 메인. 실제 작업은 모델이 한다.
struct OnboardingDoneStepView: View {

    let model: OnboardingModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            if let failure = model.finishFailure {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("설정을 저장하지 못했어요")
                    .font(.title3.bold())
                OnboardingFailureBox(failure: failure)
                    .padding(.horizontal, 20)
                Button("다시 시도") { model.retryFinishing() }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .padding(.horizontal, 20)
            } else if model.didComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                VStack(spacing: 8) {
                    Text("준비 끝!")
                        .font(.title2.bold())
                    Text("이제 FIRE까지 남은 날을 세어볼게요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("시작하기") { model.openMainScreen() }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .padding(.horizontal, 20)
            } else {
                ProgressView()
                    .controlSize(.large)
                VStack(spacing: 8) {
                    Text("설정을 저장하고 있어요")
                        .font(.title3.bold())
                    Text("첫 평가금액을 불러오는 중이에요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(20)
        .task { model.startFinishing() }
    }
}

// MARK: - Shared onboarding UI

/// 모든 단계가 쓰는 뼈대: 제목/설명 + 스크롤 본문 + 하단 고정 버튼.
struct OnboardingStepScaffold<Content: View, Footer: View>: View {

    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.title2.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    content()
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 12) {
                footer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .top) { Divider() }
        }
    }
}

/// 카드 배경. 다크 모드는 시스템 시맨틱 컬러로 자동 대응한다.
struct OnboardingCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        // ButtonStyle 자체는 뷰 계층에 없어서 @Environment 가 갱신되지 않는다. 실제 라벨은 뷰로 감싼다.
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(isEnabled ? Color.white : Color(uiColor: .tertiaryLabel))
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isEnabled ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                )
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// 실패 표시. 한 줄 안내 + API 가 준 코드/메시지 원문 (README §2.1 "에러 코드 + 메시지 그대로").
struct OnboardingFailureBox: View {
    let failure: OnboardingFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(failure.message)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: failure.needsIPRegistration ? "network.badge.shield.half.filled" : "exclamationmark.circle.fill")
            }
            .foregroundStyle(Color(uiColor: .systemRed))

            if failure.needsIPRegistration {
                Text("토스증권 WTS의 설정 → Open API → 허용 IP 관리에서 지금 쓰는 네트워크의 공인 IP를 등록한 뒤 다시 시도해주세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let detail = failure.detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .systemRed).opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 번호가 붙은 안내 한 줄.
struct OnboardingNumberedRow: View {
    let number: Int
    let text: String
    var highlight: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.bold().monospacedDigit())
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let highlight {
                    Text(highlight)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("온보딩") {
    OnboardingFlowView(model: OnboardingModel.previewModel())
}
#endif
