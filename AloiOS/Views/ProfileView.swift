import SwiftUI
import PhotosUI

struct ProfileView: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var selectedSection: ProfileSection = .posts
    @State private var isPalettePresented = false
    @State private var isEditPresented = false
    @State private var selectedAvatarItem: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let data = app.bootstrap {
                    ProfileHeroCard(
                        user: data.me,
                        coverStyleOverride: nil,
                        showsOwnerControls: true,
                        primaryTitle: nil,
                        primarySystemImage: nil,
                        primaryAccent: false,
                        onPrimary: nil,
                        secondarySystemImage: nil,
                        onSecondary: nil,
                        onEditProfile: { isEditPresented = true },
                        onEditBanner: { isPalettePresented = true },
                        avatarSelection: $selectedAvatarItem
                    )

                    ProfileContentSwitcher(selected: $selectedSection)

                    ForEach(selectedSection == .posts ? data.profilePosts : []) { post in
                        AloPostCard(post: post) {
                            app.toggleLike(post)
                        } onComment: {
                            app.openComments(for: post)
                        } onAuthor: {
                            app.openProfile(post.author)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 100)
        }
        .refreshable { await app.loadBootstrap() }
        .sheet(isPresented: $isPalettePresented) {
            ProfilePaletteSheet(
                name: app.bootstrap?.me.name ?? "Alo",
                selectedStyle: app.bootstrap?.me.coverStyle ?? "violet"
            ) { style in
                app.updateProfileCover(style: style)
            }
        }
        .fullScreenCover(isPresented: $isEditPresented) {
            ProfileEditSheet(
                user: app.bootstrap?.me,
                privacySettings: app.bootstrap?.privacySettings ?? .default,
                onApplyPrivacy: { settings in app.updatePrivacy(settings: settings) },
                onLogout: { app.logout() }
            )
        }
        .onChange(of: selectedAvatarItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        app.updateProfileAvatar(data: data)
                        selectedAvatarItem = nil
                    }
                }
            }
        }
    }
}

struct ProfileDetailView: View {
    @EnvironmentObject private var app: AloAppModel
    let profile: AloUserProfile
    @State private var selectedSection: ProfileSection = .posts

    var body: some View {
        ZStack(alignment: .topLeading) {
            AloTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 10) {
                    ProfileHeroCard(
                        user: profile.user,
                        coverStyleOverride: nil,
                        showsOwnerControls: false,
                        primaryTitle: relationTitle,
                        primarySystemImage: relationIcon,
                        primaryAccent: relationTitle == "Добавить" || relationTitle == "Подписаться" || relationTitle == "Принять",
                        onPrimary: handleRelationTap,
                        secondarySystemImage: profile.permissions.canMessage ? "message.fill" : nil,
                        onSecondary: profile.permissions.canMessage ? { app.openConversation(with: profile) } : nil,
                        onEditProfile: nil,
                        onEditBanner: nil
                    )
                    .padding(.top, 8)

                    if profile.permissions.isPrivate {
                        privateNotice
                    } else {
                        ProfileContentSwitcher(selected: $selectedSection)

                        let posts = selectedSection == .posts ? profile.posts : profile.likes
                        if posts.isEmpty {
                            ContentUnavailableView(
                                selectedSection == .posts ? "Постов пока нет" : "Отметок пока нет",
                                systemImage: selectedSection == .posts ? "text.bubble" : "heart",
                                description: Text("Когда здесь появится контент, он будет показан списком.")
                            )
                            .foregroundStyle(AloTheme.muted)
                            .padding(.top, 34)
                        } else {
                            ForEach(posts) { post in
                                AloPostCard(post: post) {
                                    app.toggleLike(post)
                                } onComment: {
                                    app.openComments(for: post)
                                } onAuthor: {
                                    app.openProfile(post.author)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 28)
            }

            Button(action: app.closeProfile) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 42, height: 46)
                    .contentShape(Rectangle())
            }
            .padding(.leading, 20)
            .padding(.top, 18)
        }
    }

    private var privateNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Закрытый профиль", systemImage: "lock.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AloTheme.text)
            Text("Посты, фото и отметки откроются только после добавления в друзья.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .aloCard(radius: 22)
    }

    private var relationTitle: String {
        switch profile.relation.friendStatus {
        case "friends":
            return "В друзьях"
        case "outgoing":
            return "Отправлено"
        case "incoming":
            return "Принять"
        default:
            if profile.permissions.canSendFriendRequest {
                return "Добавить"
            }
            return profile.relation.following ? "Вы подписаны" : "Подписаться"
        }
    }

    private var relationIcon: String {
        switch profile.relation.friendStatus {
        case "friends":
            return "checkmark"
        case "outgoing":
            return "clock"
        case "incoming":
            return "checkmark"
        default:
            return profile.permissions.canSendFriendRequest ? "person.badge.plus" : "bell.badge"
        }
    }

    private var isOwnProfile: Bool {
        app.bootstrap?.me.id == profile.user.id
    }

    private func handleRelationTap() {
        switch profile.relation.friendStatus {
        case "incoming":
            guard profile.relation.incomingRequestId > 0 else { return }
            app.respondFriendRequest(requestId: profile.relation.incomingRequestId, accept: true)
        case "none":
            if profile.permissions.canSendFriendRequest {
                app.sendFriendRequest(userId: profile.user.id)
            } else {
                app.toggleFollowUser(userId: profile.user.id)
            }
        default:
            return
        }
    }
}

private struct ProfileHeroCard: View {
    let user: AloCurrentUser
    let coverStyleOverride: String?
    let showsOwnerControls: Bool
    let primaryTitle: String?
    let primarySystemImage: String?
    let primaryAccent: Bool
    let onPrimary: (() -> Void)?
    let secondarySystemImage: String?
    let onSecondary: (() -> Void)?
    let onEditProfile: (() -> Void)?
    let onEditBanner: (() -> Void)?
    var avatarSelection: Binding<PhotosPickerItem?>? = nil
    @State private var isAvatarOptionsPresented = false

    var body: some View {
        let outerRadius: CGFloat = 30
        let bannerRadius: CGFloat = outerRadius
        let bannerHeight: CGFloat = 178
        let avatarSize: CGFloat = 116
        let avatarOverlap: CGFloat = avatarSize / 2
        let hasActions = primaryTitle != nil || secondarySystemImage != nil

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .fill(AloTheme.surface)

            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: bannerRadius, style: .continuous)
                    .fill(aloProfileGradient(coverStyleOverride ?? user.coverStyle))
                    .frame(height: bannerHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: bannerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    }

                Color.clear.frame(height: 82)
            }

            HStack(alignment: .top, spacing: 10) {
                avatarView(size: avatarSize)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(user.name)
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                            .layoutPriority(1)
                        if user.verified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(AloTheme.accent)
                        }
                    }
                    .foregroundStyle(AloTheme.text)

                    Text(user.username.withAtPrefix)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(AloTheme.muted)
                }
                .padding(.top, avatarOverlap + 8)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.leading, 24)
            .padding(.trailing, 24)
            .padding(.top, bannerHeight - avatarOverlap)
            .padding(.bottom, 20)

            if showsOwnerControls {
                HStack(spacing: 8) {
                    if let onEditProfile {
                        Button(action: onEditProfile) {
                            Text("Редактировать")
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 16)
                                .frame(height: 40)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    if let onEditBanner {
                        Button(action: onEditBanner) {
                            Image(systemName: "paintpalette.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(width: 40, height: 40)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 14)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }

            if !showsOwnerControls && hasActions {
                profileActionRow
                    .padding(.top, 14)
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 284)
        .clipShape(RoundedRectangle(cornerRadius: outerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 12)
        .confirmationDialog(
            "Фотография профиля",
            isPresented: $isAvatarOptionsPresented,
            titleVisibility: .visible
        ) {
            if let avatarSelection {
                PhotosPicker(selection: avatarSelection, matching: .images) {
                    Text("Загрузить новое фото")
                }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func avatarView(size: CGFloat) -> some View {
        if showsOwnerControls, avatarSelection != nil {
            Button {
                isAvatarOptionsPresented = true
            } label: {
                AloAvatar(name: user.name, url: user.avatarUrl, size: size)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(AloTheme.accent)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(AloTheme.surface, lineWidth: 3))
                            .offset(x: 2, y: 2)
                    }
            }
            .buttonStyle(.plain)
        } else {
            AloAvatar(name: user.name, url: user.avatarUrl, size: size)
        }
    }

    private var profileActionRow: some View {
        HStack(spacing: 8) {
            if let primaryTitle, let onPrimary {
                Button(action: onPrimary) {
                    HStack(spacing: 6) {
                        if let primarySystemImage {
                            Image(systemName: primarySystemImage)
                                .font(.system(size: 13, weight: .bold))
                        }
                        Text(primaryTitle)
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 15)
                    .frame(height: 40)
                    .background(Color.black.opacity(primaryAccent ? 0.28 : 0.24))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.30), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!(primaryTitle == "Отправлено" || primaryTitle == "В друзьях"))
            }

            if let secondarySystemImage, let onSecondary {
                Button(action: onSecondary) {
                    Image(systemName: secondarySystemImage)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.24))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.30), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

}

private struct ProfilePaletteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State var selectedStyle: String
    let onApply: (String) -> Void

    private let styles = ["violet", "azure", "emerald", "sunset", "rose", "ocean"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(AloTheme.muted.opacity(0.55))
                .frame(width: 54, height: 5)
                .frame(maxWidth: .infinity)

            Text("Баннер профиля")
                .font(.system(size: 24, weight: .heavy, design: .rounded))

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(aloProfileGradient(selectedStyle))
                .frame(height: 158)
                .overlay(alignment: .bottomLeading) {
                    Text(name)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white)
                        .padding(22)
                }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(styles, id: \.self) { style in
                    Button {
                        selectedStyle = style
                    } label: {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(aloProfileGradient(style))
                            .frame(height: 86)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(selectedStyle == style ? Color.white : Color.white.opacity(0.08), lineWidth: selectedStyle == style ? 3 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)

            AloPrimaryButton(title: "Применить") {
                onApply(selectedStyle)
                dismiss()
            }
        }
        .padding(20)
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

}

private func aloProfileGradient(_ style: String) -> LinearGradient {
    let colors: [Color]
    switch style {
    case "sunset":
        colors = [
            Color(red: 1.00, green: 0.31, blue: 0.12),
            Color(red: 1.00, green: 0.52, blue: 0.20),
            Color(red: 1.00, green: 0.74, blue: 0.18)
        ]
    case "violet":
        colors = [
            Color(red: 0.88, green: 0.20, blue: 1.00),
            Color(red: 0.60, green: 0.44, blue: 1.00),
            Color(red: 0.16, green: 0.58, blue: 1.00)
        ]
    case "azure", "ocean":
        colors = [
            Color(red: 0.00, green: 0.31, blue: 1.00),
            Color(red: 0.16, green: 0.58, blue: 1.00),
            Color(red: 0.65, green: 0.93, blue: 1.00)
        ]
    case "rose":
        colors = [
            Color(red: 1.00, green: 0.12, blue: 0.44),
            Color(red: 1.00, green: 0.36, blue: 0.56),
            Color(red: 1.00, green: 0.54, blue: 0.66)
        ]
    case "emerald":
        colors = [
            Color(red: 0.00, green: 0.48, blue: 0.33),
            Color(red: 0.03, green: 0.83, blue: 0.59),
            Color(red: 0.53, green: 1.00, blue: 0.89)
        ]
    default:
        colors = [
            Color(red: 0.88, green: 0.20, blue: 1.00),
            Color(red: 0.60, green: 0.44, blue: 1.00),
            Color(red: 0.16, green: 0.58, blue: 1.00)
        ]
    }
    return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
}

private struct ProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let user: AloCurrentUser?
    let privacySettings: AloPrivacySettings
    let onApplyPrivacy: (AloPrivacySettings) -> Void
    let onLogout: () -> Void
    @State private var allowFriendRequests: Bool
    @State private var messageScope: String
    @State private var allowMessageForwards: Bool
    @State private var callScope: String
    @State private var profileVisibility: String
    @State private var hideActivity: Bool

    init(
        user: AloCurrentUser?,
        privacySettings: AloPrivacySettings,
        onApplyPrivacy: @escaping (AloPrivacySettings) -> Void,
        onLogout: @escaping () -> Void
    ) {
        self.user = user
        self.privacySettings = privacySettings
        self.onApplyPrivacy = onApplyPrivacy
        self.onLogout = onLogout
        _allowFriendRequests = State(initialValue: privacySettings.allowFriendRequests)
        _messageScope = State(initialValue: privacySettings.messageScope.ifBlank("all"))
        _allowMessageForwards = State(initialValue: privacySettings.allowMessageForwards)
        _callScope = State(initialValue: privacySettings.callScope.ifBlank("all"))
        _profileVisibility = State(initialValue: privacySettings.profileVisibility.ifBlank("all"))
        _hideActivity = State(initialValue: privacySettings.hideActivity)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 12) {
                    infoCard

                    settingsCard(title: "Приватность") {
                        settingToggle(
                            title: "Заявки в друзья",
                            subtitle: "Разрешать другим отправлять запросы",
                            isOn: $allowFriendRequests
                        )
                        settingDivider
                        choiceBlock(
                            title: "Кто может писать",
                            options: [
                                ("friends", "Друзья"),
                                ("friends_of_friends", "Друзья и друзья друзей"),
                                ("all", "Все")
                            ],
                            selected: $messageScope
                        )
                        settingDivider
                        choiceBlock(
                            title: "Кто видит профиль",
                            options: [
                                ("all", "Все"),
                                ("friends", "Только друзья")
                            ],
                            selected: $profileVisibility
                        )
                    }

                    settingsCard(title: "Сообщения и звонки") {
                        settingToggle(
                            title: "Пересылка сообщений",
                            subtitle: "Разрешать другим пересылать ваши сообщения",
                            isOn: $allowMessageForwards
                        )
                        settingDivider
                        choiceBlock(
                            title: "Кто может звонить",
                            options: [
                                ("friends", "Друзья"),
                                ("friends_of_friends", "Друзья и друзья друзей"),
                                ("all", "Все"),
                                ("none", "Никто")
                            ],
                            selected: $callScope
                        )
                        settingDivider
                        settingToggle(
                            title: "Скрывать активность",
                            subtitle: "Показывать общий статус вместо точного онлайна",
                            isOn: $hideActivity
                        )
                    }

                    Button(role: .destructive) {
                        onLogout()
                        dismiss()
                    } label: {
                        Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(AloTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 100)
            }

            AloPrimaryButton(title: "Сохранить") {
                onApplyPrivacy(AloPrivacySettings(
                    allowFriendRequests: allowFriendRequests,
                    messageScope: messageScope,
                    allowMessageForwards: allowMessageForwards,
                    callScope: callScope,
                    profileVisibility: profileVisibility,
                    hideActivity: hideActivity
                ))
                dismiss()
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("Редактировать профиль")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                Text("Настройки аккаунта и приватности")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(AloTheme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(user?.name ?? "Alo")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
            Text("Эти параметры синхронизируются с сервером и применяются на всех устройствах.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func settingToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn.animation(.spring(response: 0.24, dampingFraction: 0.9))) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
            }
        }
        .tint(AloTheme.accent)
    }

    private var settingDivider: some View {
        Rectangle()
            .fill(AloTheme.border.opacity(0.7))
            .frame(height: 1)
    }

    private func choiceBlock(title: String, options: [(String, String)], selected: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .heavy, design: .rounded))

            ForEach(Array(options.enumerated()), id: \.element.0) { index, option in
                let value = option.0
                let label = option.1
                Toggle(isOn: Binding(
                    get: { selected.wrappedValue == value },
                    set: { isOn in
                        guard isOn else { return }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            selected.wrappedValue = value
                        }
                    }
                )) {
                    Text(label)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(AloTheme.text)
                }
                .tint(AloTheme.accent)

                if index < options.count - 1 {
                    settingDivider.opacity(0.55)
                }
            }
        }
    }
}

private struct ProfileContentSwitcher: View {
    @Binding var selected: ProfileSection
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ProfileSection.allCases) { section in
                Button(section.title) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        selected = section
                    }
                }
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(selected == section ? AloTheme.text : AloTheme.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background {
                    if selected == section {
                        Capsule()
                            .fill(AloTheme.surfaceRaised)
                            .matchedGeometryEffect(id: "profile-switcher", in: namespace)
                    }
                }
            }
        }
        .padding(4)
        .background(AloTheme.surface)
        .clipShape(Capsule())
    }
}

private enum ProfileSection: String, CaseIterable, Identifiable {
    case posts
    case likes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .posts: return "Посты"
        case .likes: return "Нравится"
        }
    }
}
