import SwiftUI

struct AlertsView: View {
    @EnvironmentObject private var app: AloAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Уведомления")
                .font(.largeTitle.bold())
                .foregroundStyle(AloTheme.text)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(app.bootstrap?.notifications ?? []) { item in
                        HStack(alignment: .top, spacing: 12) {
                            ZStack(alignment: .bottomTrailing) {
                                Button {
                                    if let actor = item.actor {
                                        app.openProfile(actor)
                                    }
                                } label: {
                                    AloAvatar(name: item.actor?.name ?? "A", url: item.actor?.avatarUrl ?? "", size: 50)
                                }
                                .buttonStyle(.plain)

                                Image(systemName: icon(for: item))
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(Color.white)
                                    .frame(width: 20, height: 20)
                                    .background(color(for: item))
                                    .clipShape(Circle())
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.text)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(AloTheme.text)
                                Text(item.createdAt.prefix(16))
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(AloTheme.muted)
                                if item.actionableFriendRequestId > 0 {
                                    HStack {
                                        Button("Принять") { app.respondFriendRequest(item, accept: true) }
                                            .buttonStyle(.borderedProminent)
                                        Button("Отклонить") { app.respondFriendRequest(item, accept: false) }
                                            .buttonStyle(.bordered)
                                    }
                                }
                            }
                            Spacer()
                        }
                        .padding(16)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let actor = item.actor {
                                app.openProfile(actor)
                            }
                        }
                        Divider().background(AloTheme.border).padding(.leading, 76)
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .refreshable { await app.loadBootstrap() }
    }

    private func icon(for item: AloNotificationItem) -> String {
        switch item.type {
        case "friend_request":
            return "person.badge.plus"
        case "friend_accept":
            return "checkmark"
        case "like", "comment_like":
            return "heart.fill"
        case "comment":
            return "bubble.left.fill"
        default:
            return "bell.fill"
        }
    }

    private func color(for item: AloNotificationItem) -> Color {
        switch item.type {
        case "friend_accept":
            return .green
        case "like", "comment_like":
            return Color(red: 1, green: 0.32, blue: 0.42)
        default:
            return AloTheme.accent
        }
    }
}
