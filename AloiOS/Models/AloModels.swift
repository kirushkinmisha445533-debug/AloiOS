import Foundation

enum AloAppTab: String, CaseIterable, Identifiable {
    case feed
    case search
    case messages
    case alerts
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feed: return "Лента"
        case .search: return "Поиск"
        case .messages: return "Чаты"
        case .alerts: return "Уведы"
        case .profile: return "Профиль"
        }
    }

    var systemImage: String {
        switch self {
        case .feed: return "house.fill"
        case .search: return "magnifyingglass"
        case .messages: return "message"
        case .alerts: return "bell"
        case .profile: return "person"
        }
    }
}

enum AloFeedMode: String, CaseIterable {
    case popular
    case subscriptions
}

struct AloEntitySummary: Identifiable, Equatable {
    let id: Int
    let name: String
    let username: String
    let avatarUrl: String
    let verified: Bool
    let isChannel: Bool
    let relation: AloProfileRelation?

    init(_ json: [String: Any]) {
        id = json.int("id")
        name = json.string("name").ifBlank("Без имени")
        username = json.string("username")
        avatarUrl = json.string("avatarUrl").ifBlank(json.string("avatarEmoji"))
        verified = json.bool("verified") || json.bool("isVerified")
        isChannel = json.bool("isChannel") || json.string("entityType") == "channel"
        relation = json.optionalObject("relation").map(AloProfileRelation.init)
    }
}

struct AloCurrentUser: Identifiable, Equatable {
    let id: Int
    let name: String
    let username: String
    let email: String
    let bio: String
    let avatarUrl: String
    let verified: Bool
    let online: Bool
    let registeredLabel: String
    let coverStyle: String
    let coverImageUrl: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        name = json.string("name").ifBlank("Alo")
        username = json.string("username")
        email = json.string("email")
        bio = json.string("bio")
        avatarUrl = json.string("avatarUrl").ifBlank(json.string("avatarEmoji"))
        verified = json.bool("verified") || json.bool("isVerified")
        online = json.bool("online") || json.bool("isOnline")
        registeredLabel = json.string("registeredLabel")
        coverStyle = json.string("coverStyle").ifBlank("violet")
        coverImageUrl = json.string("coverImageUrl")
    }
}

struct AloMediaItem: Identifiable, Equatable {
    let id = UUID()
    let type: String
    let url: String
    let posterUrl: String
    let caption: String

    init(_ json: [String: Any]) {
        type = json.string("type")
        url = json.string("url")
        posterUrl = json.string("posterUrl")
        caption = json.string("caption").ifBlank(json.string("alt"))
    }
}

struct AloPostComment: Identifiable, Equatable {
    let id: Int
    let body: String
    let media: [AloMediaItem]
    let createdAt: String
    let editedAt: String
    let likeCount: Int
    let viewerLiked: Bool
    let author: AloEntitySummary

    init(_ json: [String: Any]) {
        id = json.int("id")
        body = json.string("body")
        media = json.array("media").map(AloMediaItem.init)
        createdAt = json.string("createdAt")
        editedAt = json.string("editedAt")
        likeCount = json.int("likeCount")
        viewerLiked = json.bool("viewerLiked")
        author = AloEntitySummary(json.object("author"))
    }
}

struct AloMessageAttachment: Identifiable, Equatable {
    let id: String
    let type: String
    let url: String
    let name: String
    let posterUrl: String
    let waveform: [CGFloat]

    init(_ json: [String: Any]) {
        type = json.string("type")
        url = json.string("url")
        name = json.string("name")
        posterUrl = json.string("posterUrl")
        waveform = Self.normalizedWaveform(json["waveform"])
        id = url.ifBlank(name.ifBlank(UUID().uuidString))
    }

    private static func normalizedWaveform(_ value: Any?) -> [CGFloat] {
        if let values = value as? [CGFloat] {
            return clippedWaveform(values)
        }
        if let values = value as? [Double] {
            return clippedWaveform(values.map { CGFloat($0) })
        }
        if let values = value as? [Float] {
            return clippedWaveform(values.map { CGFloat($0) })
        }
        if let values = value as? [Int] {
            return clippedWaveform(values.map { CGFloat($0) })
        }
        guard let rawValues = value as? [Any] else { return [] }
        return rawValues.prefix(64).compactMap { item in
            let number: Double?
            if let value = item as? Double {
                number = value
            } else if let value = item as? Float {
                number = Double(value)
            } else if let value = item as? Int {
                number = Double(value)
            } else if let value = item as? NSNumber {
                number = value.doubleValue
            } else if let value = item as? String {
                number = Double(value)
            } else {
                number = nil
            }
            guard let number, number.isFinite else { return nil }
            return CGFloat(max(0.08, min(1, number)))
        }
    }

    private static func clippedWaveform(_ values: [CGFloat]) -> [CGFloat] {
        values.prefix(64).map { max(0.08, min(1, $0)) }
    }
}

struct AloLocalAttachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let mime: String
    let type: String
    let name: String
    let waveform: [CGFloat]

    init(data: Data, mime: String, type: String, name: String, waveform: [CGFloat] = []) {
        self.data = data
        self.mime = mime
        self.type = type
        self.name = name
        self.waveform = waveform.prefix(64).map { max(0.08, min(1, $0)) }
    }

    var dataUrl: String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    func replacingWaveform(_ waveform: [CGFloat]) -> AloLocalAttachment {
        AloLocalAttachment(
            data: data,
            mime: mime,
            type: type,
            name: name,
            waveform: waveform.isEmpty ? self.waveform : waveform
        )
    }
}

struct AloForwardMeta: Equatable {
    let userId: Int
    let messageId: Int
    let user: AloEntitySummary?

    init?(_ json: [String: Any]) {
        userId = json.int("userId")
        messageId = json.int("messageId")
        user = json.optionalObject("user").map(AloEntitySummary.init)
        if userId <= 0 || messageId <= 0 { return nil }
    }

    init(userId: Int, messageId: Int, user: AloEntitySummary?) {
        self.userId = userId
        self.messageId = messageId
        self.user = user
    }
}

struct AloMessageReaction: Identifiable, Equatable {
    let emoji: String
    let count: Int
    let reactedByMe: Bool

    var id: String { emoji }

    init(_ json: [String: Any]) {
        emoji = json.string("emoji")
        count = max(0, json.int("count"))
        reactedByMe = json.bool("reactedByMe")
    }
}

struct AloPost: Identifiable, Equatable {
    let id: Int
    let creatorId: Int
    let body: String
    let media: [AloMediaItem]
    let likeCount: Int
    let commentCount: Int
    let repostCount: Int
    let viewCount: Int
    let viewerLiked: Bool
    let createdAt: String
    let author: AloEntitySummary

    init(_ json: [String: Any]) {
        id = json.int("id")
        creatorId = json.int("creatorId").ifZero(json.int("creator_id"))
        body = json.string("body")
        media = json.array("media").map(AloMediaItem.init)
        likeCount = json.int("likeCount")
        commentCount = json.int("commentCount")
        repostCount = json.int("repostCount")
        viewCount = json.int("viewCount")
        viewerLiked = json.bool("viewerLiked")
        createdAt = json.string("createdAt").ifBlank(json.string("created_at"))
        author = AloEntitySummary(json.object("author"))
    }
}

struct AloNotificationItem: Identifiable {
    let id: Int
    let type: String
    let text: String
    let createdAt: String
    let actor: AloEntitySummary?
    let actionableFriendRequestId: Int

    init(_ json: [String: Any]) {
        id = json.int("id")
        type = json.string("type")
        text = json.string("text")
        createdAt = json.string("createdAt")
        actor = json.optionalObject("actor").map(AloEntitySummary.init)
        actionableFriendRequestId = json.bool("friendRequestActionable") ? id : 0
    }
}

struct AloConversationPeer: Identifiable, Equatable {
    let id: Int
    let name: String
    let username: String
    let avatarUrl: String
    let verified: Bool
    let online: Bool
    let lastSeenAt: String
    let isTyping: Bool
    let entityType: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        name = json.string("name").ifBlank("Чат")
        username = json.string("username")
        avatarUrl = json.string("avatarUrl").ifBlank(json.string("avatarEmoji"))
        verified = json.bool("verified") || json.bool("isVerified")
        online = json.bool("online") || json.bool("isOnline")
        lastSeenAt = json.string("lastSeenAt")
        isTyping = json.bool("typing") || json.bool("isTyping")
        entityType = json.string("entityType")
    }
}

struct AloGroupMember: Identifiable, Equatable {
    let id: Int
    let name: String
    let username: String
    let avatarUrl: String
    let verified: Bool
    let role: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        name = json.string("name").ifBlank("Участник")
        username = json.string("username")
        avatarUrl = json.string("avatarUrl").ifBlank(json.string("avatarEmoji"))
        verified = json.bool("verified") || json.bool("isVerified")
        role = json.string("role").ifBlank("member")
    }

    var roleLabel: String {
        switch role {
        case "owner":
            return "Владелец"
        case "admin":
            return "Админ"
        default:
            return ""
        }
    }
}

struct AloConversationSummary: Identifiable, Equatable {
    var id: Int { peerId }
    let peerId: Int
    let kind: String
    let roomId: Int
    let memberCount: Int
    let lastAt: String
    let lastBody: String
    let peer: AloConversationPeer

    init(_ json: [String: Any]) {
        peerId = json.int("peerId")
        kind = json.string("kind").ifBlank("direct")
        roomId = json.int("roomId")
        memberCount = json.int("memberCount")
        lastAt = json.string("lastAt")
        lastBody = json.string("lastBody")
        peer = AloConversationPeer(json.object("peer"))
    }
}

struct AloChatMessage: Identifiable, Equatable {
    let id: Int
    let senderId: Int
    let recipientId: Int
    let body: String
    let attachmentUrl: String
    let attachmentType: String
    let attachmentName: String
    let attachments: [AloMessageAttachment]
    let editedAt: String
    let readAt: String
    let forwardFrom: AloForwardMeta?
    let createdAt: String
    let reactions: [AloMessageReaction]
    let sender: AloConversationPeer?

    init(_ json: [String: Any]) {
        id = json.int("id")
        senderId = json.int("senderId").ifZero(json.int("sender_id"))
        recipientId = json.int("recipientId").ifZero(json.int("recipient_id"))
        body = json.string("body")
        attachmentUrl = json.string("attachmentUrl")
        attachmentType = json.string("attachmentType")
        attachmentName = json.string("attachmentName")
        attachments = json.array("attachments").map(AloMessageAttachment.init)
        editedAt = json.string("editedAt")
        readAt = json.string("readAt")
        forwardFrom = json.optionalObject("forwardFrom").flatMap(AloForwardMeta.init)
        createdAt = json.string("createdAt")
        reactions = json.array("reactions").map(AloMessageReaction.init)
        sender = json.optionalObject("sender").map(AloConversationPeer.init)
    }

    private init(
        id: Int,
        senderId: Int,
        recipientId: Int,
        body: String,
        attachmentUrl: String,
        attachmentType: String,
        attachmentName: String,
        attachments: [AloMessageAttachment],
        editedAt: String,
        readAt: String,
        forwardFrom: AloForwardMeta?,
        createdAt: String,
        reactions: [AloMessageReaction],
        sender: AloConversationPeer?
    ) {
        self.id = id
        self.senderId = senderId
        self.recipientId = recipientId
        self.body = body
        self.attachmentUrl = attachmentUrl
        self.attachmentType = attachmentType
        self.attachmentName = attachmentName
        self.attachments = attachments
        self.editedAt = editedAt
        self.readAt = readAt
        self.forwardFrom = forwardFrom
        self.createdAt = createdAt
        self.reactions = reactions
        self.sender = sender
    }

    func replacingReactions(_ reactions: [AloMessageReaction]) -> AloChatMessage {
        AloChatMessage(
            id: id,
            senderId: senderId,
            recipientId: recipientId,
            body: body,
            attachmentUrl: attachmentUrl,
            attachmentType: attachmentType,
            attachmentName: attachmentName,
            attachments: attachments,
            editedAt: editedAt,
            readAt: readAt,
            forwardFrom: forwardFrom,
            createdAt: createdAt,
            reactions: reactions,
            sender: sender
        )
    }

    func replacingBody(_ body: String, editedAt: String) -> AloChatMessage {
        AloChatMessage(
            id: id,
            senderId: senderId,
            recipientId: recipientId,
            body: body,
            attachmentUrl: attachmentUrl,
            attachmentType: attachmentType,
            attachmentName: attachmentName,
            attachments: attachments,
            editedAt: editedAt,
            readAt: readAt,
            forwardFrom: forwardFrom,
            createdAt: createdAt,
            reactions: reactions,
            sender: sender
        )
    }
}

struct AloConversationDetail {
    let peerId: Int
    let kind: String
    let roomId: Int
    let title: String
    let subtitle: String
    let avatarUrl: String
    let canManageGroup: Bool
    let groupMemberRole: String
    let groupMembers: [AloGroupMember]
    let online: Bool
    let lastSeenAt: String
    let isTyping: Bool
    let items: [AloChatMessage]

    init(
        peerId: Int,
        kind: String,
        roomId: Int,
        title: String,
        subtitle: String,
        avatarUrl: String,
        canManageGroup: Bool = false,
        groupMemberRole: String = "",
        groupMembers: [AloGroupMember] = [],
        online: Bool,
        lastSeenAt: String,
        isTyping: Bool = false,
        items: [AloChatMessage]
    ) {
        self.peerId = peerId
        self.kind = kind
        self.roomId = roomId
        self.title = title
        self.subtitle = subtitle
        self.avatarUrl = avatarUrl
        self.canManageGroup = canManageGroup
        self.groupMemberRole = groupMemberRole
        self.groupMembers = groupMembers
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.isTyping = isTyping
        self.items = items
    }

    init(summary: AloConversationSummary, items: [AloChatMessage]) {
        peerId = summary.peerId
        kind = summary.kind
        roomId = summary.roomId
        title = summary.peer.name
        subtitle = summary.kind == "group"
            ? "\(summary.memberCount) участников"
            : (summary.peer.online ? "в сети" : AloFormatters.lastSeenLabel(summary.peer.lastSeenAt))
        avatarUrl = summary.peer.avatarUrl
        canManageGroup = false
        groupMemberRole = ""
        groupMembers = []
        online = summary.peer.online
        lastSeenAt = summary.peer.lastSeenAt
        isTyping = false
        self.items = items
    }

    init(peerId: Int, json: [String: Any]) {
        let peer = AloConversationPeer(json.object("peer"))
        let room = json.object("room")
        self.peerId = peerId
        kind = room.isEmpty ? "direct" : "group"
        roomId = room.int("id")
        title = room.string("title").ifBlank(peer.name)
        subtitle = room.isEmpty ? (peer.online ? "в сети" : AloFormatters.lastSeenLabel(peer.lastSeenAt)) : "\(room.int("memberCount")) участников"
        avatarUrl = room.string("avatarEmoji").ifBlank(peer.avatarUrl)
        canManageGroup = room.bool("canManage")
        groupMemberRole = room.string("memberRole")
        groupMembers = room.array("members").map(AloGroupMember.init)
        online = peer.online
        lastSeenAt = peer.lastSeenAt
        isTyping = json.bool("typing") || json.bool("isTyping") || peer.isTyping
        items = json.array("items").map(AloChatMessage.init)
    }

    func replacingMessage(_ message: AloChatMessage) -> AloConversationDetail {
        AloConversationDetail(
            peerId: peerId,
            kind: kind,
            roomId: roomId,
            title: title,
            subtitle: subtitle,
            avatarUrl: avatarUrl,
            canManageGroup: canManageGroup,
            groupMemberRole: groupMemberRole,
            groupMembers: groupMembers,
            online: online,
            lastSeenAt: lastSeenAt,
            isTyping: isTyping,
            items: items.map { $0.id == message.id ? message : $0 }
        )
    }
}

struct AloProfileStats: Equatable {
    let friends: Int
    let followers: Int
    let following: Int
    let channels: Int

    init(_ json: [String: Any]) {
        friends = json.int("friendsCount")
        followers = json.int("followersCount")
        following = json.int("followingCount")
        channels = json.int("channelsOwnedCount") + json.int("channelsSubscribedCount")
    }
}

struct AloProfileRelation: Equatable {
    let following: Bool
    let followedBy: Bool
    let isFriend: Bool
    let friendStatus: String
    let incomingRequestId: Int
    let outgoingRequestId: Int

    init(_ json: [String: Any]) {
        following = json.bool("following")
        followedBy = json.bool("followedBy") || json.bool("followsYou")
        isFriend = json.bool("isFriend")
        friendStatus = json.string("friendStatus").ifBlank(isFriend ? "friends" : "none")
        incomingRequestId = json.int("incomingRequestId")
        outgoingRequestId = json.int("outgoingRequestId")
    }
}

struct AloProfilePermissions: Equatable {
    let canMessage: Bool
    let canViewContent: Bool
    let isPrivate: Bool
    let profileVisibility: String
    let canSendFriendRequest: Bool

    init(_ json: [String: Any]) {
        canMessage = json.bool("canMessage")
        canViewContent = json.bool("canViewContent")
        isPrivate = json.bool("isPrivate")
        profileVisibility = json.string("profileVisibility")
        canSendFriendRequest = json.bool("canSendFriendRequest")
    }
}

struct AloPrivacySettings: Equatable {
    let allowFriendRequests: Bool
    let messageScope: String
    let allowMessageForwards: Bool
    let callScope: String
    let profileVisibility: String
    let hideActivity: Bool

    init(
        allowFriendRequests: Bool,
        messageScope: String,
        allowMessageForwards: Bool,
        callScope: String,
        profileVisibility: String,
        hideActivity: Bool
    ) {
        self.allowFriendRequests = allowFriendRequests
        self.messageScope = messageScope
        self.allowMessageForwards = allowMessageForwards
        self.callScope = callScope
        self.profileVisibility = profileVisibility
        self.hideActivity = hideActivity
    }

    init(_ json: [String: Any]) {
        allowFriendRequests = json.bool("allowFriendRequests")
        messageScope = json.string("messageScope").ifBlank("all")
        allowMessageForwards = json["allowMessageForwards"] == nil ? true : json.bool("allowMessageForwards")
        callScope = json.string("callScope").ifBlank("all")
        profileVisibility = json.string("profileVisibility").ifBlank("all")
        hideActivity = json.bool("hideActivity")
    }

    static let `default` = AloPrivacySettings([
        "allowFriendRequests": true,
        "messageScope": "all",
        "allowMessageForwards": true,
        "callScope": "all",
        "profileVisibility": "all",
        "hideActivity": false
    ])

    var requestBody: [String: Any] {
        [
            "allowFriendRequests": allowFriendRequests,
            "messageScope": messageScope,
            "allowMessageForwards": allowMessageForwards,
            "callScope": callScope,
            "profileVisibility": profileVisibility,
            "hideActivity": hideActivity
        ]
    }
}

struct AloUserProfile: Identifiable, Equatable {
    let id: Int
    let user: AloCurrentUser
    let stats: AloProfileStats
    let posts: [AloPost]
    let likes: [AloPost]
    let relation: AloProfileRelation
    let permissions: AloProfilePermissions

    init(
        id: Int,
        user: AloCurrentUser,
        stats: AloProfileStats,
        posts: [AloPost],
        likes: [AloPost],
        relation: AloProfileRelation,
        permissions: AloProfilePermissions
    ) {
        self.id = id
        self.user = user
        self.stats = stats
        self.posts = posts
        self.likes = likes
        self.relation = relation
        self.permissions = permissions
    }

    init(_ json: [String: Any]) {
        let profile = json.object("profile")
        user = AloCurrentUser(profile.object("user"))
        id = user.id
        stats = AloProfileStats(profile.object("stats"))
        posts = profile.array("posts").map(AloPost.init)
        likes = profile.array("likes").map(AloPost.init)
        relation = AloProfileRelation(profile.object("relation"))
        permissions = AloProfilePermissions(profile.object("permissions"))
    }
}

struct AloBootstrapData {
    let me: AloCurrentUser
    let feedPopular: [AloPost]
    let feedSubscriptions: [AloPost]
    let notifications: [AloNotificationItem]
    let searchUsers: [AloEntitySummary]
    let searchChannels: [AloEntitySummary]
    let profileStats: AloProfileStats
    let profilePosts: [AloPost]
    let privacySettings: AloPrivacySettings
    let conversations: [AloConversationSummary]
    let activePeerId: Int
    let activeMessages: [AloChatMessage]

    init(
        me: AloCurrentUser,
        feedPopular: [AloPost],
        feedSubscriptions: [AloPost],
        notifications: [AloNotificationItem],
        searchUsers: [AloEntitySummary],
        searchChannels: [AloEntitySummary],
        profileStats: AloProfileStats,
        profilePosts: [AloPost],
        privacySettings: AloPrivacySettings,
        conversations: [AloConversationSummary],
        activePeerId: Int,
        activeMessages: [AloChatMessage]
    ) {
        self.me = me
        self.feedPopular = feedPopular
        self.feedSubscriptions = feedSubscriptions
        self.notifications = notifications
        self.searchUsers = searchUsers
        self.searchChannels = searchChannels
        self.profileStats = profileStats
        self.profilePosts = profilePosts
        self.privacySettings = privacySettings
        self.conversations = conversations
        self.activePeerId = activePeerId
        self.activeMessages = activeMessages
    }

    init(_ json: [String: Any]) {
        let data = json.object("data")
        let feed = data.object("feed")
        let search = data.object("search")
        let profile = data.object("profile")
        let messages = data.object("messages")
        me = AloCurrentUser(data.object("me"))
        feedPopular = feed.array("popular").map(AloPost.init)
        feedSubscriptions = feed.array("subs").map(AloPost.init)
        notifications = data.array("notifications").map(AloNotificationItem.init)
        searchUsers = search.array("users").map(AloEntitySummary.init)
        searchChannels = search.array("channels").map(AloEntitySummary.init)
        profileStats = AloProfileStats(profile.object("stats"))
        profilePosts = profile.array("posts").map(AloPost.init)
        privacySettings = AloPrivacySettings(data.object("privacySettings"))
        conversations = messages.array("conversations").map(AloConversationSummary.init)
        activePeerId = messages.int("activePeerId")
        activeMessages = messages.array("items").map(AloChatMessage.init)
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String {
        if let value = self[key] as? String { return value }
        if let value = self[key] { return String(describing: value) }
        return ""
    }

    func int(_ key: String) -> Int {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? String { return Int(value) ?? 0 }
        return 0
    }

    func bool(_ key: String) -> Bool {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? Int { return value != 0 }
        if let value = self[key] as? String { return value == "true" || value == "1" }
        return false
    }

    func object(_ key: String) -> [String: Any] {
        self[key] as? [String: Any] ?? [:]
    }

    func optionalObject(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func array(_ key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }
}

extension String {
    func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }

    var withAtPrefix: String {
        isEmpty ? "" : "@\(self)"
    }
}

extension Int {
    func ifZero(_ fallback: Int) -> Int {
        self == 0 ? fallback : self
    }
}

enum AloFormatters {
    static func lastSeenLabel(_ raw: String) -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "был(а) недавно"
        }
        guard let date = parseIsoDate(raw) else {
            return raw
        }

        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) {
            return "был(а) сегодня в \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "был(а) вчера в \(time)"
        }
        return "был(а) \(dayMonthFormatter.string(from: date)) в \(time)"
    }

    static func messageTime(_ raw: String) -> String {
        guard let date = parseIsoDate(raw) else {
            return String(raw.prefix(16))
        }
        return timeFormatter.string(from: date)
    }

    private static func parseIsoDate(_ raw: String) -> Date? {
        isoDateFormatter.date(from: raw) ?? isoDateFormatterWithoutFraction.date(from: raw)
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateFormatterWithoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()
}
