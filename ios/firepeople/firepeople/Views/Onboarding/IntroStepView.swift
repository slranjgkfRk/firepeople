//
//  IntroStepView.swift
//  firepeople
//
//  온보딩 [1] 안내 — 토스증권 Open API 키가 왜 필요하고 어디서 받는지.
//  허용 IP 등록은 선택이 아니라 필수다. 등록하지 않으면 키가 맞아도 모든 호출이 403 이다
//  (docs/api-notes.md § Credentials, README §3.1).
//

import SwiftUI

struct IntroStepView: View {

    let model: OnboardingModel

    private static let docsURL = URL(string: "https://developers.tossinvest.com")

    var body: some View {
        OnboardingStepScaffold(
            title: "토스증권 Open API 키가 필요해요",
            subtitle: "이 앱은 선택한 계좌의 평가금액만 읽어서 FIRE까지 남은 날과 진행률을 보여줘요."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                issuanceCard
                ipCard
                safetyCard
            }
        } footer: {
            Button("시작하기") { model.continueFromIntro() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
        }
    }

    // MARK: - Cards

    private var issuanceCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader(icon: "key.fill", title: "키 발급 방법")

                OnboardingNumberedRow(number: 1,
                                      text: "토스증권 WTS(웹 트레이딩)에 로그인하세요.")
                OnboardingNumberedRow(number: 2,
                                      text: "설정 → Open API 로 들어가 키를 발급받으세요.",
                                      highlight: "client_id 와 client_secret 두 개를 받게 돼요.")
                OnboardingNumberedRow(number: 3,
                                      text: "설정 → Open API → 허용 IP 관리 에서 지금 인터넷에 연결된 공인 IP를 등록하세요.",
                                      highlight: "이 단계를 건너뛰면 연결 테스트가 반드시 실패해요.")

                Text("발급은 심사 대기 없이 바로 끝나요. 두 값은 발급 화면에서 복사해 두었다가 다음 단계에 붙여넣으면 돼요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = Self.docsURL {
                    Link(destination: url) {
                        Label("토스증권 Open API 문서 열기", systemImage: "arrow.up.right.square")
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
        }
    }

    private var ipCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("허용 IP 등록은 필수예요")
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "network.badge.shield.half.filled")
                }
                .foregroundStyle(Color(uiColor: .systemOrange))

                Text("등록하지 않은 IP에서 호출하면 키가 아무리 정확해도 403으로 거절돼요. 와이파이나 통신망이 바뀌어 공인 IP가 달라지면, 새 IP를 다시 등록해야 연결돼요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var safetyCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader(icon: "lock.shield.fill", title: "이 앱이 하는 일과 안 하는 일")

                bullet("계좌 목록·평가금액·환율만 조회해요. 읽기 전용 API만 사용합니다.")
                bullet("주문·정정·취소 기능은 코드에 아예 들어 있지 않아요.")
                bullet("입력한 키는 기기의 Keychain 에만 저장되고, 서버로 보내지 않아요.")
            }
        }
    }

    // MARK: - Pieces

    private func cardHeader(icon: String, title: String) -> some View {
        Label {
            Text(title).font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(.primary)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("안내") {
    IntroStepView(model: OnboardingModel.previewModel())
        .background(Color(uiColor: .systemGroupedBackground))
}
#endif
