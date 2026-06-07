import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct FeedView: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var postAttachments = [AloLocalAttachment]()
    @State private var pickedItems = [PhotosPickerItem]()
    @Namespace private var feedModeNamespace

    private var posts: [AloPost] {
        guard let data = app.bootstrap else { return [] }
        return app.feedMode == .popular ? data.feedPopular : data.feedSubscriptions
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                composer
                modePicker
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
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 102)
        }
        .refreshable {
            await app.loadBootstrap()
        }
        .onChange(of: pickedItems) { _, newItems in
            Task { await loadPickedItems(newItems) }
        }
    }

    private var composer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if let me = app.bootstrap?.me {
                    AloAvatar(name: me.name, url: me.avatarUrl, size: 44)
                }
                TextField("Что нового?", text: $app.composeText, axis: .vertical)
                    .foregroundStyle(AloTheme.text)
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 48)
                    .background {
                        Capsule()
                            .fill(AloTheme.surfaceRaised.opacity(0.78))
                    }
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.045), lineWidth: 1)
                    }
            }
            if !postAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(postAttachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                FeedAttachmentPreview(attachment: attachment)
                                Button {
                                    postAttachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 22, height: 22)
                                        .background(Color.black.opacity(0.62))
                                        .clipShape(Circle())
                                }
                                .padding(5)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                PhotosPicker(
                    selection: $pickedItems,
                    maxSelectionCount: 10,
                    matching: .any(of: [.images, .videos])
                ) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AloTheme.muted)
                        .frame(width: 46, height: 46)
                        .background(AloTheme.surfaceRaised.opacity(0.82))
                        .clipShape(Circle())
                        .overlay {
                            Circle().stroke(Color.white.opacity(0.045), lineWidth: 1)
                        }
                }
                Spacer()
                Button {
                    let attachments = postAttachments
                    app.createPost(localAttachments: attachments)
                    postAttachments = []
                    pickedItems = []
                } label: {
                    Text("Опубликовать")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(postDisabled ? AloTheme.muted : Color.white)
                        .frame(minWidth: 164)
                        .frame(height: 46)
                        .background(postDisabled ? AloTheme.surfaceRaised.opacity(0.82) : AloTheme.accent)
                        .clipShape(Capsule())
                        .overlay {
                            Capsule().stroke(Color.white.opacity(postDisabled ? 0.04 : 0), lineWidth: 1)
                        }
                }
                .disabled(postDisabled)
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(AloTheme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.20), radius: 18, x: 0, y: 10)
    }

    private var postDisabled: Bool {
        app.composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && postAttachments.isEmpty
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(AloFeedMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        app.feedMode = mode
                    }
                } label: {
                    Text(feedModeTitle(mode))
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(app.feedMode == mode ? AloTheme.text : AloTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background {
                            if app.feedMode == mode {
                                Capsule()
                                    .fill(AloTheme.surfaceRaised)
                                    .matchedGeometryEffect(id: "feed-mode", in: feedModeNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(AloTheme.surface)
        .clipShape(Capsule())
    }

    private func feedModeTitle(_ mode: AloFeedMode) -> String {
        switch mode {
        case .popular:
            return "Для вас"
        case .subscriptions:
            return "Подписки"
        }
    }

    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        var next = [AloLocalAttachment]()
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let contentType = item.supportedContentTypes.first
            let isVideo = contentType?.conforms(to: .movie) == true || contentType?.conforms(to: .video) == true
            let mime = contentType?.preferredMIMEType ?? (isVideo ? "video/mp4" : "image/jpeg")
            let ext = contentType?.preferredFilenameExtension ?? (isVideo ? "mp4" : "jpg")
            next.append(
                AloLocalAttachment(
                    data: data,
                    mime: mime,
                    type: isVideo ? "video" : "image",
                    name: "post-\(index + 1).\(ext)"
                )
            )
        }
        postAttachments = next
    }
}

private struct FeedAttachmentPreview: View {
    let attachment: AloLocalAttachment

    var body: some View {
        ZStack {
            AloTheme.surfaceRaised
            if attachment.type == "image", let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: attachment.type == "video" ? "play.rectangle.fill" : "doc.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AloTheme.text)
            }
        }
        .frame(width: 86, height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CommentsSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deleteCandidate: AloPostComment?

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(AloTheme.muted.opacity(0.55))
                .frame(width: 54, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)

            if let post = app.commentsPost {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        AloPostCard(post: post) {
                            app.toggleLike(post)
                        } onComment: {} onAuthor: {
                            dismiss()
                            app.openProfile(post.author)
                        }
                        .padding(.horizontal, 12)

                        if app.commentsLoading {
                            ProgressView().tint(AloTheme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        } else if app.comments.isEmpty {
                            ContentUnavailableView(
                                "Комментариев пока нет",
                                systemImage: "bubble.left",
                                description: Text("Будь первым в обсуждении.")
                            )
                            .foregroundStyle(AloTheme.muted)
                            .padding(.vertical, 28)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(app.comments) { comment in
                                    CommentRow(
                                        comment: comment,
                                        isMine: comment.author.id == app.bootstrap?.me.id,
                                        onLike: { app.toggleCommentLike(comment) },
                                        onAuthor: {
                                            dismiss()
                                            app.openProfile(comment.author)
                                        },
                                        onDelete: { deleteCandidate = comment }
                                    )
                                    Divider().background(AloTheme.border).padding(.leading, 72)
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.bottom, 86)
                }
            }

            commentComposer
        }
        .background(AloTheme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .confirmationDialog("Комментарий", isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let deleteCandidate {
                    app.deleteComment(deleteCandidate)
                }
                deleteCandidate = nil
            }
            Button("Отмена", role: .cancel) {
                deleteCandidate = nil
            }
        }
        .onDisappear {
            if app.commentsPost != nil {
                app.closeComments()
            }
        }
    }

    private var commentComposer: some View {
        HStack(spacing: 10) {
            TextField("Комментарий", text: $app.commentText, axis: .vertical)
                .foregroundStyle(AloTheme.text)
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .background(AloTheme.surface)
                .clipShape(Capsule())
            Button {
                app.createComment()
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(app.commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AloTheme.surfaceRaised : AloTheme.accent)
                    .clipShape(Circle())
            }
            .disabled(app.commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AloTheme.background.opacity(0.98))
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { deleteCandidate != nil },
            set: { presented in
                if !presented { deleteCandidate = nil }
            }
        )
    }
}

private struct CommentRow: View {
    let comment: AloPostComment
    let isMine: Bool
    let onLike: () -> Void
    let onAuthor: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onAuthor) {
                AloAvatar(name: comment.author.name, url: comment.author.avatarUrl, size: 46)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Button(action: onAuthor) {
                    HStack(spacing: 5) {
                        Text(comment.author.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AloTheme.text)
                        if comment.author.verified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AloTheme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)

                if !comment.body.isEmpty {
                    Text(comment.body)
                        .font(.system(size: 16))
                        .foregroundStyle(AloTheme.text)
                }

                HStack(spacing: 16) {
                    Button(action: onLike) {
                        Label("\(comment.likeCount)", systemImage: comment.viewerLiked ? "heart.fill" : "heart")
                            .foregroundStyle(comment.viewerLiked ? Color(red: 1, green: 0.32, blue: 0.42) : AloTheme.muted)
                    }
                    Text(comment.editedAt.isEmpty ? shortDate(comment.createdAt) : "\(shortDate(comment.createdAt)) · изменено")
                        .foregroundStyle(AloTheme.muted)
                    if isMine {
                        Button("Удалить", role: .destructive, action: onDelete)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func shortDate(_ raw: String) -> String {
        String(raw.prefix(16))
    }
}
