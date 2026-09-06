import SwiftUI
import FireCore

/// 설정 › 정보 — README §2.3 "버전, '읽기 전용 API만 사용합니다' 명시" and README §3.5's
/// "설정 > 정보 > 최근 오류" list.
///
/// Deliberately model-free: it reads the bundle and the local error log, nothing else.
struct AboutView: View {

    @State private var errors: [RecentError] = []
    @State private var isConfirmingErrorClear = false

    var body: some View {
        List {
            Section("앱") {
                LabeledContent("이름", value: "FIRE D-Day")
                LabeledContent("버전", value: Self.versionText)
            }

            readOnlySection
            securitySection
            recentErrorsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("정보")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { errors = RecentErrorLog.shared.recent() }
        .confirmationDialog(
            "최근 오류 기록을 지울까요?",
            isPresented: $isConfirmingErrorClear,
            titleVisibility: .visible
        ) {
            Button("지우기", role: .destructive) {
                RecentErrorLog.shared.clear()
                errors = []
            }
            Button("취소", role: .cancel) {}
        }
    }

    // MARK: - 읽기 전용

    private var readOnlySection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
                Text("읽기 전용 API만 사용합니다")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 2)

            ForEach(Self.readOnlyFacts, id: \.self) { fact in
                Text(fact)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("이 앱이 부르는 API는 계좌 목록, 보유 현황, 환율, 매수 가능 금액뿐입니다.")
        }
    }

    private static let readOnlyFacts = [
        "주문·정정·취소 같은 계좌 상태를 바꾸는 코드는 앱에 아예 존재하지 않습니다.",
        "조회한 값은 이 기기 안에만 저장되고, 외부로 보내지 않습니다.",
        "통신 상대는 openapi.tossinvest.com 하나뿐입니다."
    ]

    // MARK: - 보안

    private var securitySection: some View {
        Section {
            ForEach(Self.securityFacts, id: \.self) { fact in
                Text(fact)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("키 보관")
        } footer: {
            Text("앱을 지우기 전에 설정 › API 키 삭제 및 초기화 를 실행하고, 토스증권 WTS 설정 > Open API 에서 키를 폐기해 주세요. 앱에서 지우는 것만으로는 키가 폐기되지 않습니다.")
        }
    }

    private static let securityFacts = [
        "client_id 와 client_secret 은 이 기기의 Keychain에만 저장됩니다.",
        "키와 액세스 토큰은 화면, 로그, 오류 기록 어디에도 남지 않습니다."
    ]

    // MARK: - 최근 오류

    private var recentErrorsSection: some View {
        Section {
            if errors.isEmpty {
                Text("기록된 오류가 없습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(errors) { error in
                    RecentErrorRow(error: error)
                }

                Button("오류 기록 지우기", role: .destructive) {
                    isConfirmingErrorClear = true
                }
            }
        } header: {
            Text("최근 오류")
        } footer: {
            Text("갱신이 실패했을 때의 코드·메시지·요청 ID를 최대 \(RecentErrorLog.maxEntries)개까지 기기에만 남깁니다. API 키는 기록되지 않습니다.")
        }
    }

    // MARK: - Bundle

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(short) (\(build))"
    }
}

/// One row of README §3.5's local error log: when, which `code`, the message, and the request id
/// that support would ask for.
private struct RecentErrorRow: View {
    let error: RecentError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(error.code)
                    .font(.footnote.weight(.semibold).monospaced())
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text(FireFormatter.refreshedAt(error.timestamp, now: Date()))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !error.message.isEmpty {
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let requestId = error.requestId, !requestId.isEmpty {
                Text("요청 ID \(requestId)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
