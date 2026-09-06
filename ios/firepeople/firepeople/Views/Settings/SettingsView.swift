import SwiftUI
import WidgetKit
import FireCore

/// 설정 — every row of README §2.3, in the order the table lists them, plus the two toggles the
/// spec adds elsewhere (§2.4 위젯에 금액 숨기기, §12 예수금 포함) placed next to the row they belong with.
///
/// Presented as a sheet from the main screen's ⚙ button, so it carries its own `NavigationStack`
/// and a 완료 button.
///
/// It reads and writes exactly three things on `AppModel`:
/// `settings` (get/set), `snapshot` (get/set — cleared on reset) and `refresh()`.
struct SettingsView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var isPresentingKeyInput = false
    @State private var isPresentingAccountSelect = false
    @State private var isConfirmingReset = false
    @State private var didFailToWipeKeychain = false

    var body: some View {
        NavigationStack {
            List {
                goalSection
                dataSection
                keySection
                widgetSection
                appSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .sheet(isPresented: $isPresentingKeyInput) { ReenterKeysSheet() }
            .sheet(isPresented: $isPresentingAccountSelect) { ReselectAccountsSheet() }
            .confirmationDialog(
                "API 키를 삭제하고 초기화할까요?",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("삭제하고 초기화", role: .destructive) { performReset() }
                Button("취소", role: .cancel) {}
            } message: {
                Text(Self.resetWarning)
            }
            .alert("키를 모두 지우지 못했습니다", isPresented: $didFailToWipeKeychain) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(
                    """
                    설정과 스냅샷은 삭제했지만 Keychain 항목이 남아 있을 수 있습니다. \
                    앱을 삭제하면 함께 지워집니다.
                    어느 쪽이든 토스증권 WTS 설정 > Open API 에서 키를 직접 폐기해 주세요.
                    """
                )
            }
        }
    }

    // MARK: - 목표

    private var goalSection: some View {
        Section("목표") {
            NavigationLink {
                EditTargetAmountView()
            } label: {
                LabeledContent("목표 금액 수정", value: FireFormatter.amountKo(model.settings.targetAmount))
            }

            NavigationLink {
                EditTargetDateView()
            } label: {
                LabeledContent("FIRE 예정일 수정", value: FireFormatter.targetDate(model.settings.targetDate))
            }
        }
    }

    // MARK: - 데이터

    private var dataSection: some View {
        Section {
            Button {
                isPresentingAccountSelect = true
            } label: {
                LabeledContent("계좌 다시 선택", value: selectedAccountsSummary)
            }
            .tint(.primary)

            Picker("갱신 주기", selection: refreshPolicyBinding) {
                ForEach(RefreshPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayNameKo).tag(policy)
                }
            }

            Toggle("예수금 포함", isOn: includeCashBinding)
        } header: {
            Text("데이터")
        } footer: {
            Text("예수금을 포함하면 주식 평가금액에 계좌의 매수 가능 금액을 더해서 현재 자산을 계산합니다. 켜거나 끄면 바로 다시 불러옵니다.")
        }
    }

    private var selectedAccountsSummary: String {
        let count = model.settings.selectedAccountSeqs.count
        return count == 0 ? "선택 안 됨" : "\(count)개"
    }

    // MARK: - API 키

    private var keySection: some View {
        Section {
            Button("API 키 재입력") { isPresentingKeyInput = true }
                .tint(.primary)

            Button("API 키 삭제 및 초기화", role: .destructive) { isConfirmingReset = true }
        } header: {
            Text("API 키")
        } footer: {
            Text("키는 이 기기의 Keychain에만 저장됩니다. 앱에서 삭제해도 토스증권에서 폐기되지는 않습니다.")
        }
    }

    // MARK: - 위젯

    private var widgetSection: some View {
        Section {
            Toggle("위젯에 금액 숨기기", isOn: hideAmountBinding)

            NavigationLink("위젯 추가 방법") { WidgetGuideView() }
        } header: {
            Text("위젯")
        } footer: {
            Text("켜면 위젯에서 금액 줄이 사라지고 D-day와 진행률만 남습니다.")
        }
    }

    // MARK: - 앱

    private var appSection: some View {
        Section("앱") {
            NavigationLink("정보") { AboutView() }
        }
    }

    // MARK: - Bindings

    /// Every settings edit takes the same path: mutate, persist, then whatever side effect the row
    /// needs. Persisting here (and not only inside `AppModel`) is what makes README §2.3's "즉시
    /// 반영" literally true — the value is in the App Group container before the row animates.
    private func updateSettings(_ mutate: (inout Settings) -> Void) {
        var updated = model.settings
        mutate(&updated)
        guard updated != model.settings else { return }
        model.settings = updated
        SettingsSideEffects.persist(updated)
    }

    private var refreshPolicyBinding: Binding<RefreshPolicy> {
        Binding {
            model.settings.refreshPolicy
        } set: { newValue in
            updateSettings { $0.refreshPolicy = newValue }
            // The widget's reload policy is derived from this, so its timeline has to be rebuilt.
            SettingsSideEffects.reloadWidget()
        }
    }

    private var hideAmountBinding: Binding<Bool> {
        Binding {
            model.settings.hideAmountInWidget
        } set: { newValue in
            updateSettings { $0.hideAmountInWidget = newValue }
            SettingsSideEffects.reloadWidget()
        }
    }

    private var includeCashBinding: Binding<Bool> {
        Binding {
            model.settings.includeCash
        } set: { newValue in
            updateSettings { $0.includeCash = newValue }
            // Turning it on adds 예수금 to the total, turning it off removes it. Either way the
            // stored snapshot no longer matches the setting, so pull a fresh one; a failed refresh
            // keeps the previous numbers (README §2.6).
            Task { @MainActor in
                await model.refresh()
                SettingsSideEffects.reloadWidget()
            }
        }
    }

    // MARK: - Reset

    /// README §2.3 마지막 행 + §7: wipe the Keychain, the settings and the snapshot, then drop back
    /// into onboarding. Deleting locally does **not** revoke anything on Toss's side — the dialog
    /// says so, because a leaked key stays usable until the user revokes it in the WTS.
    private static let resetWarning = """
        이 기기에 저장된 API 키와 설정, 마지막 스냅샷을 모두 지우고 온보딩부터 다시 시작합니다.

        앱에서 지워도 키가 폐기되는 것은 아닙니다. 토스증권 WTS 설정 > Open API 에서 발급한 키를 \
        직접 폐기해 주세요.
        """

    private func performReset() {
        var keychainWiped = true
        #if canImport(Security)
        do {
            try KeychainStore().clearAll()
        } catch {
            // Never surface or log the underlying item — only that the wipe failed.
            keychainWiped = false
        }
        #endif

        SettingsSideEffects.clearPersistedState()
        RecentErrorLog.shared.clear()

        model.snapshot = nil
        model.settings = .fresh
        SettingsSideEffects.reloadWidget()

        if keychainWiped {
            dismiss()
        } else {
            didFailToWipeKeychain = true
        }
    }
}

// MARK: - Onboarding screens reused as sheets

/// README §2.3 "API 키 재입력 — 온보딩 [2] 재사용".
///
/// 온보딩 [2] 화면을 그대로 띄운다. 연결 테스트가 성공하면 `OnboardingModel` 이 그 자리에서
/// Keychain 에 새 키를 저장하고 다음 단계로 넘어가는데, 여기서는 그 단계 전환을 "성공했다"는
/// 신호로만 쓰고 시트를 닫는다.
private struct ReenterKeysSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var onboarding = OnboardingModel()

    var body: some View {
        NavigationStack {
            KeyInputStepView(model: onboarding)
                .navigationTitle("API 키 재입력")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
        .task { onboarding.prepareForSettingsReuse() }
        .onChange(of: onboarding.step) { _, step in
            guard step > .keyInput else { return }
            let clientId = onboarding.clientId
            let clientSecret = onboarding.clientSecret
            dismiss()
            Task {
                // 앱이 들고 있는 클라이언트에도 새 키를 알려 준다. 이전 키로 받은 토큰이
                // 액터 안에 캐시돼 있으면 새 키가 반영되지 않는다.
                try? await model.saveCredentials(clientId: clientId, clientSecret: clientSecret)
                await model.refresh(force: true)
            }
        }
    }
}

/// README §2.3 "계좌 다시 선택 — 온보딩 [3] 재사용".
///
/// 현재 선택을 미리 채워 두고 온보딩 [3] 화면을 띄운다. "다음" 을 누르면 그 단계가 [4] 로
/// 넘어가는데, 여기서는 그것을 확정 신호로 받아 설정에 반영하고 닫는다.
private struct ReselectAccountsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var onboarding = OnboardingModel()

    var body: some View {
        NavigationStack {
            AccountSelectStepView(model: onboarding)
                .navigationTitle("계좌 다시 선택")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
        .task { onboarding.prepareForSettingsReuse(preselecting: model.settings.selectedAccountSeqs) }
        .onChange(of: onboarding.step) { _, step in
            guard step > .accountSelect else { return }
            let selected = onboarding.selectedAccountSeqs.sorted()
            dismiss()
            guard !selected.isEmpty else { return }
            model.setSelectedAccounts(selected)
            Task { await model.refresh(force: true) }
        }
    }
}

// MARK: - Side effects

/// The two things a settings edit does beyond changing `AppModel`: write through to the App Group
/// container, and ask WidgetKit to rebuild the timeline.
///
/// `FireCore` stays WidgetKit-free by design, so the reload lives here, on the app side.
enum SettingsSideEffects {

    /// Writes `settings` to the shared container. A no-op when the App Group is unavailable
    /// (previews, an unentitled simulator build) — `AppGroup.defaults` is documented as optional.
    static func persist(_ settings: Settings) {
        guard let defaults = AppGroup.defaults else { return }
        try? UserDefaultsSettingsStore(defaults: defaults).save(settings)
    }

    /// Removes the stored settings and snapshot. Keychain items are wiped separately.
    static func clearPersistedState() {
        guard let defaults = AppGroup.defaults else { return }
        try? UserDefaultsSettingsStore(defaults: defaults).clear()
        try? UserDefaultsSnapshotStore(defaults: defaults).clear()
    }

    static func reloadWidget() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
