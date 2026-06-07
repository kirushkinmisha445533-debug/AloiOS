import Foundation

struct AloAPIError: Error, Identifiable {
    let id = UUID()
    let status: Int
    let code: String
    let message: String
    let payload: [String: Any]
}

final class AloAPIClient {
    static let shared = AloAPIClient()

    var baseURL: URL { activeBaseURL }

    private let baseURLs: [URL]
    private var activeBaseURL: URL
    private let session: URLSession

    init(baseURLs: [URL] = AloEnvironment.baseURLs) {
        let normalizedBaseURLs = baseURLs.isEmpty ? [URL(string: "http://127.0.0.1:3000/")!] : baseURLs
        self.baseURLs = normalizedBaseURLs
        self.activeBaseURL = normalizedBaseURLs[0]
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    func absoluteURL(_ path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        return URL(string: path, relativeTo: activeBaseURL)?.absoluteURL
    }

    func appURL(_ path: String) -> URL {
        absoluteURL(path) ?? activeBaseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func login(email: String, password: String, captchaToken: String? = nil) async throws -> (challengeToken: String, message: String) {
        let json = try await request(
            "POST",
            "/api/auth/login",
            body: compactBody([
                "email": email,
                "password": password,
                "captchaToken": captchaToken
            ])
        )
        return (json.string("challengeToken"), json.string("message").ifBlank("Код отправлен на почту."))
    }

    func verifyLogin(email: String, code: String, challengeToken: String) async throws {
        _ = try await request(
            "POST",
            "/api/auth/verify-login",
            body: [
                "email": email,
                "code": code,
                "challengeToken": challengeToken
            ]
        )
    }

    func logout() async throws {
        _ = try await request("POST", "/api/auth/logout")
    }

    func clearCookies() {
        HTTPCookieStorage.shared.cookies?.forEach { cookie in
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    func register(name: String, username: String, email: String, password: String, captchaToken: String? = nil) async throws -> String {
        let json = try await request(
            "POST",
            "/api/auth/register",
            body: compactBody([
                "name": name,
                "username": username,
                "email": email,
                "password": password,
                "skipAvatar": true,
                "captchaToken": captchaToken
            ])
        )
        return json.string("message").ifBlank("Код отправлен на почту.")
    }

    func verifyEmail(email: String, code: String) async throws {
        _ = try await request(
            "POST",
            "/api/auth/verify-email",
            body: [
                "email": email,
                "code": code
            ]
        )
    }

    func loadBootstrap(peerId: Int = 0) async throws -> AloBootstrapData {
        let path = peerId > 0 ? "/api/app/bootstrap?peerId=\(peerId)" : "/api/app/bootstrap"
        return AloBootstrapData(try await request("GET", path))
    }

    func createPost(body: String, media: [AloMessageAttachment] = [], captchaToken: String? = nil) async throws -> AloPost {
        let json = try await request(
            "POST",
            "/api/posts",
            body: compactBody([
                "body": body,
                "media": media.map { ["type": $0.type, "url": $0.url, "name": $0.name] },
                "captchaToken": captchaToken
            ])
        )
        return AloPost(json.object("post"))
    }

    func toggleLike(postId: Int) async throws -> AloPost {
        let json = try await request("POST", "/api/posts/\(postId)/like")
        return AloPost(json.object("post"))
    }

    func deletePost(postId: Int) async throws -> Int {
        let json = try await request("DELETE", "/api/posts/\(postId)")
        return json.int("deletedPostId").ifZero(postId)
    }

    func loadConversation(peerId: Int) async throws -> AloConversationDetail {
        AloConversationDetail(peerId: peerId, json: try await request("GET", "/api/messages/\(peerId)"))
    }

    func updateChatPresence(activePeerId: Int) async throws {
        _ = try await request(
            "POST",
            "/api/chat/presence",
            body: ["activePeerId": activePeerId]
        )
    }

    func sendTyping(conversation: AloConversationDetail) async throws {
        _ = try await request(
            "POST",
            "/api/chat/typing",
            body: [
                "kind": conversation.kind,
                "peerId": conversation.peerId,
                "roomId": conversation.roomId
            ]
        )
    }

    func uploadAttachment(_ attachment: AloLocalAttachment, purpose: String = "message") async throws -> AloMessageAttachment {
        let json = try await request(
            "POST",
            "/api/uploads",
            body: [
                "purpose": purpose,
                "dataUrl": attachment.dataUrl
            ]
        )
        let file = json.object("file")
        return AloMessageAttachment([
            "type": file.string("type").ifBlank(attachment.type),
            "url": file.string("url"),
            "name": attachment.name,
            "waveform": attachment.waveform
        ])
    }

    func loadUserProfile(userId: Int) async throws -> AloUserProfile {
        AloUserProfile(try await request("GET", "/api/users/\(userId)/profile"))
    }

    func updateProfileCover(coverStyle: String) async throws -> AloCurrentUser {
        let json = try await request(
            "PATCH",
            "/api/profile/cover",
            body: ["coverStyle": coverStyle]
        )
        return AloCurrentUser(json.object("user"))
    }

    func updateProfileAvatar(avatarUrl: String) async throws -> AloCurrentUser {
        let json = try await request(
            "PATCH",
            "/api/profile",
            body: ["avatarEmoji": avatarUrl]
        )
        return AloCurrentUser(json.object("user"))
    }

    func updateGroupChatProfile(
        roomId: Int,
        title: String,
        avatarUrl: String? = nil
    ) async throws -> AloConversationDetail {
        var body: [String: Any] = ["title": title]
        if let avatarUrl {
            body["avatarUrl"] = avatarUrl
            body["avatarGallery"] = avatarUrl.isEmpty ? [] : [avatarUrl]
        }
        let json = try await request(
            "PATCH",
            "/api/group-chats/\(roomId)/profile",
            body: body
        )
        let room = json.object("room")
        let peerId = room.int("peerId")
        return try await loadConversation(peerId: peerId)
    }

    func leaveGroupChat(roomId: Int) async throws {
        _ = try await request("POST", "/api/group-chats/\(roomId)/leave")
    }

    func deleteGroupChat(roomId: Int) async throws {
        _ = try await request("DELETE", "/api/group-chats/\(roomId)")
    }

    func updatePrivacy(profileVisibility: String) async throws -> AloPrivacySettings {
        try await updatePrivacy(settings: AloPrivacySettings(
            allowFriendRequests: true,
            messageScope: "all",
            allowMessageForwards: true,
            callScope: "all",
            profileVisibility: profileVisibility,
            hideActivity: false
        ))
    }

    func updatePrivacy(settings: AloPrivacySettings) async throws -> AloPrivacySettings {
        let json = try await request(
            "PATCH",
            "/api/privacy/settings",
            body: settings.requestBody
        )
        return AloPrivacySettings(json.object("settings"))
    }

    func loadPostComments(postId: Int) async throws -> [AloPostComment] {
        let json = try await request("GET", "/api/posts/\(postId)/comments")
        return json.array("comments").map(AloPostComment.init)
    }

    func createComment(
        postId: Int,
        body: String,
        attachments: [AloMessageAttachment] = [],
        captchaToken: String? = nil
    ) async throws -> (comment: AloPostComment, post: AloPost?) {
        let json = try await request(
            "POST",
            "/api/posts/\(postId)/comments",
            body: compactBody([
                "body": body,
                "attachments": attachments.map { ["type": $0.type, "url": $0.url, "name": $0.name] },
                "captchaToken": captchaToken
            ])
        )
        return (AloPostComment(json.object("comment")), json.optionalObject("post").map(AloPost.init))
    }

    func updateComment(postId: Int, commentId: Int, body: String) async throws -> (comment: AloPostComment, post: AloPost?) {
        let json = try await request(
            "PATCH",
            "/api/posts/\(postId)/comments/\(commentId)",
            body: ["body": body]
        )
        return (AloPostComment(json.object("comment")), json.optionalObject("post").map(AloPost.init))
    }

    func deleteComment(postId: Int, commentId: Int) async throws -> AloPost? {
        let json = try await request("DELETE", "/api/posts/\(postId)/comments/\(commentId)")
        return json.optionalObject("post").map(AloPost.init)
    }

    func toggleCommentLike(postId: Int, commentId: Int) async throws -> AloPostComment {
        let json = try await request("POST", "/api/posts/\(postId)/comments/\(commentId)/like")
        return AloPostComment(json.object("comment"))
    }

    func sendMessage(
        peerId: Int,
        roomId: Int,
        kind: String,
        body: String,
        attachments: [AloMessageAttachment] = [],
        forwardFrom: AloForwardMeta? = nil,
        captchaToken: String? = nil
    ) async throws {
        var payload: [String: Any?] = [
            "body": body,
            "attachments": attachments.map(messageAttachmentPayload),
            "captchaToken": captchaToken
        ]
        if let forwardFrom {
            payload["forwardFrom"] = [
                "userId": forwardFrom.userId,
                "messageId": forwardFrom.messageId
            ]
        }
        if kind == "group", roomId > 0 {
            _ = try await request(
                "POST",
                "/api/group-chats/\(roomId)/messages/send",
                body: compactBody(payload)
            )
        } else {
            payload["peerId"] = peerId
            _ = try await request("POST", "/api/messages/send", body: compactBody(payload))
        }
    }

    func toggleMessageReaction(
        conversation: AloConversationDetail,
        messageId: Int,
        emoji: String
    ) async throws -> [AloMessageReaction] {
        let path = conversation.kind == "group" && conversation.roomId > 0
            ? "/api/group-chats/\(conversation.roomId)/messages/\(messageId)/reactions/toggle"
            : "/api/messages/\(messageId)/reactions/toggle"
        let json = try await request(
            "POST",
            path,
            body: ["emoji": emoji]
        )
        return json.array("reactions").map(AloMessageReaction.init)
    }

    func editMessage(
        conversation: AloConversationDetail,
        messageId: Int,
        body: String
    ) async throws -> (body: String, editedAt: String) {
        let path = conversation.kind == "group" && conversation.roomId > 0
            ? "/api/group-chats/\(conversation.roomId)/messages/\(messageId)/edit"
            : "/api/messages/\(messageId)/edit"
        let json = try await request("POST", path, body: ["body": body])
        let message = json.object("message")
        return (
            message.string("body").ifBlank(body),
            message.string("editedAt")
        )
    }

    func deleteMessages(messageIds: [Int], conversation: AloConversationDetail, mode: String = "me") async throws {
        let ids = Array(Set(messageIds)).filter { $0 > 0 }
        guard !ids.isEmpty else { return }
        if conversation.kind == "group", conversation.roomId > 0 {
            _ = try await request(
                "POST",
                "/api/group-chats/\(conversation.roomId)/messages/delete-batch",
                body: [
                    "messageIds": ids,
                    "mode": mode
                ]
            )
        } else {
            _ = try await request(
                "POST",
                "/api/messages/delete-batch",
                body: [
                    "messageIds": ids,
                    "mode": mode
                ]
            )
        }
    }

    func sendFriendRequest(userId: Int, captchaToken: String? = nil) async throws -> String {
        let json = try await request(
            "POST",
            "/api/friends/request",
            body: compactBody([
                "userId": userId,
                "captchaToken": captchaToken
            ])
        )
        return json.string("status").ifBlank("outgoing")
    }

    func toggleFollowUser(userId: Int) async throws -> Bool {
        let json = try await request("POST", "/api/users/\(userId)/follow", body: [:])
        return json.bool("following")
    }

    func respondFriendRequest(requestId: Int, accept: Bool) async throws -> String {
        let json = try await request("POST", "/api/friends/\(requestId)/\(accept ? "accept" : "decline")", body: [:])
        return json.string("status")
    }

    @discardableResult
    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let candidates = candidateURLs(for: path)
        guard !candidates.isEmpty else {
            throw AloAPIError(status: 0, code: "BAD_URL", message: "Некорректный адрес API.", payload: [:])
        }

        var lastConnectionError: Error?
        for candidate in candidates {
            do {
                var request = URLRequest(url: candidate.url)
                request.httpMethod = method
                request.timeoutInterval = 3
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("AloiOS", forHTTPHeaderField: "X-Requested-With")
                if let body {
                    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                }

                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                guard (200..<300).contains(status) else {
                    throw AloAPIError(
                        status: status,
                        code: json.string("code"),
                        message: json.string("error").ifBlank(json.string("message").ifBlank("Ошибка сервера.")),
                        payload: json
                    )
                }
                if let baseURL = candidate.baseURL {
                    activeBaseURL = baseURL
                }
                return json
            } catch let error as AloAPIError {
                throw error
            } catch {
                lastConnectionError = error
                continue
            }
        }

        throw AloAPIError(
            status: 0,
            code: "CONNECTION_FAILED",
            message: connectionErrorMessage(lastConnectionError),
            payload: [:]
        )
    }

    private func candidateURLs(for path: String) -> [(baseURL: URL?, url: URL)] {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path).map { [(nil, $0)] } ?? []
        }
        let orderedBaseURLs = [activeBaseURL] + baseURLs.filter { $0 != activeBaseURL }
        return orderedBaseURLs.compactMap { baseURL in
            guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { return nil }
            return (baseURL, url)
        }
    }

    private func connectionErrorMessage(_ error: Error?) -> String {
        if let error {
            return "Не удалось подключиться к серверу Alo. Проверьте, что сервер запущен и устройство находится в одной сети с Mac. \(error.localizedDescription)"
        }
        return "Не удалось подключиться к серверу Alo."
    }

    private func messageAttachmentPayload(_ attachment: AloMessageAttachment) -> [String: Any] {
        var payload: [String: Any] = [
            "type": attachment.type,
            "url": attachment.url,
            "name": attachment.name
        ]
        if !attachment.waveform.isEmpty {
            payload["waveform"] = attachment.waveform.map { Double($0) }
        }
        return payload
    }

    private func compactBody(_ body: [String: Any?]) -> [String: Any] {
        body.reduce(into: [String: Any]()) { result, pair in
            if let value = pair.value {
                if let string = value as? String, string.isEmpty { return }
                result[pair.key] = value
            }
        }
    }
}

enum AloEnvironment {
    static let baseURLs = [
        URL(string: "http://127.0.0.1:3000/")!,
        URL(string: "http://192.168.0.31:3000/")!,
        URL(string: "http://198.18.0.1:3000/")!
        
        
        
        
    ]
}
