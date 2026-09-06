//
//  KeyInputStepView.swift
//  firepeople
//
//  온보딩 [2] 키 입력 — client_id / client_secret 을 secure text 로 받고 [연결 테스트].
//  성공하면 그 자리에서 Keychain 에 저장하고 계좌 선택으로 넘어간다.
//  실패하면 API 가 준 코드와 메시지를 그대로 보여주고, 어느 필드가 틀렸는지 알려주면 그 필드를 가리킨다.
//

import SwiftUI

struct KeyInputStepView: View {

    @Bindable var model: OnboardingModel
    @FocusState private var focusedField: CredentialField?

    var body: some View {
        OnboardingStepScaffold(
            title: "API 키를 입력해주세요",
            subtitle: "토스증권 WTS의 설정 → Open API 에서 발급받은 두 값이에요. 붙여넣기도 돼요."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if model.hasStoredCredentials {
                    storedKeyNotice
                }

                OnboardingCard {
                    VStack(alignment: .leading, spacing: 18) {
                        field(.clientId,
                              title: "client_id",
                              hint: "tsck_live_ 로 시작하는 값",
                              text: $model.clientId,
                              submitLabel: .next)
                        Divider()
                        field(.clientSecret,
                              title: "client_secret",
                              hint: "tssk_live_ 로 시작하는 값",
                              text: $model.clientSecret,
                              submitLabel: .go)
                    }
                }

                if let failure = model.keyFailure {
                    OnboardingFailureBox(failure: failure)
                }

                Text("입력한 키는 이 기기의 Keychain 에만 저장돼요. 화면 캡처나 로그에도 남지 않아요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button {
                focusedField = nil
                Task { await model.testConnection() }
            } label: {
                if model.isTestingConnection {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("연결 확인 중…")
                    }
                } else {
                    Text("연결 테스트")
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(!model.canTestConnection)
        }
        .onChange(of: model.keyFailure) { _, failure in
            if let field = failure?.field { focusedField = field }
        }
    }

    // MARK: - Field

    private func field(_ field: CredentialField,
                       title: String,
                       hint: String,
                       text: Binding<String>,
                       submitLabel: SubmitLabel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.footnote.weight(.semibold).monospaced())
                if isFlagged(field) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: .systemRed))
                }
            }
            .foregroundStyle(isFlagged(field) ? Color(uiColor: .systemRed) : .secondary)

            SecureField(hint, text: text)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
                .focused($focusedField, equals: field)
                .disabled(model.isTestingConnection)
                .onSubmit {
                    switch field {
                    case .clientId:
                        focusedField = .clientSecret
                    case .clientSecret:
                        focusedField = nil
                        if model.canTestConnection {
                            Task { await model.testConnection() }
                        }
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(borderColor(for: field), lineWidth: isFlagged(field) ? 1.5 : 1)
                }

            if isFlagged(field) {
                Text("이 값이 맞지 않다고 응답했어요. 다시 붙여넣어 주세요.")
                    .font(.caption)
                    .foregroundStyle(Color(uiColor: .systemRed))
            }
        }
    }

    private func isFlagged(_ field: CredentialField) -> Bool {
        model.keyFailure?.field == field
    }

    private func borderColor(for field: CredentialField) -> Color {
        if isFlagged(field) { return Color(uiColor: .systemRed) }
        if focusedField == field { return Color.accentColor }
        return .clear
    }

    // MARK: - Pieces

    private var storedKeyNotice: some View {
        Label {
            Text("이미 저장된 키가 있어요. 새로 입력해서 연결 테스트에 성공하면 저장된 키를 교체해요.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield.fill")
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("키 입력") {
    KeyInputStepView(model: OnboardingModel.previewModel())
        .background(Color(uiColor: .systemGroupedBackground))
}
#endif
