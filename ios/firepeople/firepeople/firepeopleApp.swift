//
//  firepeopleApp.swift
//  firepeople
//
//  FIRE D-Day — 목표일까지 남은 날과 자산 진행률만 보여주는 앱.
//
//  The SwiftData template this file started as is gone: there is no `ModelContainer`, no `Item`, no
//  persistence beyond the App Group JSON stores and the Keychain (README §4.3, §5.1). The whole app
//  is one `AppModel` handed to two screens.
//

import SwiftUI
import FireCore

@main
struct firepeopleApp: App {

    /// Created once for the process. Owns the Keychain, the App Group stores, the API client and
    /// the refresh service; every screen reads it out of the environment.
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// Picks the screen: onboarding until it has been completed, the main countdown afterwards.
///
/// Onboarding resumes where the user left it because the values it collects are written through as
/// they are entered — keys straight to the Keychain, settings to the App Group store (README §2.1).
private struct RootView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.route {
            case .onboarding:
                // The flow owns its own draft state and writes what it collects straight to the
                // shared stores; the callback is only the routing signal, and `onboardingDidFinish`
                // re-reads what was written before switching screens.
                OnboardingFlowView { model.onboardingDidFinish() }
            case .main:
                MainView()
            }
        }
        .task {
            // Idempotent: loads settings + snapshot, picks the route and, on the main route, starts
            // a refresh when the stored snapshot is older than the configured interval.
            model.bootstrap()
        }
        .animation(.easeInOut(duration: 0.25), value: model.route)
    }
}
