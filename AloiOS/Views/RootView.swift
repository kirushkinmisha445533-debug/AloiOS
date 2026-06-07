import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AloAppModel

    var body: some View {
        ZStack {
            AloTheme.background.ignoresSafeArea()
            switch app.phase {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView().tint(AloTheme.accent)
                    Text("Alo")
                        .font(.largeTitle.bold())
                        .foregroundStyle(AloTheme.text)
                }
            case .auth:
                AuthView()
            case .app:
                MainTabView()
            }

            if let challenge = app.humanChallenge {
                HumanChallengeView(
                    challenge: challenge,
                    onToken: app.completeChallenge,
                    onClose: app.closeChallenge
                )
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: app.phaseKey)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: app.humanChallenge?.id)
        .task {
            app.start()
        }
    }
}

private extension AloAppModel {
    var phaseKey: String {
        switch phase {
        case .loading: return "loading"
        case .auth: return "auth"
        case .app: return "app"
        }
    }
}
