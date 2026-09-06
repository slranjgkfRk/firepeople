//
//  AccountSelectStepView.swift
//  firepeople
//
//  온보딩 [3] 계좌 선택 — API 가 준 계좌를 체크박스로. 복수 선택, 기본 전체 선택.
//  각 줄에는 그 계좌의 현재 평가금액(holdings + 환율로 KRW 환산)을 붙인다.
//  화면에 뜨는 숫자는 전부 API 응답에서 온 값이고, 계좌번호는 항상 마스킹된 값만 쓴다.
//

import SwiftUI
import FireCore

struct AccountSelectStepView: View {

    let model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            title: "연결할 계좌를 선택해주세요",
            subtitle: "선택한 계좌들의 평가금액을 합산해서 현재 자산으로 써요. 나중에 설정에서 다시 고를 수 있어요."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if model.isLoadingAccounts {
                    loadingState
                } else if let failure = model.accountsFailure {
                    VStack(alignment: .leading, spacing: 12) {
                        OnboardingFailureBox(failure: failure)
                        Button {
                            model.reloadAccounts()
                        } label: {
                            Label("다시 불러오기", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                } else if model.accounts.isEmpty {
                    emptyState
                } else {
                    accountList
                    summary
                }
            }
        } footer: {
            Button("다음") { model.continueFromAccounts() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(model.selectedAccountSeqs.isEmpty)

            if model.selectedAccountSeqs.isEmpty, !model.accounts.isEmpty {
                Text("계좌를 하나 이상 선택해주세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task { model.prepareAccountStep() }
    }

    // MARK: - States

    private var loadingState: some View {
        OnboardingCard {
            HStack(spacing: 12) {
                ProgressView()
                Text("계좌 목록을 불러오고 있어요…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("조회된 계좌가 없어요")
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "tray")
                }
                Text("토스증권에 계좌가 있는지 확인한 뒤 다시 불러와 주세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    model.reloadAccounts()
                } label: {
                    Label("다시 불러오기", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 2)
            }
        }
    }

    private var accountList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.accounts.enumerated()), id: \.element.accountSeq) { index, account in
                if index > 0 {
                    Divider().padding(.leading, 52)
                }
                row(for: account)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(for account: TossAccount) -> some View {
        let isSelected = model.isSelected(account.accountSeq)
        return Button {
            model.toggleAccount(account.accountSeq)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.accountType.displayNameKo)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(account.maskedAccountNo)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                preview(for: account.accountSeq)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func preview(for accountSeq: Int) -> some View {
        switch model.accountPreviews[accountSeq] {
        case .some(.loaded(let krwTotal, let itemCount)):
            VStack(alignment: .trailing, spacing: 3) {
                Text(FireFormatter.amountKo(krwTotal))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("보유 종목 \(itemCount)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .some(.loading):
            ProgressView()
        case .some(.failed(let message)):
            Text(message)
                .font(.caption)
                .foregroundStyle(Color(uiColor: .systemRed))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140, alignment: .trailing)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let total = model.selectedPreviewTotal {
                HStack {
                    Text("선택한 계좌 합계")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(FireFormatter.amountKo(total))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                }
            }
            if model.hasFailedPreview {
                Button {
                    model.reloadPreviews()
                } label: {
                    Label("평가금액 다시 불러오기", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                }
                .padding(.top, 2)
            }
            if let rate = model.usdKrwRate {
                Text("달러 자산은 토스증권이 준 환율 \(DecimalDisplay.string(rate))원 기준으로 환산했어요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("계좌 선택") {
    AccountSelectStepView(model: OnboardingModel.previewModel())
        .background(Color(uiColor: .systemGroupedBackground))
}
#endif
