import Foundation
import Combine
import SwiftUI

@MainActor
final class AloAppModel: ObservableObject {
    enum Phase {
        case loading
        case auth
        case app
    }

    enum AuthMode {
        case login
        case register
        case verifyLogin
        case verifyEmail
    }

    struct HumanChallenge: Identifiable {
        let id = UUID()
        let url: URL
        let message: String
    }

    @Published var phase: Phase = .loading
    @Published var authMode: AuthMode = .login
    @Published var email = ""
    @Published var password = ""
    @Published var name = ""
    @Published var username = ""
    @Published var code = ""
    @Published var notice = ""
    @Published var errorMessage = ""
    @Published var isBusy = false
    @Published var bootstrap: AloBootstrapData?
    @Published var activeTab: AloAppTab = .feed
    @Published var feedMode: AloFeedMode = .popular
    @Published var composeText = ""
    @Published var searchQuery = ""
    @Published var activeConversation: AloConversationDetail?
    @Published var messageText = ""
    @Published var pendingForwardDraft: AloForwardMeta?
    @Published var pendingForwardTitle = ""
    @Published var humanChallenge: HumanChallenge?
    @Published var selectedProfile: AloUserProfile?
    @Published var isProfileLoading = false
    @Published var commentsPost: AloPost?
    @Published var comments = [AloPostComment]()
    @Published var commentText = ""
    @Published var commentsLoading = false

    let api = AloAPIClient.shared
    private var challengeToken = ""
    private var pendingChallengeRetry: ((String) -> Void)?
    private var conversationRefreshTask: Task<Void, Never>?
    private var lastTypingSentAt: Date = .distantPast

    func start() {
        Task { await initialBootstrapFlow() }
    }

    func loadBootstrap(showAuthOnUnauthorized: Bool = false, peerId: Int = 0) async {
        isBusy = true
        errorMessage = ""
        do {
            let data = try await api.loadBootstrap(peerId: peerId)
            bootstrap = data
            if peerId > 0, let summary = data.conversations.first(where: { $0.peerId == peerId }) {
                let detail = AloConversationDetail(summary: summary, items: data.activeMessages)
                activeConversation = detail
                startConversationLive(detail)
            }
            phase = .app
        } catch let error as AloAPIError {
            if error.status == 401 && showAuthOnUnauthorized {
                phase = .auth
            } else if error.code == "CONNECTION_FAILED" || error.status == 0 {
                if bootstrap == nil {
                    phase = .loading
                }
            } else {
                errorMessage = error.message
            }
        } catch {
            if bootstrap == nil {
                phase = .loading
            }
        }
        isBusy = false
    }

    func submitAuth() {
        switch authMode {
        case .login:
            submitLogin()
        case .register:
            submitRegister()
        case .verifyLogin:
            verifyLogin()
        case .verifyEmail:
            verifyEmail()
        }
    }

    func submitLogin(captchaToken: String? = nil) {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Введите почту и пароль."
            return
        }
        runAuthTask {
            do {
                let result = try await self.api.login(email: self.email, password: self.password, captchaToken: captchaToken)
                self.challengeToken = result.challengeToken
                self.notice = result.message
                self.code = ""
                self.authMode = .verifyLogin
            } catch let error as AloAPIError {
                if self.handleChallenge(error, retry: { token in self.submitLogin(captchaToken: token) }) { return }
                self.errorMessage = error.message
            } catch {
                self.errorMessage = "Не удалось подключиться к серверу."
            }
        }
    }

    func submitRegister(captchaToken: String? = nil) {
        guard !name.isEmpty, !username.isEmpty, !email.isEmpty, !password.isEmpty else {
            errorMessage = "Заполните все поля."
            return
        }
        runAuthTask {
            do {
                self.notice = try await self.api.register(
                    name: self.name,
                    username: self.username,
                    email: self.email,
                    password: self.password,
                    captchaToken: captchaToken
                )
                self.code = ""
                self.authMode = .verifyEmail
            } catch let error as AloAPIError {
                if self.handleChallenge(error, retry: { token in self.submitRegister(captchaToken: token) }) { return }
                self.errorMessage = error.message
            } catch {
                self.errorMessage = "Не удалось подключиться к серверу."
            }
        }
    }

    func verifyLogin() {
        runAuthTask {
            do {
                try await self.api.verifyLogin(email: self.email, code: self.code, challengeToken: self.challengeToken)
                await self.loadBootstrap()
            } catch let error as AloAPIError {
                self.errorMessage = error.message
            } catch {
                self.errorMessage = "Не удалось подключиться к серверу."
            }
        }
    }

    func verifyEmail() {
        runAuthTask {
            do {
                try await self.api.verifyEmail(email: self.email, code: self.code)
                await self.loadBootstrap()
            } catch let error as AloAPIError {
                self.errorMessage = error.message
            } catch {
                self.errorMessage = "Не удалось подключиться к серверу."
            }
        }
    }

    func logout() {
        Task {
            isBusy = true
            _ = try? await api.logout()
            api.clearCookies()
            bootstrap = nil
            activeConversation = nil
            selectedProfile = nil
            commentsPost = nil
            comments = []
            composeText = ""
            messageText = ""
            commentText = ""
            pendingForwardDraft = nil
            pendingForwardTitle = ""
            code = ""
            password = ""
            notice = "Вы вышли из аккаунта."
            errorMessage = ""
            activeTab = .feed
            authMode = .login
            phase = .auth
            isBusy = false
        }
    }

    func createPost(localAttachments: [AloLocalAttachment] = [], captchaToken: String? = nil) {
        let body = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !localAttachments.isEmpty else { return }
        Task {
            isBusy = true
            do {
                var media = [AloMessageAttachment]()
                for attachment in localAttachments {
                    media.append(try await api.uploadAttachment(attachment, purpose: "post"))
                }
                let post = try await api.createPost(body: body, media: media, captchaToken: captchaToken)
                composeText = ""
                if let data = bootstrap {
                    bootstrap = AloBootstrapDataPatch.prepend(post, to: data)
                }
            } catch let error as AloAPIError {
                if handleChallenge(error, retry: { token in self.createPost(localAttachments: localAttachments, captchaToken: token) }) { return }
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось опубликовать пост."
            }
            isBusy = false
        }
    }

    func toggleLike(_ post: AloPost) {
        Task {
            do {
                let updated = try await api.toggleLike(postId: post.id)
                if let data = bootstrap {
                    bootstrap = AloBootstrapDataPatch.replace(updated, in: data)
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить лайк."
            }
        }
    }

    func deletePost(_ post: AloPost) {
        Task {
            do {
                let deletedId = try await api.deletePost(postId: post.id)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    removePost(id: deletedId)
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось удалить пост."
            }
        }
    }

    func openConversation(_ summary: AloConversationSummary) {
        activeTab = .messages
        Task {
            do {
                let detail = try await api.loadConversation(peerId: summary.peerId)
                activeConversation = detail
                startConversationLive(detail)
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось открыть чат."
            }
        }
    }

    func closeConversation() {
        stopConversationLive()
        activeConversation = nil
    }

    func toggleMessageReaction(_ message: AloChatMessage, emoji: String) {
        guard let conversation = activeConversation else { return }
        Task {
            do {
                let reactions = try await api.toggleMessageReaction(
                    conversation: conversation,
                    messageId: message.id,
                    emoji: emoji
                )
                let updatedMessage = message.replacingReactions(reactions)
                if let activeConversation {
                    self.activeConversation = activeConversation.replacingMessage(updatedMessage)
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось поставить реакцию."
            }
        }
    }

    func editMessage(_ message: AloChatMessage, body: String, onDone: (() -> Void)? = nil) {
        guard let conversation = activeConversation else { return }
        let nextBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextBody.isEmpty else { return }
        Task {
            do {
                let result = try await api.editMessage(
                    conversation: conversation,
                    messageId: message.id,
                    body: nextBody
                )
                if let activeConversation {
                    let updatedMessage = message.replacingBody(result.body, editedAt: result.editedAt)
                    self.activeConversation = activeConversation.replacingMessage(updatedMessage)
                }
                await loadBootstrap(peerId: conversation.peerId)
                onDone?()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось изменить сообщение."
            }
        }
    }

    func openProfile(_ user: AloEntitySummary) {
        guard !user.isChannel else {
            notice = "Профили пабликов подключу отдельным экраном."
            return
        }
        openProfile(userId: user.id)
    }

    func openProfile(userId: Int) {
        guard userId > 0 else { return }
        Task {
            isProfileLoading = true
            do {
                selectedProfile = try await api.loadUserProfile(userId: userId)
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось открыть профиль."
            }
            isProfileLoading = false
        }
    }

    func closeProfile() {
        selectedProfile = nil
    }

    func openConversation(with profile: AloUserProfile) {
        closeProfile()
        activeTab = .messages
        Task {
            do {
                let detail = try await api.loadConversation(peerId: profile.user.id)
                activeConversation = detail
                startConversationLive(detail)
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось открыть чат."
            }
        }
    }

    func sendMessage(
        localAttachments: [AloLocalAttachment] = [],
        forwardFrom: AloForwardMeta? = nil,
        captchaToken: String? = nil,
        onSent: (() -> Void)? = nil
    ) {
        guard let conversation = activeConversation else { return }
        let body = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !localAttachments.isEmpty || forwardFrom != nil else { return }
        Task {
            isBusy = true
            do {
                var uploadedAttachments = [AloMessageAttachment]()
                for attachment in localAttachments {
                    uploadedAttachments.append(try await api.uploadAttachment(attachment))
                }
                try await api.sendMessage(
                    peerId: conversation.peerId,
                    roomId: conversation.roomId,
                    kind: conversation.kind,
                    body: body,
                    attachments: uploadedAttachments,
                    forwardFrom: forwardFrom,
                    captchaToken: captchaToken
                )
                messageText = ""
                activeConversation = try await api.loadConversation(peerId: conversation.peerId)
                await loadBootstrap(peerId: conversation.peerId)
                onSent?()
            } catch let error as AloAPIError {
                if handleChallenge(error, retry: { token in
                    self.sendMessage(
                        localAttachments: localAttachments,
                        forwardFrom: forwardFrom,
                        captchaToken: token,
                        onSent: onSent
                    )
                }) { return }
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось отправить сообщение."
            }
            isBusy = false
        }
    }

    func startConversationLive(_ conversation: AloConversationDetail) {
        stopConversationLive(sendPresenceLeave: false)
        let peerId = conversation.peerId
        let roomId = conversation.roomId
        let kind = conversation.kind
        conversationRefreshTask = Task { [weak self] in
            await self?.sendChatPresence(for: conversation)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                await self?.refreshActiveConversation(peerId: peerId, roomId: roomId, kind: kind)
            }
        }
    }

    func stopConversationLive(sendPresenceLeave: Bool = true) {
        conversationRefreshTask?.cancel()
        conversationRefreshTask = nil
        if sendPresenceLeave {
            Task { try? await api.updateChatPresence(activePeerId: 0) }
        }
    }

    func sendTypingIfNeeded() {
        guard let conversation = activeConversation else { return }
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTypingSentAt) > 1.4 else { return }
        lastTypingSentAt = now
        Task {
            try? await api.sendTyping(conversation: conversation)
        }
    }

    private func sendChatPresence(for conversation: AloConversationDetail) async {
        let activePeerId = conversation.kind == "direct" ? conversation.peerId : 0
        try? await api.updateChatPresence(activePeerId: activePeerId)
    }

    private func refreshActiveConversation(peerId: Int, roomId: Int, kind: String) async {
        guard let current = activeConversation,
              current.peerId == peerId,
              current.roomId == roomId,
              current.kind == kind else { return }
        do {
            activeConversation = try await api.loadConversation(peerId: peerId)
        } catch {
            // Live refresh should be quiet; explicit user actions still surface errors.
        }
    }

    func deleteMessages(_ ids: [Int], mode: String = "me", onDone: (() -> Void)? = nil) {
        guard let conversation = activeConversation else { return }
        Task {
            do {
                try await api.deleteMessages(messageIds: ids, conversation: conversation, mode: mode)
                activeConversation = try await api.loadConversation(peerId: conversation.peerId)
                await loadBootstrap(peerId: conversation.peerId)
                onDone?()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось удалить сообщения."
            }
        }
    }

    func sendFriendRequest(_ user: AloEntitySummary, captchaToken: String? = nil) {
        sendFriendRequest(userId: user.id, captchaToken: captchaToken)
    }

    func sendFriendRequest(userId: Int, captchaToken: String? = nil) {
        Task {
            do {
                _ = try await api.sendFriendRequest(userId: userId, captchaToken: captchaToken)
                notice = "Заявка отправлена."
                await loadBootstrap()
                if selectedProfile?.id == userId {
                    selectedProfile = try? await api.loadUserProfile(userId: userId)
                }
            } catch let error as AloAPIError {
                if handleChallenge(error, retry: { token in self.sendFriendRequest(userId: userId, captchaToken: token) }) { return }
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось отправить заявку."
            }
        }
    }

    func toggleFollowUser(userId: Int) {
        Task {
            do {
                let following = try await api.toggleFollowUser(userId: userId)
                notice = following ? "Подписка оформлена." : "Подписка отменена."
                await loadBootstrap()
                if selectedProfile?.id == userId {
                    selectedProfile = try? await api.loadUserProfile(userId: userId)
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось изменить подписку."
            }
        }
    }

    func respondFriendRequest(_ item: AloNotificationItem, accept: Bool) {
        guard item.actionableFriendRequestId > 0 else { return }
        respondFriendRequest(requestId: item.actionableFriendRequestId, accept: accept)
    }

    func respondFriendRequest(requestId: Int, accept: Bool) {
        Task {
            do {
                _ = try await api.respondFriendRequest(requestId: requestId, accept: accept)
                await loadBootstrap()
                if let profile = selectedProfile {
                    selectedProfile = try? await api.loadUserProfile(userId: profile.id)
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить заявку."
            }
        }
    }

    func updateProfileCover(style: String) {
        Task {
            do {
                let updated = try await api.updateProfileCover(coverStyle: style)
                if let data = bootstrap {
                    bootstrap = AloBootstrapDataPatch.replaceMe(updated, in: data)
                }
                if selectedProfile?.id == updated.id {
                    selectedProfile = try? await api.loadUserProfile(userId: updated.id)
                }
                await loadBootstrap()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить баннер."
            }
        }
    }

    func updateProfileAvatar(data: Data, mime: String = "image/jpeg") {
        Task {
            do {
                let attachment = AloLocalAttachment(
                    data: data,
                    mime: mime,
                    type: "image",
                    name: "profile-avatar.jpg"
                )
                let uploaded = try await api.uploadAttachment(attachment, purpose: "avatar")
                let updated = try await api.updateProfileAvatar(avatarUrl: uploaded.url)
                if let data = bootstrap {
                    bootstrap = AloBootstrapDataPatch.replaceMe(updated, in: data)
                }
                if selectedProfile?.id == updated.id {
                    selectedProfile = try? await api.loadUserProfile(userId: updated.id)
                }
                await loadBootstrap()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить аватар."
            }
        }
    }

    func updateGroupAvatar(conversation: AloConversationDetail, data: Data, mime: String = "image/jpeg") {
        guard conversation.kind == "group", conversation.roomId > 0 else { return }
        Task {
            do {
                let attachment = AloLocalAttachment(
                    data: data,
                    mime: mime,
                    type: "image",
                    name: "group-avatar-\(conversation.roomId).jpg"
                )
                let uploaded = try await api.uploadAttachment(attachment, purpose: "avatar")
                activeConversation = try await api.updateGroupChatProfile(
                    roomId: conversation.roomId,
                    title: conversation.title,
                    avatarUrl: uploaded.url
                )
                await loadBootstrap(peerId: conversation.peerId)
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить аватарку группы."
            }
        }
    }

    func leaveGroupChat(_ conversation: AloConversationDetail) {
        guard conversation.kind == "group", conversation.roomId > 0 else { return }
        Task {
            do {
                try await api.leaveGroupChat(roomId: conversation.roomId)
                closeConversation()
                await loadBootstrap()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось покинуть группу."
            }
        }
    }

    func deleteGroupChat(_ conversation: AloConversationDetail) {
        guard conversation.kind == "group", conversation.roomId > 0 else { return }
        Task {
            do {
                try await api.deleteGroupChat(roomId: conversation.roomId)
                closeConversation()
                await loadBootstrap()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось удалить группу."
            }
        }
    }

    func updatePrivacy(profileVisibility: String) {
        let current = bootstrap?.privacySettings ?? .default
        updatePrivacy(settings: AloPrivacySettings(
            allowFriendRequests: current.allowFriendRequests,
            messageScope: current.messageScope,
            allowMessageForwards: current.allowMessageForwards,
            callScope: current.callScope,
            profileVisibility: profileVisibility,
            hideActivity: current.hideActivity
        ))
    }

    func updatePrivacy(settings: AloPrivacySettings) {
        Task {
            do {
                _ = try await api.updatePrivacy(settings: settings)
                await loadBootstrap()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить приватность."
            }
        }
    }

    func openComments(for post: AloPost) {
        commentsPost = post
        commentText = ""
        Task { await loadComments(for: post.id) }
    }

    func closeComments() {
        commentsPost = nil
        comments = []
        commentText = ""
    }

    func loadComments(for postId: Int) async {
        commentsLoading = true
        do {
            comments = try await api.loadPostComments(postId: postId)
        } catch let error as AloAPIError {
            errorMessage = error.message
        } catch {
            errorMessage = "Не удалось загрузить комментарии."
        }
        commentsLoading = false
    }

    func createComment(captchaToken: String? = nil) {
        guard let post = commentsPost else { return }
        let body = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Task {
            do {
                let result = try await api.createComment(postId: post.id, body: body, captchaToken: captchaToken)
                commentText = ""
                comments.append(result.comment)
                if let updatedPost = result.post {
                    replacePost(updatedPost)
                    commentsPost = updatedPost
                }
            } catch let error as AloAPIError {
                if handleChallenge(error, retry: { token in self.createComment(captchaToken: token) }) { return }
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось отправить комментарий."
            }
        }
    }

    func toggleCommentLike(_ comment: AloPostComment) {
        guard let post = commentsPost else { return }
        Task {
            do {
                let updated = try await api.toggleCommentLike(postId: post.id, commentId: comment.id)
                comments = comments.map { $0.id == updated.id ? updated : $0 }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить лайк."
            }
        }
    }

    func deleteComment(_ comment: AloPostComment) {
        guard let post = commentsPost else { return }
        Task {
            do {
                let updatedPost = try await api.deleteComment(postId: post.id, commentId: comment.id)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    comments.removeAll { $0.id == comment.id }
                }
                if let updatedPost {
                    replacePost(updatedPost)
                    commentsPost = updatedPost
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось удалить комментарий."
            }
        }
    }

    func completeChallenge(token: String) {
        let retry = pendingChallengeRetry
        pendingChallengeRetry = nil
        humanChallenge = nil
        retry?(token)
    }

    func closeChallenge() {
        pendingChallengeRetry = nil
        humanChallenge = nil
    }

    private func runAuthTask(_ operation: @escaping () async -> Void) {
        isBusy = true
        errorMessage = ""
        notice = ""
        Task {
            await operation()
            isBusy = false
        }
    }

    private func replacePost(_ post: AloPost) {
        if let data = bootstrap {
            bootstrap = AloBootstrapDataPatch.replace(post, in: data)
        }
        if selectedProfile?.posts.contains(where: { $0.id == post.id }) == true,
           let profile = selectedProfile {
            selectedProfile = AloUserProfilePatch.replace(post, in: profile)
        }
    }

    private func removePost(id postId: Int) {
        if let data = bootstrap {
            bootstrap = AloBootstrapDataPatch.remove(postId, from: data)
        }
        if let profile = selectedProfile {
            selectedProfile = AloUserProfilePatch.remove(postId, from: profile)
        }
        if commentsPost?.id == postId {
            commentsPost = nil
            comments = []
        }
    }

    private func initialBootstrapFlow() async {
        phase = .loading
        errorMessage = ""

        for attempt in 0..<4 {
            do {
                let data = try await api.loadBootstrap()
                bootstrap = data
                phase = .app
                isBusy = false
                return
            } catch let error as AloAPIError {
                if error.status == 401 {
                    phase = .auth
                    isBusy = false
                    return
                }

                if attempt == 3 {
                    errorMessage = ""
                    phase = .loading
                    isBusy = false
                    return
                }
            } catch {
                if attempt == 3 {
                    errorMessage = ""
                    phase = .loading
                    isBusy = false
                    return
                }
            }

            try? await Task.sleep(nanoseconds: 900_000_000)
        }
    }

    private func handleChallenge(_ error: AloAPIError, retry: @escaping (String) -> Void) -> Bool {
        guard error.code == "CHALLENGE_REQUIRED" else { return false }
        pendingChallengeRetry = retry
        humanChallenge = HumanChallenge(
            url: api.absoluteURL("/auth/turnstile-mobile.html")!,
            message: error.message.ifBlank("Подтвердите, что вы не робот.")
        )
        isBusy = false
        return true
    }
}

private enum AloUserProfilePatch {
    static func replace(_ post: AloPost, in profile: AloUserProfile) -> AloUserProfile {
        AloUserProfile(
            id: profile.id,
            user: profile.user,
            stats: profile.stats,
            posts: profile.posts.map { $0.id == post.id ? post : $0 },
            likes: profile.likes,
            relation: profile.relation,
            permissions: profile.permissions
        )
    }

    static func remove(_ postId: Int, from profile: AloUserProfile) -> AloUserProfile {
        AloUserProfile(
            id: profile.id,
            user: profile.user,
            stats: profile.stats,
            posts: profile.posts.filter { $0.id != postId },
            likes: profile.likes.filter { $0.id != postId },
            relation: profile.relation,
            permissions: profile.permissions
        )
    }
}

private enum AloBootstrapDataPatch {
    static func prepend(_ post: AloPost, to data: AloBootstrapData) -> AloBootstrapData {
        build(
            from: data,
            feedPopular: [post] + data.feedPopular.filter { $0.id != post.id },
            feedSubscriptions: [post] + data.feedSubscriptions.filter { $0.id != post.id },
            profilePosts: [post] + data.profilePosts.filter { $0.id != post.id }
        )
    }

    static func replace(_ post: AloPost, in data: AloBootstrapData) -> AloBootstrapData {
        build(
            from: data,
            feedPopular: data.feedPopular.map { $0.id == post.id ? post : $0 },
            feedSubscriptions: data.feedSubscriptions.map { $0.id == post.id ? post : $0 },
            profilePosts: data.profilePosts.map { $0.id == post.id ? post : $0 }
        )
    }

    static func remove(_ postId: Int, from data: AloBootstrapData) -> AloBootstrapData {
        build(
            from: data,
            feedPopular: data.feedPopular.filter { $0.id != postId },
            feedSubscriptions: data.feedSubscriptions.filter { $0.id != postId },
            profilePosts: data.profilePosts.filter { $0.id != postId }
        )
    }

    private static func build(
        from data: AloBootstrapData,
        feedPopular: [AloPost],
        feedSubscriptions: [AloPost],
        profilePosts: [AloPost]
    ) -> AloBootstrapData {
        AloBootstrapData(
            me: data.me,
            feedPopular: feedPopular,
            feedSubscriptions: feedSubscriptions,
            notifications: data.notifications,
            searchUsers: data.searchUsers,
            searchChannels: data.searchChannels,
            profileStats: data.profileStats,
            profilePosts: profilePosts,
            privacySettings: data.privacySettings,
            conversations: data.conversations,
            activePeerId: data.activePeerId,
            activeMessages: data.activeMessages
        )
    }

    static func replaceMe(_ user: AloCurrentUser, in data: AloBootstrapData) -> AloBootstrapData {
        AloBootstrapData(
            me: user,
            feedPopular: data.feedPopular,
            feedSubscriptions: data.feedSubscriptions,
            notifications: data.notifications,
            searchUsers: data.searchUsers,
            searchChannels: data.searchChannels,
            profileStats: data.profileStats,
            profilePosts: data.profilePosts,
            privacySettings: data.privacySettings,
            conversations: data.conversations,
            activePeerId: data.activePeerId,
            activeMessages: data.activeMessages
        )
    }
}
