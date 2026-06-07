import SwiftUI
import UIKit

struct AloAvatar: View {
    let name: String
    let url: String
    var size: CGFloat = 46

    @EnvironmentObject private var app: AloAppModel

    var body: some View {
        ZStack {
            Circle().fill(AloTheme.surfaceRaised)
            if let imageUrl = app.api.absoluteURL(url), !url.isEmpty {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Text(initial)
                            .font(.system(size: size * 0.42, weight: .bold))
                            .foregroundStyle(AloTheme.accent)
                    }
                }
                .clipShape(Circle())
            } else {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(AloTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
    }

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased().ifBlank("A")
    }
}

struct AloIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AloTheme.text)
                .frame(width: 46, height: 46)
                .background {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(AloTheme.surfaceRaised.opacity(0.72))
                }
                .clipShape(Circle())
                .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct AloPrimaryButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(disabled ? AloTheme.surfaceRaised : AloTheme.accent)
                .clipShape(Capsule())
        }
        .disabled(disabled)
        .buttonStyle(.plain)
    }
}

struct AloTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .foregroundStyle(AloTheme.text)
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(AloTheme.surfaceRaised)
        .clipShape(Capsule())
    }
}

struct AloPostCard: View {
    let post: AloPost
    let onLike: () -> Void
    var onComment: () -> Void = {}
    var onAuthor: () -> Void = {}

    @EnvironmentObject private var app: AloAppModel
    @State private var isDeleteConfirmationPresented = false
    @State private var likePulse = false

    private var canDelete: Bool {
        guard let currentUserId = app.bootstrap?.me.id else { return false }
        return post.creatorId == currentUserId || post.author.id == currentUserId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: onAuthor) {
                    HStack(spacing: 10) {
                        AloAvatar(name: post.author.name, url: post.author.avatarUrl, size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(post.author.name)
                                    .font(.system(size: 17, weight: .bold))
                                if post.author.verified {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(AloTheme.accent)
                                }
                            }
                            Text(post.author.username.withAtPrefix)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AloTheme.muted)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(shortDate(post.createdAt))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                    Button {
                        isDeleteConfirmationPresented = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AloTheme.muted)
                            .frame(width: 34, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !post.body.isEmpty {
                Text(post.body)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(AloTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !post.media.isEmpty {
                AloPostMediaGrid(media: post.media)
            }

            HStack(spacing: 22) {
                Button {
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.62)) {
                        likePulse = true
                    }
                    onLike()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                            likePulse = false
                        }
                    }
                } label: {
                    Label("\(post.likeCount)", systemImage: post.viewerLiked ? "heart.fill" : "heart")
                        .foregroundStyle(post.viewerLiked ? Color(red: 1, green: 0.32, blue: 0.42) : AloTheme.muted)
                }
                .scaleEffect(likePulse ? 1.16 : 1)
                Button(action: onComment) {
                    Label("\(post.commentCount)", systemImage: "bubble.left")
                        .foregroundStyle(AloTheme.muted)
                }
                Label("\(post.repostCount)", systemImage: "arrow.2.squarepath")
                    .foregroundStyle(AloTheme.muted)
                Spacer()
                Label("\(post.viewCount)", systemImage: "eye")
                    .foregroundStyle(AloTheme.muted)
            }
            .font(.system(size: 15, weight: .semibold))
        }
        .padding(14)
        .aloCard(radius: 22)
        .confirmationDialog(
            "Пост",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Скопировать ссылку") {
                copyPostLink()
            }
            if canDelete {
                Button("Удалить пост", role: .destructive) {
                    app.deletePost(post)
                }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func copyPostLink() {
        UIPasteboard.general.string = app.api.appURL("/posts/\(post.id)").absoluteString
        app.notice = "Ссылка на пост скопирована."
    }

    private func shortDate(_ raw: String) -> String {
        let value = String(raw.prefix(10))
        guard value.count == 10 else { return value }
        return String(value.suffix(5))
    }
}

struct AloPostMediaGrid: View {
    let media: [AloMediaItem]

    @EnvironmentObject private var app: AloAppModel
    @State private var selectedMedia: AloMediaItem?

    var body: some View {
        Group {
            switch media.count {
            case 0:
                EmptyView()
            case 1:
                mediaCell(media[0])
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
            case 2:
                HStack(spacing: 2) {
                    mediaCell(media[0])
                        .frame(maxWidth: .infinity)
                    mediaCell(media[1])
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 230)
            case 3:
                HStack(spacing: 2) {
                    mediaCell(media[0])
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 2) {
                        mediaCell(media[1])
                            .frame(maxWidth: .infinity)
                        mediaCell(media[2])
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 270)
            default:
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(media.prefix(4)) { item in
                        mediaCell(item)
                            .frame(maxWidth: .infinity)
                            .frame(height: 145)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .fullScreenCover(item: $selectedMedia) { item in
            AloPostMediaViewer(
                media: media,
                startItem: item,
                onDismiss: { selectedMedia = nil }
            )
            .environmentObject(app)
        }
    }

    private func mediaCell(_ item: AloMediaItem) -> some View {
        GeometryReader { proxy in
            ZStack {
                AloTheme.background
                if let url = app.api.absoluteURL(item.posterUrl.ifBlank(item.url)) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        default:
                            ProgressView().tint(AloTheme.accent)
                        }
                    }
                }
                if item.type == "video" {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                selectedMedia = item
            }
        }
        .clipped()
    }
}

private struct AloPostMediaViewer: View {
    let media: [AloMediaItem]
    let startItem: AloMediaItem
    let onDismiss: () -> Void

    @EnvironmentObject private var app: AloAppModel
    @Environment(\.openURL) private var openURL
    @State private var selectedURL: String
    @State private var notice: String?

    init(media: [AloMediaItem], startItem: AloMediaItem, onDismiss: @escaping () -> Void) {
        self.media = media
        self.startItem = startItem
        self.onDismiss = onDismiss
        _selectedURL = State(initialValue: startItem.url)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedURL) {
                ForEach(media) { item in
                    viewerContent(for: item)
                        .tag(item.url)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: media.count > 1 ? .automatic : .never))

            HStack {
                Spacer()
                actionRail
                    .padding(.trailing, 16)
            }

            VStack {
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                Spacer()
            }

            if let notice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                        .padding(.bottom, 42)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    @ViewBuilder
    private func viewerContent(for item: AloMediaItem) -> some View {
        if let url = app.api.absoluteURL(item.posterUrl.ifBlank(item.url)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    ProgressView()
                        .tint(AloTheme.accent)
                }
            }
        } else {
            ProgressView()
                .tint(AloTheme.accent)
        }
    }

    private var actionRail: some View {
        VStack(spacing: 12) {
            if let url = currentAbsoluteURL {
                ShareLink(item: url) {
                    railIcon("square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }

            Button {
                copyCurrentLink()
            } label: {
                railIcon("link")
            }
            .buttonStyle(.plain)

            Button {
                saveCurrentMedia()
            } label: {
                railIcon("arrow.down.to.line")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.42))
        .clipShape(Capsule())
    }

    private func railIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(Color.white.opacity(0.10))
            .clipShape(Circle())
    }

    private var currentItem: AloMediaItem? {
        media.first(where: { $0.url == selectedURL }) ?? media.first
    }

    private var currentAbsoluteURL: URL? {
        guard let currentItem else { return nil }
        return app.api.absoluteURL(currentItem.url)
    }

    private func copyCurrentLink() {
        guard let url = currentAbsoluteURL else { return }
        UIPasteboard.general.string = url.absoluteString
        showNotice("Ссылка скопирована")
    }

    private func saveCurrentMedia() {
        guard let item = currentItem, let url = currentAbsoluteURL else { return }
        Task {
            do {
                let (localURL, response) = try await URLSession.shared.download(from: url)
                let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
                if item.type == "video" || mime.hasPrefix("video/") {
                    UISaveVideoAtPathToSavedPhotosAlbum(localURL.path, nil, nil, nil)
                } else if let data = try? Data(contentsOf: localURL), let image = UIImage(data: data) {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                }
                await MainActor.run { showNotice("Сохранено") }
            } catch {
                await MainActor.run { showNotice("Не удалось сохранить") }
            }
        }
    }

    private func showNotice(_ value: String) {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            notice = value
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.16)) {
                if notice == value {
                    notice = nil
                }
            }import SwiftUI
            import UIKit

            struct AloAvatar: View {
                let name: String
                let url: String
                var size: CGFloat = 46

                @EnvironmentObject private var app: AloAppModel

                var body: some View {
                    ZStack {
                        Circle().fill(AloTheme.surfaceRaised)
                        if let imageUrl = app.api.absoluteURL(url), !url.isEmpty {
                            AsyncImage(url: imageUrl) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    Text(initial)
                                        .font(.system(size: size * 0.42, weight: .bold))
                                        .foregroundStyle(AloTheme.accent)
                                }
                            }
                            .clipShape(Circle())
                        } else {
                            Text(initial)
                                .font(.system(size: size * 0.42, weight: .bold))
                                .foregroundStyle(AloTheme.accent)
                        }
                    }
                    .frame(width: size, height: size)
                    .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
                }

                private var initial: String {
                    String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased().ifBlank("A")
                }
            }

            struct AloIconButton: View {
                let systemName: String
                let action: () -> Void

                var body: some View {
                    Button(action: action) {
                        Image(systemName: systemName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AloTheme.text)
                            .frame(width: 46, height: 46)
                            .background {
                                Circle().fill(.ultraThinMaterial)
                                Circle().fill(AloTheme.surfaceRaised.opacity(0.72))
                            }
                            .clipShape(Circle())
                            .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            struct AloPrimaryButton: View {
                let title: String
                var disabled = false
                let action: () -> Void

                var body: some View {
                    Button(action: action) {
                        Text(title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(disabled ? AloTheme.surfaceRaised : AloTheme.accent)
                            .clipShape(Capsule())
                    }
                    .disabled(disabled)
                    .buttonStyle(.plain)
                }
            }

            struct AloTextField: View {
                let placeholder: String
                @Binding var text: String
                var secure = false

                var body: some View {
                    Group {
                        if secure {
                            SecureField(placeholder, text: $text)
                        } else {
                            TextField(placeholder, text: $text)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(AloTheme.text)
                    .padding(.horizontal, 18)
                    .frame(height: 52)
                    .background(AloTheme.surfaceRaised)
                    .clipShape(Capsule())
                }
            }

            struct AloPostCard: View {
                let post: AloPost
                let onLike: () -> Void
                var onComment: () -> Void = {}
                var onAuthor: () -> Void = {}

                @EnvironmentObject private var app: AloAppModel
                @State private var isDeleteConfirmationPresented = false
                @State private var likePulse = false

                private var canDelete: Bool {
                    guard let currentUserId = app.bootstrap?.me.id else { return false }
                    return post.creatorId == currentUserId || post.author.id == currentUserId
                }

                var body: some View {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Button(action: onAuthor) {
                                HStack(spacing: 10) {
                                    AloAvatar(name: post.author.name, url: post.author.avatarUrl, size: 42)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text(post.author.name)
                                                .font(.system(size: 17, weight: .bold))
                                            if post.author.verified {
                                                Image(systemName: "checkmark.seal.fill")
                                                    .font(.system(size: 15, weight: .bold))
                                                    .foregroundStyle(AloTheme.accent)
                                            }
                                        }
                                        Text(post.author.username.withAtPrefix)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(AloTheme.muted)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(shortDate(post.createdAt))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AloTheme.muted)
                                Button {
                                    isDeleteConfirmationPresented = true
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundStyle(AloTheme.muted)
                                        .frame(width: 34, height: 26)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !post.body.isEmpty {
                            Text(post.body)
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(AloTheme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !post.media.isEmpty {
                            AloPostMediaGrid(media: post.media)
                        }

                        HStack(spacing: 22) {
                            Button {
                                withAnimation(.spring(response: 0.18, dampingFraction: 0.62)) {
                                    likePulse = true
                                }
                                onLike()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                                    withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                                        likePulse = false
                                    }
                                }
                            } label: {
                                Label("\(post.likeCount)", systemImage: post.viewerLiked ? "heart.fill" : "heart")
                                    .foregroundStyle(post.viewerLiked ? Color(red: 1, green: 0.32, blue: 0.42) : AloTheme.muted)
                            }
                            .scaleEffect(likePulse ? 1.16 : 1)
                            Button(action: onComment) {
                                Label("\(post.commentCount)", systemImage: "bubble.left")
                                    .foregroundStyle(AloTheme.muted)
                            }
                            Label("\(post.repostCount)", systemImage: "arrow.2.squarepath")
                                .foregroundStyle(AloTheme.muted)
                            Spacer()
                            Label("\(post.viewCount)", systemImage: "eye")
                                .foregroundStyle(AloTheme.muted)
                        }
                        .font(.system(size: 15, weight: .semibold))
                    }
                    .padding(14)
                    .aloCard(radius: 22)
                    .confirmationDialog(
                        "Пост",
                        isPresented: $isDeleteConfirmationPresented,
                        titleVisibility: .visible
                    ) {
                        Button("Скопировать ссылку") {
                            copyPostLink()
                        }
                        if canDelete {
                            Button("Удалить пост", role: .destructive) {
                                app.deletePost(post)
                            }
                        }
                        Button("Отмена", role: .cancel) {}
                    }
                }

                private func copyPostLink() {
                    UIPasteboard.general.string = app.api.appURL("/posts/\(post.id)").absoluteString
                    app.notice = "Ссылка на пост скопирована."
                }

                private func shortDate(_ raw: String) -> String {
                    let value = String(raw.prefix(10))
                    guard value.count == 10 else { return value }
                    return String(value.suffix(5))
                }
            }

            struct AloPostMediaGrid: View {
                let media: [AloMediaItem]

                @EnvironmentObject private var app: AloAppModel
                @State private var selectedMedia: AloMediaItem?

                var body: some View {
                    Group {
                        switch media.count {
                        case 0:
                            EmptyView()
                        case 1:
                            mediaCell(media[0])
                                .frame(maxWidth: .infinity)
                                .frame(height: 260)
                        case 2:
                            HStack(spacing: 2) {
                                mediaCell(media[0])
                                    .frame(maxWidth: .infinity)
                                mediaCell(media[1])
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(height: 230)
                        case 3:
                            HStack(spacing: 2) {
                                mediaCell(media[0])
                                    .frame(maxWidth: .infinity)
                                VStack(spacing: 2) {
                                    mediaCell(media[1])
                                        .frame(maxWidth: .infinity)
                                    mediaCell(media[2])
                                        .frame(maxWidth: .infinity)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .frame(height: 270)
                        default:
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                                ForEach(media.prefix(4)) { item in
                                    mediaCell(item)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 145)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .fullScreenCover(item: $selectedMedia) { item in
                        AloPostMediaViewer(
                            media: media,
                            startItem: item,
                            onDismiss: { selectedMedia = nil }
                        )
                        .environmentObject(app)
                    }
                }

                private func mediaCell(_ item: AloMediaItem) -> some View {
                    GeometryReader { proxy in
                        ZStack {
                            AloTheme.background
                            if let url = app.api.absoluteURL(item.posterUrl.ifBlank(item.url)) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: proxy.size.width, height: proxy.size.height)
                                            .clipped()
                                    default:
                                        ProgressView().tint(AloTheme.accent)
                                    }
                                }
                            }
                            if item.type == "video" {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 52, height: 52)
                                    .background(Color.black.opacity(0.45))
                                    .clipShape(Circle())
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedMedia = item
                        }
                    }
                    .clipped()
                }
            }

            private struct AloPostMediaViewer: View {
                let media: [AloMediaItem]
                let startItem: AloMediaItem
                let onDismiss: () -> Void

                @EnvironmentObject private var app: AloAppModel
                @Environment(\.openURL) private var openURL
                @State private var selectedURL: String
                @State private var notice: String?

                init(media: [AloMediaItem], startItem: AloMediaItem, onDismiss: @escaping () -> Void) {
                    self.media = media
                    self.startItem = startItem
                    self.onDismiss = onDismiss
                    _selectedURL = State(initialValue: startItem.url)
                }

                var body: some View {
                    ZStack {
                        Color.black.ignoresSafeArea()

                        TabView(selection: $selectedURL) {
                            ForEach(media) { item in
                                viewerContent(for: item)
                                    .tag(item.url)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: media.count > 1 ? .automatic : .never))

                        HStack {
                            Spacer()
                            actionRail
                                .padding(.trailing, 16)
                        }

                        VStack {
                            HStack {
                                Button(action: onDismiss) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 30, weight: .bold))
                                        .foregroundStyle(Color.white.opacity(0.88))
                                        .frame(width: 48, height: 48)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Spacer()
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 18)
                            Spacer()
                        }

                        if let notice {
                            VStack {
                                Spacer()
                                Text(notice)
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .frame(height: 40)
                                    .background(Color.white.opacity(0.12))
                                    .clipShape(Capsule())
                                    .padding(.bottom, 42)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                }

                @ViewBuilder
                private func viewerContent(for item: AloMediaItem) -> some View {
                    if let url = app.api.absoluteURL(item.posterUrl.ifBlank(item.url)) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            default:
                                ProgressView()
                                    .tint(AloTheme.accent)
                            }
                        }
                    } else {
                        ProgressView()
                            .tint(AloTheme.accent)
                    }
                }

                private var actionRail: some View {
                    VStack(spacing: 12) {
                        if let url = currentAbsoluteURL {
                            ShareLink(item: url) {
                                railIcon("square.and.arrow.up")
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            copyCurrentLink()
                        } label: {
                            railIcon("link")
                        }
                        .buttonStyle(.plain)

                        Button {
                            saveCurrentMedia()
                        } label: {
                            railIcon("arrow.down.to.line")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                    .background(Color.black.opacity(0.42))
                    .clipShape(Capsule())
                }

                private func railIcon(_ systemName: String) -> some View {
                    Image(systemName: systemName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Circle())
                }

                private var currentItem: AloMediaItem? {
                    media.first(where: { $0.url == selectedURL }) ?? media.first
                }

                private var currentAbsoluteURL: URL? {
                    guard let currentItem else { return nil }
                    return app.api.absoluteURL(currentItem.url)
                }

                private func copyCurrentLink() {
                    guard let url = currentAbsoluteURL else { return }
                    UIPasteboard.general.string = url.absoluteString
                    showNotice("Ссылка скопирована")
                }

                private func saveCurrentMedia() {
                    guard let item = currentItem, let url = currentAbsoluteURL else { return }
                    Task {
                        do {
                            let (localURL, response) = try await URLSession.shared.download(from: url)
                            let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
                            if item.type == "video" || mime.hasPrefix("video/") {
                                UISaveVideoAtPathToSavedPhotosAlbum(localURL.path, nil, nil, nil)
                            } else if let data = try? Data(contentsOf: localURL), let image = UIImage(data: data) {
                                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                            }
                            await MainActor.run { showNotice("Сохранено") }
                        } catch {
                            await MainActor.run { showNotice("Не удалось сохранить") }
                        }
                    }
                }

                private func showNotice(_ value: String) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        notice = value
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        withAnimation(.easeOut(duration: 0.16)) {
                            if notice == value {
                                notice = nil
                            }
                        }
                    }
                }
            }

        }
    }
}
