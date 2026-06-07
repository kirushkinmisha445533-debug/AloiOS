import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var selectedRelationList: SearchRelationListKind?

    private var users: [AloEntitySummary] {
        let query = app.searchQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let all = (app.bootstrap?.searchUsers ?? []) + (app.bootstrap?.searchChannels ?? [])
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(query) || $0.username.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Кого читать")
                    .font(.largeTitle.bold())
                    .foregroundStyle(AloTheme.text)

                AloTextField(placeholder: "Поиск", text: $app.searchQuery)

                if let stats = app.bootstrap?.profileStats {
                    SearchRelationsOverview(stats: stats) { kind in
                        selectedRelationList = kind
                    }
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(users) { item in
                        HStack(spacing: 12) {
                            Button {
                                app.openProfile(item)
                            } label: {
                                HStack(spacing: 12) {
                                    AloAvatar(name: item.name, url: item.avatarUrl, size: 56)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 5) {
                                            Text(item.name)
                                                .font(.system(size: 18, weight: .bold))
                                            if item.verified {
                                                Image(systemName: "checkmark.seal.fill")
                                                    .font(.system(size: 15, weight: .bold))
                                                    .foregroundStyle(AloTheme.accent)
                                            }
                                        }
                                        Text(item.isChannel ? "Паблик" : item.username.withAtPrefix)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(AloTheme.muted)
                                    }
                                }
                                .foregroundStyle(AloTheme.text)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            if !item.isChannel {
                                Button(friendButtonTitle(for: item)) {
                                    app.sendFriendRequest(item)
                                }
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(friendButtonEnabled(for: item) ? Color.white : AloTheme.muted)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(friendButtonEnabled(for: item) ? AloTheme.accent : AloTheme.surfaceRaised)
                                .clipShape(Capsule())
                                .disabled(!friendButtonEnabled(for: item))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        Divider().background(AloTheme.border).padding(.leading, 82)
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .fullScreenCover(item: $selectedRelationList) { kind in
            SearchRelationListScreen(
                kind: kind,
                items: relationItems(for: kind),
                onClose: { selectedRelationList = nil }
            )
            .environmentObject(app)
        }
    }

    private func friendButtonTitle(for item: AloEntitySummary) -> String {
        switch item.relation?.friendStatus {
        case "friends":
            return "В друзьях"
        case "outgoing":
            return "Отправлено"
        case "incoming":
            return "Ответить"
        default:
            return "Добавить"
        }
    }

    private func friendButtonEnabled(for item: AloEntitySummary) -> Bool {
        (item.relation?.friendStatus ?? "none") == "none"
    }

    private func relationItems(for kind: SearchRelationListKind) -> [AloEntitySummary] {
        let users = app.bootstrap?.searchUsers ?? []
        let channels = app.bootstrap?.searchChannels ?? []

        switch kind {
        case .friends:
            return users.filter { $0.relation?.friendStatus == "friends" }
        case .followers:
            return users.filter { ($0.relation?.followedBy ?? false) && $0.relation?.friendStatus != "friends" }
        case .following:
            return users.filter { ($0.relation?.following ?? false) && $0.relation?.friendStatus != "friends" }
        case .channels:
            return channels
        }
    }
}

private struct SearchRelationsOverview: View {
    let stats: AloProfileStats
    let onTap: (SearchRelationListKind) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            relationTile(.friends, "Друзья", stats.friends)
            relationTile(.followers, "Подписчики", stats.followers)
            relationTile(.following, "Подписки", stats.following)
            relationTile(.channels, "Каналы", stats.channels)
        }
    }

    private func relationTile(_ kind: SearchRelationListKind, _ title: String, _ value: Int) -> some View {
        Button {
            onTap(kind)
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1)
                Spacer()
                Text("\(value)")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(AloTheme.accent)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .background(AloTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private enum SearchRelationListKind: String, Identifiable {
    case friends
    case followers
    case following
    case channels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friends:
            return "Друзья"
        case .followers:
            return "Подписчики"
        case .following:
            return "Подписки"
        case .channels:
            return "Каналы"
        }
    }
}

private struct SearchRelationListScreen: View {
    @EnvironmentObject private var app: AloAppModel
    let kind: SearchRelationListKind
    let items: [AloEntitySummary]
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            AloTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.title)
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .foregroundStyle(AloTheme.text)

                        Text(subtitle)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(AloTheme.muted)
                    }
                    .padding(.top, 96)
                    .padding(.horizontal, 14)

                    if items.isEmpty {
                        ContentUnavailableView(
                            "\(kind.title.lowercased()) пока нет",
                            systemImage: emptySymbol,
                            description: Text("Когда здесь появятся связи, они будут показаны списком.")
                        )
                        .foregroundStyle(AloTheme.muted)
                        .padding(.top, 48)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                Button {
                                    onClose()
                                    app.openProfile(item)
                                } label: {
                                    HStack(spacing: 12) {
                                        AloAvatar(name: item.name, url: item.avatarUrl, size: 58)

                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 5) {
                                                Text(item.name)
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundStyle(AloTheme.text)
                                                if item.verified {
                                                    Image(systemName: "checkmark.seal.fill")
                                                        .font(.system(size: 15, weight: .bold))
                                                        .foregroundStyle(AloTheme.accent)
                                                }
                                            }

                                            Text(item.isChannel ? "Паблик" : item.username.withAtPrefix)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(AloTheme.muted)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(AloTheme.muted.opacity(0.85))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Divider()
                                    .background(AloTheme.border)
                                    .padding(.leading, 86)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.bottom, 36)
            }

            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 58, height: 58)
                    .contentShape(Rectangle())
            }
            .padding(.leading, 14)
            .padding(.top, 20)
        }
    }

    private var subtitle: String {
        switch kind {
        case .friends:
            return "Список твоих подтверждённых друзей."
        case .followers:
            return "Кто подписан на тебя."
        case .following:
            return "На кого подписан ты."
        case .channels:
            return "Паблики и каналы, доступные в подборке."
        }
    }

    private var emptySymbol: String {
        switch kind {
        case .friends:
            return "person.2"
        case .followers:
            return "person.badge.shield.checkmark"
        case .following:
            return "person.crop.circle.badge.plus"
        case .channels:
            return "megaphone"
        }
    }
}
