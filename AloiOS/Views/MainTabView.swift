import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var app: AloAppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch app.activeTab {
                case .feed:
                    FeedView()
                case .search:
                    SearchView()
                case .messages:
                    MessagesView()
                case .alerts:
                    AlertsView()
                case .profile:
                    ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !(app.activeTab == .messages && app.activeConversation != nil) {
                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
            }

            if app.isProfileLoading {
                ProgressView()
                    .tint(AloTheme.accent)
                    .frame(width: 54, height: 54)
                    .background(AloTheme.surface)
                    .clipShape(Circle())
                    .transition(.scale.combined(with: .opacity))
            }

            if let profile = app.selectedProfile {
                ProfileDetailView(profile: profile)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                    .zIndex(20)
            }
        }
        .background(AloTheme.background.ignoresSafeArea())
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: app.selectedProfile?.id)
        .animation(.spring(response: 0.24, dampingFraction: 0.9), value: app.isProfileLoading)
        .alert("Alo", isPresented: errorBinding) {
            Button("Ок") { app.errorMessage = "" }
        } message: {
            Text(app.errorMessage)
        }
        .sheet(isPresented: commentsPresented) {
            CommentsSheet()
                .environmentObject(app)
        }
        .onChange(of: app.activeTab) { _, tab in
            guard tab == .feed || tab == .profile || tab == .search || tab == .alerts else { return }
            Task { await app.loadBootstrap() }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach(AloAppTab.allCases) { tab in
                Button {
                    app.activeTab = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 19, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(app.activeTab == tab ? AloTheme.text : AloTheme.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 68)
                    .background {
                        if app.activeTab == tab {
                            Circle()
                                .fill(AloTheme.surfaceRaised)
                                .frame(width: 74, height: 74)
                                .matchedGeometryEffect(id: "tab", in: namespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 74)
        .background {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(AloTheme.surface.opacity(0.72))
        }
        .clipShape(Capsule())
        .overlay(Capsule().stroke(AloTheme.border, lineWidth: 1))
    }

    @Namespace private var namespace

    private var errorBinding: Binding<Bool> {
        Binding(get: { !app.errorMessage.isEmpty && app.phase == .app }, set: { if !$0 { app.errorMessage = "" } })
    }

    private var commentsPresented: Binding<Bool> {
        Binding(
            get: { app.commentsPost != nil },
            set: { presented in
                if !presented {
                    app.closeComments()
                }
            }
        )
    }
}
