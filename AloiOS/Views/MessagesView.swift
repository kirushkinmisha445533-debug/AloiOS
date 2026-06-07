import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation
import AVKit
import Combine

private enum AloKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct MessagesView: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var chatDragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                inbox
                    .opacity(app.activeConversation == nil ? 1 : max(0.18, min(1, chatDragOffset / max(proxy.size.width * 0.62, 1))))
                    .allowsHitTesting(app.activeConversation == nil)

                if let conversation = app.activeConversation {
                    ConversationView(conversation: conversation)
                        .offset(x: max(0, chatDragOffset))
                        .shadow(color: Color.black.opacity(chatDragOffset > 0 ? 0.30 : 0), radius: 18, x: -8, y: 0)
                        .simultaneousGesture(chatSwipeGesture(width: proxy.size.width))
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                        .zIndex(2)
                }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: app.activeConversation?.peerId)
        .onChange(of: app.activeConversation?.peerId) { _, _ in
            chatDragOffset = 0
        }
    }

    private func chatSwipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard (value.startLocation.x < 42 || chatDragOffset > 0),
                      value.translation.width > 0,
                      abs(value.translation.width) > abs(value.translation.height) * 1.05 else { return }
                AloKeyboard.dismiss()
                chatDragOffset = min(width, max(0, value.translation.width))
            }
            .onEnded { value in
                let threshold = max(110, width * 0.28)
                let shouldClose = value.translation.width > threshold || value.predictedEndTranslation.width > width * 0.52
                if shouldClose {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) {
                        chatDragOffset = width
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        AloKeyboard.dismiss()
                        app.closeConversation()
                        chatDragOffset = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        chatDragOffset = 0
                    }
                }
            }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Чаты")
                .font(.largeTitle.bold())
                .foregroundStyle(AloTheme.text)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(app.bootstrap?.conversations ?? []) { conversation in
                        Button {
                            app.openConversation(conversation)
                        } label: {
                            ConversationRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                        Divider().background(AloTheme.border).padding(.leading, 88)
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .refreshable { await app.loadBootstrap() }
    }
}

private struct ConversationRow: View {
    let conversation: AloConversationSummary

    var body: some View {
        HStack(spacing: 12) {
            AloAvatar(name: conversation.peer.name, url: conversation.peer.avatarUrl, size: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.peer.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AloTheme.text)
                Text(conversation.lastBody.ifBlank("Сообщение"))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(AloTheme.muted)
            }
            Spacer()
            Text(AloFormatters.messageTime(conversation.lastAt))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AloTheme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ActiveVoicePlayback: Equatable {
    let attachmentId: String
    let title: String
    let isPlaying: Bool
    var speed: Double
}

private struct ChatCallLogMeta: Equatable {
    let callType: String
    let status: String
    let durationSec: Int
    let scope: String
}

struct ConversationView: View {
    @EnvironmentObject private var app: AloAppModel
    let conversation: AloConversationDetail

    @State private var localAttachments = [AloLocalAttachment]()
    @State private var isAttachmentSheetPresented = false
    @State private var selectedMessageIds = Set<Int>()
    @State private var selectionMode = false
    @State private var actionMessage: AloChatMessage?
    @State private var actionMessageFrame: CGRect?
    @State private var editingMessage: AloChatMessage?
    @State private var deleteCandidateIds = [Int]()
    @State private var forwardPickerMessage: AloChatMessage?
    @State private var recordingMode: ChatRecordingMode = .voice
    @State private var activeRecordingMode: ChatRecordingMode?
    @State private var isRecordingLocked = false
    @State private var recordingStartedAt = Date()
    @State private var recordedDurations = [UUID: TimeInterval]()
    @State private var recordedWaveforms = [UUID: [CGFloat]]()
    @State private var activeVoicePlayback: ActiveVoicePlayback?
    @State private var isChatDetailsPresented = false
    @State private var activeCallKind: ChatCallKind?
    @State private var keyboardHeight: CGFloat = 0
    @StateObject private var audioRecorder = ChatAudioRecorder()
    @StateObject private var circleRecorder = ChatCircleRecorder()
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            chatBackground.ignoresSafeArea()

            messagesList

            chatChromeBlur
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                if let activeVoicePlayback {
                    VoicePlaybackTopBar(
                        playback: activeVoicePlayback,
                        onToggle: { toggleTopVoicePlayback(activeVoicePlayback.attachmentId) },
                        onSpeed: { cycleVoicePlaybackSpeed(activeVoicePlayback.attachmentId) },
                        onClose: { stopTopVoicePlayback(activeVoicePlayback.attachmentId) }
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 7)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer(minLength: 0)
            }

            if let actionMessage {
                MessageActionOverlay(
                    message: actionMessage,
                    targetFrame: actionMessageFrame,
                    onCopy: {
                        if !actionMessage.body.isEmpty {
                            UIPasteboard.general.string = actionMessage.body
                        }
                        closeMessageActions()
                    },
                    onForward: {
                        beginForward(actionMessage)
                        closeMessageActions()
                    },
                    onEdit: {
                        beginEdit(actionMessage)
                        closeMessageActions()
                    },
                    onReact: { emoji in
                        app.toggleMessageReaction(actionMessage, emoji: emoji)
                        closeMessageActions()
                    },
                    onSelect: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            selectionMode = true
                            selectedMessageIds = [actionMessage.id]
                            self.actionMessage = nil
                        }
                    },
                    onDelete: {
                        deleteCandidateIds = [actionMessage.id]
                        closeMessageActions()
                    },
                    onCancel: closeMessageActions
                )
                .transition(.opacity)
                .zIndex(20)
            }

            if isChatDetailsPresented {
                ChatPeerInfoPanel(
                    conversation: conversation,
                    messages: conversation.items,
                    onClose: { withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { isChatDetailsPresented = false } },
                    onOpenProfile: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { isChatDetailsPresented = false }
                        if conversation.kind != "group" {
                            app.openProfile(userId: conversation.peerId)
                        }
                    },
                    onAudioCall: { startCall(.audio) },
                    onVideoCall: { startCall(.video) }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
                .zIndex(30)
            }

            if let activeCallKind {
                ChatCallScreen(
                    kind: activeCallKind,
                    conversation: conversation,
                    onEnd: { withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { self.activeCallKind = nil } }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(40)
            }

            if activeRecordingMode == .circle {
                CircleRecordingOverlay(
                    startedAt: recordingStartedAt,
                    isLocked: isRecordingLocked,
                    recorder: circleRecorder,
                    onCancel: cancelRecording,
                    onSend: { finishRecording(sendImmediately: true) }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(18)
            }
        }
        .coordinateSpace(name: "conversationRoot")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomChrome
        }
        .sheet(isPresented: $isAttachmentSheetPresented) {
            ChatAttachmentSheet(attachments: $localAttachments)
        }
        .onAppear {
            app.startConversationLive(conversation)
        }
        .onChange(of: conversation.peerId) { _, _ in
            app.startConversationLive(conversation)
        }
        .onChange(of: app.messageText) { _, _ in
            app.sendTypingIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let nextHeight = max(0, UIScreen.main.bounds.height - frame.minY)
            withAnimation(.easeOut(duration: 0.18)) {
                keyboardHeight = nextHeight
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.16)) {
                keyboardHeight = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackDidStart)) { notification in
            guard let attachmentId = notification.object as? String else { return }
            let title = (notification.userInfo?["title"] as? String)?.ifBlank("Голосовое сообщение") ?? "Голосовое сообщение"
            let speed = notification.userInfo?["speed"] as? Double
            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                activeVoicePlayback = ActiveVoicePlayback(
                    attachmentId: attachmentId,
                    title: title,
                    isPlaying: notification.userInfo?["isPlaying"] as? Bool ?? true,
                    speed: speed ?? activeVoicePlayback?.speed ?? 1
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackDidStop)) { notification in
            guard let attachmentId = notification.object as? String else { return }
            if activeVoicePlayback?.attachmentId == attachmentId {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                    activeVoicePlayback = nil
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: selectionMode)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: activeVoicePlayback)
        .sheet(isPresented: forwardPickerBinding) {
            ForwardTargetSheet(
                conversations: app.bootstrap?.conversations ?? [],
                currentPeerId: conversation.peerId
            ) { target in
                guard let message = forwardPickerMessage else { return }
                applyForward(message, to: target)
            }
        }
        .confirmationDialog("Удалить сообщение", isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button("Удалить у меня", role: .destructive) {
                deleteSelected(mode: "me")
            }
            Button("Удалить у всех", role: .destructive) {
                deleteSelected(mode: "everyone")
            }
            Button("Отмена", role: .cancel) {
                deleteCandidateIds = []
            }
        }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        if activeCallKind == nil && activeRecordingMode != .circle {
            Group {
                if selectionMode {
                    MessageSelectionToolbar(
                        count: selectedMessageIds.count,
                        onCancel: clearSelection,
                        onForward: beginForwardSelected,
                        onDelete: { deleteCandidateIds = Array(selectedMessageIds) }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    composer
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 6)
            .background {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.28)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { !deleteCandidateIds.isEmpty },
            set: { isPresented in
                if !isPresented { deleteCandidateIds = [] }
            }
        )
    }

    private var forwardPickerBinding: Binding<Bool> {
        Binding(
            get: { forwardPickerMessage != nil },
            set: { isPresented in
                if !isPresented { forwardPickerMessage = nil }
            }
        )
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    Color.clear.frame(height: 132)
                    ForEach(conversation.items) { item in
                        ChatMessageRow(
                            message: item,
                            isMine: item.senderId == app.bootstrap?.me.id,
                            isSelected: selectedMessageIds.contains(item.id),
                            selectionMode: selectionMode,
                            onTap: { handleMessageTap(item) },
                            onReact: { emoji in
                                app.toggleMessageReaction(item, emoji: emoji)
                            },
                            onLongPress: { frame in
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                                    actionMessageFrame = frame
                                    actionMessage = item
                                }
                            }
                        )
                        .id(item.id)
                    }
                    Color.clear.frame(height: 8).id(bottomAnchorId)
                }
                .padding(.horizontal, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded {
                composerFocused = false
                AloKeyboard.dismiss()
            })
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: conversation.items.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: keyboardHeight) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                composerFocused = false
                AloKeyboard.dismiss()
                app.closeConversation()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 42, height: 46)
                    .contentShape(Rectangle())
            }
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    isChatDetailsPresented = true
                }
            } label: {
                HStack(spacing: 11) {
                    AloAvatar(name: conversation.title, url: conversation.avatarUrl, size: 50)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversation.title)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(AloTheme.text)
                            .lineLimit(1)
                        if conversation.isTyping {
                            TypingStatusText()
                        } else {
                            Text(conversation.online ? "в сети" : conversation.subtitle)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AloTheme.muted)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            AloIconButton(systemName: "phone", action: { startCall(.audio) })
            AloIconButton(systemName: "video", action: { startCall(.video) })
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(AloTheme.surface.opacity(0.84))
        }
        .clipShape(Capsule())
        .overlay(Capsule().stroke(AloTheme.border, lineWidth: 1))
    }

    private var composer: some View {
        let recordedDraft = localAttachments.first(where: \.isRecordedDraft)
        let visibleAttachments = localAttachments.filter { !$0.isRecordedDraft }

        return VStack(spacing: 8) {
            if let editingMessage {
                EditDraftBar(preview: editingMessage.body) {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                        self.editingMessage = nil
                        app.messageText = ""
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if app.pendingForwardDraft != nil {
                ForwardDraftBar(title: app.pendingForwardTitle.ifBlank("Переслать сообщение")) {
                    app.pendingForwardDraft = nil
                    app.pendingForwardTitle = ""
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !visibleAttachments.isEmpty {
                LocalAttachmentStrip(attachments: visibleAttachments) { attachment in
                    localAttachments.removeAll { $0.id == attachment.id }
                }
            }

            HStack(spacing: 8) {
                if activeRecordingMode == .circle {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 48)
                } else if let activeRecordingMode {
                    RecordingComposerPanel(
                        mode: activeRecordingMode,
                        startedAt: recordingStartedAt,
                        isLocked: isRecordingLocked,
                        circleRecorder: circleRecorder,
                        levels: audioRecorder.levels,
                        onCancel: cancelRecording,
                        onSend: { finishRecording(sendImmediately: true) }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let recordedDraft {
                    RecordedDraftComposerPanel(
                        attachment: recordedDraft,
                        duration: recordedDurations[recordedDraft.id] ?? 0,
                        levels: recordedWaveforms[recordedDraft.id] ?? recordedDraft.waveform,
                        onRemove: {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                localAttachments.removeAll { $0.id == recordedDraft.id }
                                recordedDurations[recordedDraft.id] = nil
                                recordedWaveforms[recordedDraft.id] = nil
                            }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    ChatComposerButton(systemName: "paperclip") {
                        isAttachmentSheetPresented = true
                    }
                    .transition(.scale(scale: 0.88).combined(with: .opacity))

                    TextField("Сообщение", text: $app.messageText, axis: .vertical)
                        .focused($composerFocused)
                        .foregroundStyle(AloTheme.text)
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .lineLimit(1...4)
                        .frame(minHeight: 48)
                        .background {
                            Capsule().fill(AloTheme.surface)
                        }
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(AloTheme.border, lineWidth: 1))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if activeRecordingMode == .circle && !isRecordingLocked {
                    ChatRecordSendButton(
                        mode: recordingMode,
                        canSend: !sendDisabled,
                        isRecording: activeRecordingMode != nil,
                        onSend: sendCurrentDraft,
                        onToggleMode: toggleRecordingMode,
                        onHoldStart: startRecording,
                        onHoldEnd: finishRecording,
                        onLock: lockRecording,
                        onCancel: cancelRecording
                    )
                    .opacity(0.001)
                    .accessibilityHidden(true)
                } else if !isRecordingLocked {
                    ChatRecordSendButton(
                        mode: recordingMode,
                        canSend: !sendDisabled,
                        isRecording: activeRecordingMode != nil,
                        onSend: sendCurrentDraft,
                        onToggleMode: toggleRecordingMode,
                        onHoldStart: startRecording,
                        onHoldEnd: finishRecording,
                        onLock: lockRecording,
                        onCancel: cancelRecording
                    )
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: localAttachments.count)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: app.pendingForwardDraft != nil)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: editingMessage?.id)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: activeRecordingMode)
    }

    private var sendDisabled: Bool {
        app.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            localAttachments.isEmpty &&
            app.pendingForwardDraft == nil
    }

    private var chatBackground: some View {
        TelegramStyleChatWallpaper()
    }

    private var chatChromeBlur: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: 154)
                .mask(
                    LinearGradient(
                        colors: [.black, .black.opacity(0.82), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Spacer(minLength: 0)
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: 102)
                .mask(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.76), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        }
    }

    private var bottomAnchorId: String {
        "conversation-bottom-\(conversation.kind)-\(conversation.peerId)-\(conversation.roomId)"
    }

    private func handleMessageTap(_ message: AloChatMessage) {
        guard selectionMode else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            if selectedMessageIds.contains(message.id) {
                selectedMessageIds.remove(message.id)
            } else {
                selectedMessageIds.insert(message.id)
            }
            if selectedMessageIds.isEmpty {
                selectionMode = false
            }
        }
    }

    private func clearSelection() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            selectionMode = false
            selectedMessageIds = []
        }
    }

    private func closeMessageActions() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            actionMessage = nil
            actionMessageFrame = nil
        }
    }

    private func toggleTopVoicePlayback(_ attachmentId: String) {
        NotificationCenter.default.post(name: .aloVoicePlaybackToggleRequested, object: attachmentId)
    }

    private func cycleVoicePlaybackSpeed(_ attachmentId: String) {
        guard let playback = activeVoicePlayback else { return }
        let nextSpeed: Double
        switch playback.speed {
        case ..<1.25:
            nextSpeed = 1.5
        case ..<1.75:
            nextSpeed = 2.0
        default:
            nextSpeed = 1.0
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            activeVoicePlayback = ActiveVoicePlayback(
                attachmentId: attachmentId,
                title: playback.title,
                isPlaying: playback.isPlaying,
                speed: nextSpeed
            )
        }
        NotificationCenter.default.post(
            name: .aloVoicePlaybackSpeedChanged,
            object: attachmentId,
            userInfo: ["speed": nextSpeed]
        )
        AloHaptics.selection()
    }

    private func stopTopVoicePlayback(_ attachmentId: String) {
        NotificationCenter.default.post(name: .aloVoicePlaybackStopRequested, object: attachmentId)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            activeVoicePlayback = nil
        }
    }

    private func beginForward(_ message: AloChatMessage) {
        forwardPickerMessage = message
    }

    private func beginEdit(_ message: AloChatMessage) {
        guard message.senderId == app.bootstrap?.me.id, !message.body.isEmpty else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            editingMessage = message
            app.pendingForwardDraft = nil
            app.pendingForwardTitle = ""
            localAttachments = []
            app.messageText = message.body
        }
    }

    private func beginForwardSelected() {
        guard let firstId = selectedMessageIds.first,
              let message = conversation.items.first(where: { $0.id == firstId }) else { return }
        beginForward(message)
    }

    private func applyForward(_ message: AloChatMessage, to target: AloConversationSummary) {
        app.pendingForwardDraft = AloForwardMeta(userId: message.senderId, messageId: message.id, user: nil)
        app.pendingForwardTitle = "Переслать сообщение"
        forwardPickerMessage = nil
        clearSelection()
        if target.peerId != conversation.peerId {
            app.openConversation(target)
        }
    }

    private func deleteSelected(mode: String) {
        let ids = deleteCandidateIds
        deleteCandidateIds = []
        app.deleteMessages(ids, mode: mode) {
            clearSelection()
        }
    }

    private func sendCurrentDraft() {
        if let editingMessage {
            app.editMessage(editingMessage, body: app.messageText) {
                self.editingMessage = nil
                self.app.messageText = ""
            }
            return
        }

        app.sendMessage(
            localAttachments: localAttachments,
            forwardFrom: app.pendingForwardDraft
        ) {
            localAttachments = []
            recordedDurations = [:]
            recordedWaveforms = [:]
            app.pendingForwardDraft = nil
            app.pendingForwardTitle = ""
        }
    }

    private func toggleRecordingMode() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            recordingMode = recordingMode == .voice ? .circle : .voice
        }
        AloHaptics.selection()
    }

    private func startRecording() {
        guard sendDisabled, activeRecordingMode == nil else { return }
        recordingStartedAt = Date()
        isRecordingLocked = false
        activeRecordingMode = recordingMode
        AloHaptics.impact(.medium)
        switch recordingMode {
        case .voice:
            audioRecorder.start()
        case .circle:
            circleRecorder.start()
        }
    }

    private func lockRecording() {
        guard activeRecordingMode != nil, !isRecordingLocked else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            isRecordingLocked = true
        }
        AloHaptics.notification(.success)
    }

    private func finishRecording() {
        finishRecording(sendImmediately: false)
    }

    private func finishRecording(sendImmediately: Bool) {
        guard let mode = activeRecordingMode else { return }
        let duration = Date().timeIntervalSince(recordingStartedAt)
        activeRecordingMode = nil
        isRecordingLocked = false
        guard duration > 0.55 else {
            audioRecorder.cancel()
            circleRecorder.cancel()
            return
        }
        AloHaptics.impact(.light)
        switch mode {
        case .voice:
            let waveform = audioRecorder.levels
            audioRecorder.stop { attachment, extractedWaveform in
                guard let attachment else { return }
                let finalWaveform = extractedWaveform.isEmpty ? waveform : extractedWaveform
                handleRecordedAttachment(
                    attachment.replacingWaveform(finalWaveform),
                    duration: duration,
                    waveform: finalWaveform,
                    sendImmediately: sendImmediately
                )
            }
        case .circle:
            circleRecorder.stop { attachment in
                guard let attachment else { return }
                handleRecordedAttachment(attachment, duration: duration, waveform: [], sendImmediately: sendImmediately)
            }
        }
    }

    private func cancelRecording() {
        guard activeRecordingMode != nil else { return }
        activeRecordingMode = nil
        isRecordingLocked = false
        audioRecorder.cancel()
        circleRecorder.cancel()
        AloHaptics.notification(.warning)
    }

    private func handleRecordedAttachment(_ attachment: AloLocalAttachment, duration: TimeInterval, waveform: [CGFloat], sendImmediately: Bool) {
        if sendImmediately {
            app.sendMessage(localAttachments: [attachment], forwardFrom: nil)
            return
        }
        let storedWaveform = waveform.isEmpty ? attachment.waveform : waveform
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            localAttachments.removeAll { $0.isRecordedDraft }
            recordedDurations = recordedDurations.filter { key, _ in
                localAttachments.contains { $0.id == key }
            }
            recordedWaveforms = recordedWaveforms.filter { key, _ in
                localAttachments.contains { $0.id == key }
            }
            localAttachments.append(attachment)
            recordedDurations[attachment.id] = duration
            recordedWaveforms[attachment.id] = storedWaveform
        }
    }

    private func startCall(_ kind: ChatCallKind) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            activeCallKind = kind
        }
    }
}

private struct TelegramStyleChatWallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.030, green: 0.135, blue: 0.255),
                    Color(red: 0.035, green: 0.245, blue: 0.355)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, size in
                let lineColor = Color.white.opacity(0.035)
                let iconColor = Color.white.opacity(0.052)
                let dotColor = Color.white.opacity(0.040)

                var diagonal = Path()
                let spacing: CGFloat = 128
                var startX = -size.height
                while startX < size.width {
                    diagonal.move(to: CGPoint(x: startX, y: size.height))
                    diagonal.addLine(to: CGPoint(x: startX + size.height, y: 0))
                    startX += spacing
                }
                context.stroke(diagonal, with: .color(lineColor), lineWidth: 1)

                let stepX: CGFloat = 92
                let stepY: CGFloat = 104
                var row = 0
                var y: CGFloat = 52
                while y < size.height + 40 {
                    var x: CGFloat = row.isMultiple(of: 2) ? 32 : 78
                    while x < size.width + 40 {
                        let rect = CGRect(x: x - 12, y: y - 12, width: 24, height: 24)
                        switch (row + Int(x / stepX)) % 4 {
                        case 0:
                            context.stroke(Path(ellipseIn: rect), with: .color(iconColor), lineWidth: 1.1)
                        case 1:
                            var plus = Path()
                            plus.move(to: CGPoint(x: x - 8, y: y))
                            plus.addLine(to: CGPoint(x: x + 8, y: y))
                            plus.move(to: CGPoint(x: x, y: y - 8))
                            plus.addLine(to: CGPoint(x: x, y: y + 8))
                            context.stroke(plus, with: .color(iconColor), lineWidth: 1.15)
                        case 2:
                            var bubble = Path(roundedRect: CGRect(x: x - 12, y: y - 8, width: 24, height: 16), cornerRadius: 7)
                            bubble.move(to: CGPoint(x: x + 5, y: y + 8))
                            bubble.addLine(to: CGPoint(x: x + 12, y: y + 13))
                            context.stroke(bubble, with: .color(iconColor), lineWidth: 1.05)
                        default:
                            context.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)), with: .color(dotColor))
                        }
                        x += stepX
                    }
                    row += 1
                    y += stepY
                }
            }
            .blendMode(.plusLighter)
        }
    }
}

private struct TypingStatusText: View {
    @State private var dotCount = 1
    private let timer = Timer.publish(every: 0.42, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("печатает" + String(repeating: ".", count: dotCount))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AloTheme.accent)
            .lineLimit(1)
            .onReceive(timer) { _ in
                dotCount = dotCount == 3 ? 1 : dotCount + 1
            }
    }
}

private struct ChatMessageRow: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var isPressingBubble = false
    @State private var bubbleFrame: CGRect = .zero
    @State private var longPressWorkItem: DispatchWorkItem?
    @State private var didOpenLongPressMenu = false
    @State private var didMoveDuringPress = false

    let message: AloChatMessage
    let isMine: Bool
    let isSelected: Bool
    let selectionMode: Bool
    let onTap: () -> Void
    let onReact: (String) -> Void
    let onLongPress: (CGRect) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine { Spacer(minLength: 52) }
            if selectionMode && !isMine {
                selectionIndicator
            }
            bubble
                .scaleEffect(isSelected ? 0.99 : (isPressingBubble ? 0.985 : 1))
                .overlay(selectionOverlay)
                .background(bubbleFrameReader)
                .onTapGesture(perform: onTap)
                .simultaneousGesture(voiceScrubGuardGesture)
                .onLongPressGesture(
                    minimumDuration: 0.24,
                    maximumDistance: 18,
                    pressing: handleBubblePressing,
                    perform: {
                        guard !didOpenLongPressMenu, !didMoveDuringPress else { return }
                        didOpenLongPressMenu = true
                        AloHaptics.impact(.medium)
                        onLongPress(bubbleFrame)
                    }
                )
            if selectionMode && isMine {
                selectionIndicator
            }
            if !isMine { Spacer(minLength: 52) }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isSelected)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: selectionMode)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isPressingBubble)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: reactionsAnimationKey)
    }

    private var bubbleFrameReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    updateBubbleFrame(proxy.frame(in: .named("conversationRoot")))
                }
                .onChange(of: proxy.frame(in: .named("conversationRoot"))) { _, newFrame in
                    updateBubbleFrame(newFrame)
                }
        }
    }

    private func updateBubbleFrame(_ newFrame: CGRect) {
        guard newFrame != bubbleFrame else { return }
        DispatchQueue.main.async {
            bubbleFrame = newFrame
        }
    }

    private func handleBubblePressing(_ pressing: Bool) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            isPressingBubble = pressing
        }
        if pressing {
            didMoveDuringPress = false
            longPressWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                guard !didOpenLongPressMenu, !didMoveDuringPress else { return }
                didOpenLongPressMenu = true
                AloHaptics.impact(.medium)
                onLongPress(bubbleFrame)
            }
            longPressWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        } else {
            longPressWorkItem?.cancel()
            longPressWorkItem = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                didOpenLongPressMenu = false
                didMoveDuringPress = false
            }
        }
    }

    private var voiceScrubGuardGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .local)
            .onChanged { value in
                guard voiceOnly else { return }
                if abs(value.translation.width) > abs(value.translation.height) {
                    didMoveDuringPress = true
                    longPressWorkItem?.cancel()
                }
            }
            .onEnded { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    didMoveDuringPress = false
                }
            }
    }

    @ViewBuilder
    private var bubble: some View {
        if circleOnly {
            circleBubble
        } else if voiceOnly {
            voiceBubble
        } else if simpleTextOnly {
            textOnlyBubble
        } else {
            standardBubble
        }
    }

    private var voiceBubble: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            if let forwardFrom = message.forwardFrom {
                Text("Переслано от \(forwardFrom.user?.name ?? "пользователя")")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isMine ? Color.white.opacity(0.86) : AloTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(voiceAttachments) { attachment in
                VoiceMessageAttachmentView(
                    attachment: attachment,
                    isMine: isMine,
                    showMessageMeta: attachment.id == voiceAttachments.last?.id,
                    createdAt: message.createdAt,
                    editedAt: message.editedAt,
                    isRead: !message.readAt.isEmpty,
                    onLongPress: { onLongPress(bubbleFrame) }
                )
            }

            inlineReactionFooter(showMeta: false)
        }
        .frame(width: 220, alignment: isMine ? .trailing : .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isMine ? AloTheme.outgoing : AloTheme.incoming)
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
    }

    private var messageTimestamp: some View {
        HStack(spacing: 3) {
            if !message.editedAt.isEmpty {
                Text("изм.")
            }
            Text(AloFormatters.messageTime(message.createdAt))
            if isMine {
                MessageReadStatusChecks(isRead: !message.readAt.isEmpty)
            }
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Color.white.opacity(0.72))
    }

    private var standardBubble: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
            if let forwardFrom = message.forwardFrom {
                Text("Переслано от \(forwardFrom.user?.name ?? "пользователя")")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isMine ? Color.white.opacity(0.86) : AloTheme.accent)
            }

            if !mediaAttachments.isEmpty {
                MessageMediaGrid(attachments: mediaAttachments)
                    .frame(maxWidth: 310)
            }

            ForEach(voiceAttachments) { attachment in
                VoiceMessageAttachmentView(attachment: attachment, isMine: isMine, onLongPress: { onLongPress(bubbleFrame) })
                    .frame(maxWidth: 282)
            }

            ForEach(circleAttachments) { attachment in
                CircleMessageAttachmentView(attachment: attachment)
                    .frame(width: 184, height: 184)
            }

            if let callLogMeta {
                ChatCallLogAttachment(
                    meta: callLogMeta,
                    isMine: isMine,
                    isRead: !message.readAt.isEmpty,
                    createdAt: message.createdAt
                )
            } else if !message.body.isEmpty {
                Text(message.body)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if callLogMeta == nil {
                inlineReactionFooter(showMeta: true)
            }
        }
        .padding(.horizontal, callLogMeta == nil ? bubbleHorizontalPadding : 10)
        .padding(.vertical, callLogMeta == nil ? (attachmentsOnly ? 4 : 10) : 8)
        .background(isMine ? AloTheme.outgoing : AloTheme.incoming)
        .clipShape(RoundedRectangle(cornerRadius: voiceOnly ? 24 : 22, style: .continuous))
    }

    private var textOnlyBubble: some View {
        Group {
            if message.reactions.isEmpty {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(message.body)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.white)
                        .fixedSize(horizontal: false, vertical: true)

                    messageTimestamp
                        .layoutPriority(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(message.body)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.white)
                        .fixedSize(horizontal: false, vertical: true)

                    inlineReactionFooter(showMeta: true)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(isMine ? AloTheme.outgoing : AloTheme.incoming)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 22,
                style: .continuous
            )
        )
    }

    private var circleBubble: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            if let forwardFrom = message.forwardFrom {
                Text("Переслано от \(forwardFrom.user?.name ?? "пользователя")")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isMine ? Color.white.opacity(0.86) : AloTheme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background((isMine ? AloTheme.outgoing : AloTheme.incoming).opacity(0.9))
                    .clipShape(Capsule())
            }

            ForEach(circleAttachments) { attachment in
                CircleMessageAttachmentView(attachment: attachment)
                    .frame(width: 196, height: 196)
                    .overlay(alignment: .bottomTrailing) {
                        Text(AloFormatters.messageTime(message.createdAt))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.46))
                            .clipShape(Capsule())
                            .padding(10)
                    }
            }
        }
    }

    @ViewBuilder
    private func inlineReactionFooter(showMeta: Bool) -> some View {
        if !message.reactions.isEmpty || showMeta {
            HStack(alignment: .bottom, spacing: 8) {
                if !message.reactions.isEmpty {
                    MessageReactionStrip(
                        reactions: Array(message.reactions.prefix(3)),
                        onTap: { reaction in onReact(reaction.emoji) }
                    )
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                }

                Spacer(minLength: 6)

                if showMeta {
                    HStack(spacing: 4) {
                        if !message.editedAt.isEmpty {
                            Text("изменено")
                        }
                        Text(AloFormatters.messageTime(message.createdAt))
                        if isMine {
                            MessageReadStatusChecks(isRead: !message.readAt.isEmpty)
                        }
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .layoutPriority(1)
                }
            }
        }
    }

    private var callLogMeta: ChatCallLogMeta? {
        message.chatCallLogMeta
    }

    private var simpleTextOnly: Bool {
        callLogMeta == nil &&
        message.forwardFrom == nil &&
        !message.body.isEmpty &&
        mediaAttachments.isEmpty &&
        voiceAttachments.isEmpty &&
        circleAttachments.isEmpty
    }

    private var reactionsAnimationKey: String {
        message.reactions
            .map { "\($0.emoji)-\($0.count)-\($0.reactedByMe)" }
            .joined(separator: "|")
    }

    private var attachments: [AloMessageAttachment] {
        if !message.attachments.isEmpty { return message.attachments }
        guard !message.attachmentUrl.isEmpty else { return [] }
        return [
            AloMessageAttachment([
                "type": message.attachmentType,
                "url": message.attachmentUrl,
                "name": message.attachmentName
            ])
        ]
    }

    private var mediaAttachments: [AloMessageAttachment] {
        attachments.filter { !$0.isVoiceLike && !$0.isCircleLike }
    }

    private var voiceAttachments: [AloMessageAttachment] {
        attachments.filter(\.isVoiceLike)
    }

    private var circleAttachments: [AloMessageAttachment] {
        attachments.filter(\.isCircleLike)
    }

    private var attachmentsOnly: Bool {
        !mediaAttachments.isEmpty && voiceAttachments.isEmpty && circleAttachments.isEmpty && message.body.isEmpty
    }

    private var circleOnly: Bool {
        mediaAttachments.isEmpty && voiceAttachments.isEmpty && !circleAttachments.isEmpty && message.body.isEmpty
    }

    private var voiceOnly: Bool {
        mediaAttachments.isEmpty && !voiceAttachments.isEmpty && circleAttachments.isEmpty && message.body.isEmpty
    }

    private var bubbleHorizontalPadding: CGFloat {
        if attachmentsOnly { return 4 }
        if voiceOnly { return 10 }
        return 16
    }

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(isSelected ? AloTheme.accent : AloTheme.muted)
            .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AloTheme.accent, lineWidth: 2)
        }
    }
}

private struct ChatCallLogAttachment: View {
    let meta: ChatCallLogMeta
    let isMine: Bool
    let isRead: Bool
    let createdAt: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: meta.callType == "video" ? "video.fill" : "phone.fill")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(iconColor.opacity(isMine ? 0.18 : 0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(meta.menuTitle(isMine: isMine))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(secondaryText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .monospacedDigit()
            }

            Spacer(minLength: 10)

            HStack(spacing: 3) {
                Text(AloFormatters.messageTime(createdAt))
                if isMine {
                    MessageReadStatusChecks(isRead: isRead)
                }
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.72))
            .offset(y: 9)
        }
        .frame(width: 210, alignment: .leading)
    }

    private var iconColor: Color {
        switch meta.status {
        case "missed", "declined":
            return Color(red: 1.0, green: 0.42, blue: 0.42)
        default:
            return isMine ? Color.white.opacity(0.92) : AloTheme.accent
        }
    }

    private var secondaryText: String {
        if meta.durationSec > 0 {
            let minutes = meta.durationSec / 60
            let seconds = meta.durationSec % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
        return AloFormatters.messageTime(createdAt)
    }
}

private struct MessageReactionStrip: View {
    let reactions: [AloMessageReaction]
    let onTap: (AloMessageReaction) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { reaction in
                Button {
                    onTap(reaction)
                } label: {
                    HStack(spacing: 3) {
                        Text(reaction.emoji)
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(reaction.reactedByMe ? Color.white.opacity(0.25) : Color.white.opacity(0.13))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(reaction.reactedByMe ? 0.30 : 0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }
}

private struct MessageMediaGrid: View {
    let attachments: [AloMessageAttachment]

    var body: some View {
        Group {
            switch attachments.count {
            case 0:
                EmptyView()
            case 1:
                attachmentCell(attachments[0])
                    .frame(height: 220)
            case 2:
                HStack(spacing: 2) {
                    attachmentCell(attachments[0])
                    attachmentCell(attachments[1])
                }
                .frame(height: 190)
            case 3:
                HStack(spacing: 2) {
                    attachmentCell(attachments[0])
                    VStack(spacing: 2) {
                        attachmentCell(attachments[1])
                        attachmentCell(attachments[2])
                    }
                }
                .frame(height: 230)
            default:
                LazyVGrid(columns: gridColumns, spacing: 2) {
                    ForEach(attachments.prefix(4)) { attachment in
                        attachmentCell(attachment)
                            .frame(height: 142)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]
    }

    private func attachmentCell(_ attachment: AloMessageAttachment) -> some View {
        RemoteAttachmentCell(attachment: attachment)
    }
}

private struct VoiceMessageAttachmentView: View {
    @EnvironmentObject private var app: AloAppModel
    let attachment: AloMessageAttachment
    let isMine: Bool
    var showMessageMeta = false
    var createdAt = ""
    var editedAt = ""
    var isRead = false
    let onLongPress: () -> Void

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var endObserver: NSObjectProtocol?
    @State private var isSeeking = false
    @State private var hasStartedScrubbing = false
    @State private var playbackSpeed: Double = 1

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isMine ? AloTheme.outgoing : AloTheme.incoming)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.92))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                GeometryReader { proxy in
                    VoiceScrubberWaveform(progress: progress, levels: attachment.waveform)
                        .contentShape(Rectangle())
                        .gesture(scrubGesture(width: proxy.size.width))
                }
                .frame(height: 17)

                HStack(alignment: .center, spacing: 6) {
                    Text(voiceTimeLabel)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.76))
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    if showMessageMeta {
                        HStack(alignment: .center, spacing: 3) {
                            if !editedAt.isEmpty {
                                Text("изм.")
                            }
                            Text(AloFormatters.messageTime(createdAt))
                            if isMine {
                                MessageReadStatusChecks(isRead: isRead)
                                    .scaleEffect(0.86, anchor: .center)
                            }
                        }
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .monospacedDigit()
                    }
                }
                .frame(height: 12, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .contentShape(Rectangle())
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackDidStart)) { notification in
            guard let playingAttachmentId = notification.object as? String,
                  playingAttachmentId != attachment.id,
                  isPlaying else {
                return
            }
            player?.pause()
            isPlaying = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackToggleRequested)) { notification in
            guard (notification.object as? String) == attachment.id else { return }
            togglePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackStopRequested)) { notification in
            guard (notification.object as? String) == attachment.id else { return }
            stopPlayback()
            NotificationCenter.default.post(name: .aloVoicePlaybackDidStop, object: attachment.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackSpeedChanged)) { notification in
            guard (notification.object as? String) == attachment.id,
                  let speed = notification.userInfo?["speed"] as? Double else { return }
            playbackSpeed = speed
            if isPlaying {
                player?.rate = Float(speed)
            }
        }
        .onDisappear(perform: stopPlayback)
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, currentTime / duration))
    }

    private var voiceTimeLabel: String {
        isPlaying || currentTime > 0 ? formatTime(currentTime) : formatTime(duration)
    }

    private func togglePlayback() {
        if player == nil {
            preparePlayer()
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            NotificationCenter.default.post(
                name: .aloVoicePlaybackDidStart,
                object: attachment.id,
                userInfo: [
                    "title": attachment.name.ifBlank("Голосовое сообщение"),
                    "speed": playbackSpeed,
                    "isPlaying": false
                ]
            )
        } else {
            NotificationCenter.default.post(
                name: .aloVoicePlaybackDidStart,
                object: attachment.id,
                userInfo: [
                    "title": attachment.name.ifBlank("Голосовое сообщение"),
                    "speed": playbackSpeed,
                    "isPlaying": true
                ]
            )
            player.rate = Float(playbackSpeed)
            isPlaying = true
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
            if !hasStartedScrubbing && distance < 6 {
                    return
                }
                hasStartedScrubbing = true
                isSeeking = true
                let location = max(0, min(width, value.startLocation.x + value.translation.width))
                let normalized = min(1, max(0, location / max(1, width)))
                seek(to: normalized * duration, playAfterSeek: isPlaying)
            }
            .onEnded { _ in
                hasStartedScrubbing = false
                isSeeking = false
            }
    }

    private func seek(to seconds: Double, playAfterSeek: Bool) {
        if player == nil {
            preparePlayer()
        }
        let target = max(0, min(duration, seconds))
        currentTime = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { _ in
            if playAfterSeek {
                player?.rate = Float(playbackSpeed)
            }
        }
    }

    private func preparePlayer() {
        guard let url = app.api.absoluteURL(attachment.url) else { return }
        let player = AVPlayer(url: url)
        self.player = player
        if let item = player.currentItem {
            Task {
                let loadedDuration = try? await item.asset.load(.duration)
                if let seconds = loadedDuration?.seconds,
                   seconds.isFinite,
                   seconds > 0 {
                    await MainActor.run { duration = seconds }
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600),
            queue: .main
        ) { time in
            if !isSeeking {
                currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            isPlaying = false
            currentTime = 0
            player.seek(to: .zero)
            NotificationCenter.default.post(name: .aloVoicePlaybackDidStop, object: attachment.id)
        }
    }

    private func stopPlayback() {
        let wasPlaying = isPlaying
        player?.pause()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        timeObserver = nil
        player = nil
        isPlaying = false
        if wasPlaying {
            NotificationCenter.default.post(name: .aloVoicePlaybackDidStop, object: attachment.id)
        }
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VoiceScrubberWaveform: View {
    let progress: Double
    var levels: [CGFloat] = []

    private let fallbackLevels: [CGFloat] = [0.20, 0.68, 0.38, 0.92, 0.52, 0.78, 0.24, 0.72, 0.38, 0.88, 0.30, 0.58, 0.82, 0.42, 0.70, 0.35, 0.90, 0.44, 0.62, 0.22, 0.78, 0.50, 0.28, 0.68, 0.36, 0.86, 0.52, 0.64]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(barHeights.enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(barColor(at: index))
                    .frame(width: 2.6, height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var barHeights: [CGFloat] {
        let source = levels.isEmpty ? fallbackLevels : Array(levels.prefix(36))
        return source.map { level in
            6 + max(0.08, min(1, level)) * 15
        }
    }

    private func barColor(at index: Int) -> Color {
        let threshold = Double(index + 1) / Double(max(1, barHeights.count))
        return threshold <= progress ? Color.white : Color.white.opacity(0.34)
    }
}

private struct CircleMessageAttachmentView: View {
    @EnvironmentObject private var app: AloAppModel
    let attachment: AloMessageAttachment

    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            Circle()
                .fill(AloTheme.background)

            if let player {
                CircleVideoPlayerView(player: player)
                    .clipShape(Circle())
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "video.circle.fill")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(AloTheme.accent)
            }

            if !isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 64, height: 64)
                    .background(Color.black.opacity(0.36))
                    .clipShape(Circle())
                    .transition(.scale(scale: 0.75).combined(with: .opacity))
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(AloTheme.accent.opacity(0.75), lineWidth: 2))
        .contentShape(Circle())
        .onTapGesture(perform: togglePlayback)
        .onDisappear(perform: stopPlayback)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isPlaying)
    }

    private func togglePlayback() {
        if player == nil {
            guard let url = app.api.absoluteURL(attachment.url) else { return }
            player = AVPlayer(url: url)
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func stopPlayback() {
        player?.pause()
        player = nil
        isPlaying = false
    }
}

private struct RemoteAttachmentCell: View {
    @EnvironmentObject private var app: AloAppModel
    let attachment: AloMessageAttachment

    var body: some View {
        ZStack {
            AloTheme.background
            if isImage, let url = app.api.absoluteURL(attachment.url) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        ProgressView().tint(AloTheme.accent)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: isVideo ? "play.rectangle.fill" : "doc.fill")
                        .font(.system(size: 28, weight: .bold))
                    Text(attachment.name.ifBlank(isVideo ? "Видео" : "Файл"))
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(AloTheme.text)
                .padding(12)
            }
        }
        .clipped()
    }

    private var isImage: Bool {
        attachment.type == "image" || attachment.url.lowercased().hasImageExtension
    }

    private var isVideo: Bool {
        attachment.type == "video" || attachment.url.lowercased().hasVideoExtension
    }
}

private struct LocalAttachmentStrip: View {
    let attachments: [AloLocalAttachment]
    let onRemove: (AloLocalAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        LocalAttachmentThumb(attachment: attachment)
                        Button {
                            onRemove(attachment)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(width: 22, height: 22)
                                .background(Color.black.opacity(0.62))
                                .clipShape(Circle())
                        }
                        .padding(5)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private enum ChatRecordingMode: Equatable {
    case voice
    case circle

    var title: String {
        switch self {
        case .voice: return "Голосовое"
        case .circle: return "Кружок"
        }
    }

    var shortTitle: String {
        switch self {
        case .voice: return "ГС"
        case .circle: return "Кружок"
        }
    }

    var systemImage: String {
        switch self {
        case .voice: return "mic.fill"
        case .circle: return "video.circle.fill"
        }
    }

    var tint: Color {
        AloTheme.surface
    }
}

private enum ChatCallKind {
    case audio
    case video

    var title: String {
        switch self {
        case .audio: return "Аудиозвонок"
        case .video: return "Видеозвонок"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: return "phone.fill"
        case .video: return "video.fill"
        }
    }
}

private extension ChatCallLogMeta {
    func menuTitle(isMine: Bool) -> String {
        let isVideo = callType == "video"
        let isGroup = scope == "group"
        switch status {
        case "missed":
            return isMine ? "Звонок без ответа" : "Пропущенный звонок"
        case "declined":
            return isMine ? "Звонок отклонён" : "Отклонённый звонок"
        default:
            if isGroup && isVideo { return "Групповой видеозвонок" }
            if isGroup { return "Групповой звонок" }
            if isVideo { return isMine ? "Исходящий видеозвонок" : "Входящий видеозвонок" }
            return isMine ? "Исходящий звонок" : "Входящий звонок"
        }
    }
}

private extension AloChatMessage {
    var chatCallLogMeta: ChatCallLogMeta? {
        let candidates = [attachmentName, body, attachmentUrl].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for raw in candidates {
            if let meta = ChatCallLogMeta(rawJSON: raw) {
                return meta
            }
        }
        guard attachmentType == "call" else { return nil }
        return ChatCallLogMeta(callType: "voice", status: "ended", durationSec: 0, scope: "")
    }
}

private extension ChatCallLogMeta {
    init?(rawJSON: String) {
        guard rawJSON.contains("call") || rawJSON.contains("callType") else { return nil }
        guard let data = rawJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let kind = json.string("kind")
        let callTypeValue = json.string("callType").ifBlank(json.string("type"))
        guard kind == "call" || !callTypeValue.isEmpty || json["durationSec"] != nil else { return nil }
        callType = callTypeValue.ifBlank("voice")
        status = json.string("status").ifBlank("ended")
        durationSec = json.int("durationSec")
        scope = json.string("scope")
    }
}

private struct ChatRecordSendButton: View {
    let mode: ChatRecordingMode
    let canSend: Bool
    let isRecording: Bool
    let onSend: () -> Void
    let onToggleMode: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    let onLock: () -> Void
    let onCancel: () -> Void

    @State private var isPressing = false
    @State private var didStartHold = false
    @State private var didLockRecording = false
    @State private var didCancelRecording = false
    @State private var pressToken = UUID()

    var body: some View {
        ZStack {
            Circle()
                .fill(buttonFill)
            if isRecording {
                Circle()
                    .stroke(AloTheme.accent.opacity(0.65), lineWidth: 3)
                    .scaleEffect(1.16)
                    .opacity(0.75)
            }
            Image(systemName: canSend ? "arrow.right" : mode.systemImage)
                .font(.system(size: canSend ? 19 : 18, weight: .bold))
                .foregroundStyle(canSend ? Color.white : AloTheme.muted)
        }
        .frame(width: 48, height: 48)
        .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
        .scaleEffect(isPressing ? 0.94 : 1)
        .contentShape(Circle())
        .gesture(recordGesture)
        .accessibilityLabel(canSend ? "Отправить" : mode.title)
        .animation(.spring(response: 0.20, dampingFraction: 0.78), value: isPressing)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: mode)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }

    private var buttonFill: Color {
        if canSend { return AloTheme.accent }
        return mode.tint
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isPressing {
                    isPressing = true
                    didStartHold = false
                    didLockRecording = false
                    didCancelRecording = false
                    let token = UUID()
                    pressToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        guard isPressing, pressToken == token, !canSend else { return }
                        didStartHold = true
                        onHoldStart()
                    }
                }

                if didStartHold, !didLockRecording, value.translation.height < -44 {
                    didLockRecording = true
                    onLock()
                }

                if didStartHold, !didCancelRecording, !didLockRecording, value.translation.width < -64 {
                    didCancelRecording = true
                    onCancel()
                }
            }
            .onEnded { _ in
                let shouldFinishRecording = didStartHold
                let shouldStayLocked = didLockRecording
                let shouldCancel = didCancelRecording
                isPressing = false
                didStartHold = false
                didLockRecording = false
                didCancelRecording = false
                if canSend {
                    AloHaptics.impact(.light)
                    onSend()
                } else if shouldCancel {
                    return
                } else if shouldFinishRecording && !shouldStayLocked {
                    onHoldEnd()
                } else if shouldStayLocked {
                    return
                } else {
                    onToggleMode()
                }
            }
    }
}

private struct RecordingComposerPanel: View {
    let mode: ChatRecordingMode
    let startedAt: Date
    let isLocked: Bool
    @ObservedObject var circleRecorder: ChatCircleRecorder
    let levels: [CGFloat]
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            recordingIcon

            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                        Text(isLocked ? "Запись зафиксирована" : recordingTitle)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(recordingTime(context.date.timeIntervalSince(startedAt)))
                            .monospacedDigit()
                    }
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(AloTheme.text)

                    if mode == .voice {
                        VoiceWaveform(levels: levels)
                            .frame(height: 23)
                    } else {
                        Capsule()
                            .fill(AloTheme.accent.opacity(0.18))
                            .frame(height: 6)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(AloTheme.accent)
                                    .frame(width: isLocked ? 86 : 54, height: 6)
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            if isLocked {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(AloTheme.muted)
                        .frame(width: 40, height: 40)
                        .background(AloTheme.surfaceRaised)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button(action: onSend) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 44, height: 44)
                        .background(AloTheme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, minHeight: mode == .circle ? 68 : 58, alignment: .leading)
        .padding(.leading, mode == .circle ? 7 : 8)
        .padding(.trailing, isLocked ? 7 : 12)
        .padding(.vertical, 6)
        .background {
            Capsule().fill(AloTheme.surface)
            Capsule().stroke(AloTheme.border, lineWidth: 1)
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: isLocked)
    }

    @ViewBuilder
    private var recordingIcon: some View {
        if mode == .circle {
            CircleCameraPreview(session: circleRecorder.session)
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay(Circle().stroke(AloTheme.accent.opacity(0.9), lineWidth: 2))
                .shadow(color: AloTheme.accent.opacity(0.22), radius: 12)
        } else {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.18))
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.red)
            }
            .frame(width: 44, height: 44)
        }
    }

    private var recordingTitle: String {
        switch mode {
        case .voice: return "Запись"
        case .circle: return "Кружок"
        }
    }

    private func recordingTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CircleRecordingOverlay: View {
    let startedAt: Date
    let isLocked: Bool
    @ObservedObject var recorder: ChatCircleRecorder
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .background(Color.black.opacity(0.28))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 54)

                CircleCameraPreview(session: recorder.session)
                    .frame(width: 286, height: 286)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.32), radius: 24, y: 14)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))

                Spacer(minLength: 36)

                HStack(spacing: 10) {
                    CircleIconButton(systemName: "camera.rotate", action: { recorder.switchCamera() })
                    CircleIconButton(systemName: recorder.isTorchEnabled ? "bolt.fill" : "bolt.slash", action: { recorder.toggleTorch() })

                    TimelineView(.periodic(from: startedAt, by: 0.2)) { context in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 7, height: 7)
                            Text(formatTime(context.date.timeIntervalSince(startedAt)))
                                .font(.system(size: 16, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                            Spacer(minLength: 10)
                            Button("Отмена", action: onCancel)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(AloTheme.accent)
                        }
                    }
                    .foregroundStyle(AloTheme.text)
                    .padding(.horizontal, 13)
                    .frame(height: 46)
                    .background(Color.black.opacity(0.38))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))

                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 30, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .frame(width: 76, height: 76)
                            .background(AloTheme.accent)
                            .clipShape(Circle())
                            .shadow(color: AloTheme.accent.opacity(0.40), radius: 14)
                    }
                    .buttonStyle(.plain)
                    .opacity(isLocked ? 1 : 0.72)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isLocked)
        .onAppear { AloHaptics.impact(.medium) }
    }

    private func formatTime(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CircleIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 46, height: 46)
                .background(Color.black.opacity(0.38))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct VoicePlaybackTopBar: View {
    let playback: ActiveVoicePlayback
    let onToggle: () -> Void
    let onSpeed: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(AloTheme.text)
                    .frame(width: 30, height: 30)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(playback.title)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(AloTheme.text)
                    .lineLimit(1)
                Text("Голосовое сообщение")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(AloTheme.muted)
            }

            Spacer(minLength: 8)

            Button(action: onSpeed) {
                Text(speedTitle)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(AloTheme.text)
                    .frame(minWidth: 34, minHeight: 30)
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AloTheme.surface.opacity(0.80))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AloTheme.border.opacity(0.45), lineWidth: 1)
        )
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: playback.isPlaying)
    }

    private var speedTitle: String {
        playback.speed == 1 ? "1x" : String(format: "%.1fx", playback.speed)
    }
}

private struct VoiceWaveform: View {
    var levels: [CGFloat] = []
    private let bars: [CGFloat] = [0.28, 0.68, 0.42, 0.88, 0.56, 0.74, 0.34, 0.92, 0.48, 0.78, 0.36, 0.66]

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(Array(renderedBars.enumerated()), id: \.offset) { index, value in
                    Capsule()
                        .fill(AloTheme.accent)
                        .frame(width: 4, height: 26 * animatedHeight(value, index: index, phase: phase))
                }
            }
        }
    }

    private var renderedBars: [CGFloat] {
        let cleaned = levels.suffix(18).map { max(0.12, min(1, $0)) }
        guard !cleaned.isEmpty else { return bars }
        return Array(cleaned)
    }

    private func animatedHeight(_ base: CGFloat, index: Int, phase: TimeInterval) -> CGFloat {
        if !levels.isEmpty { return max(0.18, min(1, base)) }
        let wave = CGFloat((sin(phase * 5 + Double(index) * 0.65) + 1) / 2)
        return max(0.22, min(1, base * 0.62 + wave * 0.46))
    }
}

private struct ChatComposerButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AloTheme.muted)
                .frame(width: 48, height: 48)
                .background(AloTheme.surface)
                .clipShape(Circle())
                .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct LocalAttachmentThumb: View {
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
        .frame(width: 74, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }
}

private struct RecordedDraftComposerPanel: View {
    let attachment: AloLocalAttachment
    let duration: TimeInterval
    let levels: [CGFloat]
    let onRemove: () -> Void

    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePlayback) {
                ZStack {
                    Circle()
                        .fill(attachment.isLocalCircleLike ? AloTheme.accent.opacity(0.18) : Color.white.opacity(0.12))
                    Image(systemName: buttonIcon)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(attachment.isLocalCircleLike ? AloTheme.accent : Color.white)
                }
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .disabled(!attachment.isLocalVoiceLike)

            VStack(alignment: .leading, spacing: 5) {
                if attachment.isLocalVoiceLike {
                    VoiceWaveform(levels: levels)
                        .frame(height: 26)
                } else {
                    VoiceWaveform()
                        .frame(height: 22)
                }

                Text(formatTime(duration))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AloTheme.muted)
                    .monospacedDigit()
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 38, height: 38)
                    .background(AloTheme.surfaceRaised)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .background(AloTheme.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(AloTheme.border, lineWidth: 1))
        .onDisappear(perform: stopPlayback)
    }

    private var buttonIcon: String {
        if attachment.isLocalCircleLike { return "video.circle.fill" }
        return isPlaying ? "pause.fill" : "play.fill"
    }

    private func togglePlayback() {
        guard attachment.isLocalVoiceLike else { return }
        if audioPlayer == nil {
            audioPlayer = try? AVAudioPlayer(data: attachment.data)
            audioPlayer?.prepareToPlay()
        }
        guard let audioPlayer else { return }
        if isPlaying {
            audioPlayer.pause()
            isPlaying = false
        } else {
            audioPlayer.play()
            isPlaying = true
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
    }

    private func formatTime(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.isFinite ? value.rounded() : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MessageReadStatusChecks: View {
    let isRead: Bool

    var body: some View {
        ZStack {
            Image(systemName: "checkmark")
                .offset(x: isRead ? -3.2 : 0)
            if isRead {
                Image(systemName: "checkmark")
                    .offset(x: 3.2)
            }
        }
        .font(.system(size: 11.5, weight: .heavy))
        .foregroundStyle(Color.white.opacity(isRead ? 0.86 : 0.68))
        .frame(width: isRead ? 16 : 9, height: 10)
        .accessibilityLabel(isRead ? "Прочитано" : "Отправлено")
    }
}

private struct MessageActionOverlay: View {
    @EnvironmentObject private var app: AloAppModel
    let message: AloChatMessage
    let targetFrame: CGRect?
    let onCopy: () -> Void
    let onForward: () -> Void
    let onEdit: () -> Void
    let onReact: (String) -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    private let reactionEmojis = ["❤️", "🔥", "😂", "😮", "👏", "👍"]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ZStack {
                    Rectangle()
                        .fill(.regularMaterial)
                        .opacity(0.42)
                    Color.black.opacity(0.36)
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

                reactionsRow
                    .position(reactionsPosition(in: proxy.size))
                    .transition(.scale(scale: 0.98).combined(with: .opacity))

                MessageActionPreviewBubble(message: message, previewText: previewText)
                    .frame(width: previewFrame(in: proxy.size).width, alignment: isMine ? .trailing : .leading)
                    .position(previewPosition(in: proxy.size))
                    .transition(.opacity)

                actionMenu
                    .frame(width: menuWidth(in: proxy.size), alignment: .leading)
                    .position(actionMenuPosition(in: proxy.size))
                    .transition(.scale(scale: 0.985, anchor: .center).combined(with: .opacity))
            }
        }
        .onAppear { AloHaptics.impact(.medium) }
    }

    private var reactionsRow: some View {
        HStack(spacing: 8) {
            ForEach(reactionEmojis, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 24))
                        .frame(width: 42, height: 42)
                        .background(Color.black.opacity(0.34))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
    }

    private var actionMenu: some View {
        VStack(spacing: 0) {
            if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MessageActionButton(title: "Скопировать", systemName: "doc.on.doc", action: onCopy)
            }
            if canEdit {
                MessageActionButton(title: "Изменить", systemName: "square.and.pencil", action: onEdit)
            }
            if message.chatCallLogMeta == nil {
                MessageActionButton(title: "Переслать", systemName: "arrowshape.turn.up.right", action: onForward)
            }
            MessageActionButton(title: "Удалить", systemName: "trash", tint: .red, action: onDelete)

            Divider()
                .background(AloTheme.border.opacity(0.8))
                .padding(.vertical, 6)
                .padding(.horizontal, 16)

            MessageActionButton(title: "Выбрать", systemName: "checkmark.circle", action: onSelect)
        }
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AloTheme.surface.opacity(0.88))
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AloTheme.border.opacity(0.55), lineWidth: 1)
        )
    }

    private func menuWidth(in size: CGSize) -> CGFloat {
        min(360, max(300, size.width - 36))
    }

    private func sourceFrame(in size: CGSize) -> CGRect {
        targetFrame ?? CGRect(x: size.width / 2 - 80, y: size.height / 2 - 28, width: 160, height: 56)
    }

    private func previewFrame(in size: CGSize) -> CGRect {
        let source = sourceFrame(in: size)
        let maxWidth = max(120, size.width - 36)
        return CGRect(
            x: source.minX,
            y: source.minY,
            width: min(max(source.width, 42), maxWidth),
            height: source.height
        )
    }

    private func previewPosition(in size: CGSize) -> CGPoint {
        let source = previewFrame(in: size)
        let x = min(max(source.midX, source.width / 2 + 18), size.width - source.width / 2 - 18)
        let y = min(max(source.midY, source.height / 2 + 18), size.height - source.height / 2 - 18)
        return CGPoint(x: x, y: y)
    }

    private func reactionsPosition(in size: CGSize) -> CGPoint {
        let source = sourceFrame(in: size)
        let width: CGFloat = 308
        let preferredX = isMine ? source.maxX - width / 2 : source.minX + width / 2
        let x = min(max(preferredX, width / 2 + 18), size.width - width / 2 - 18)
        let y = max(68, source.minY - 28)
        return CGPoint(x: x, y: y)
    }

    private func actionMenuPosition(in size: CGSize) -> CGPoint {
        let width = menuWidth(in: size)
        let estimatedHeight = estimatedActionMenuHeight
        let source = sourceFrame(in: size)
        let preferredX = isMine ? source.maxX - width / 2 : source.minX + width / 2
        let belowY = source.maxY + estimatedHeight / 2 + 18
        let aboveY = source.minY - estimatedHeight / 2 - 60
        let preferredY = belowY <= size.height - 34 ? belowY : aboveY
        let x = min(max(preferredX, width / 2 + 18), size.width - width / 2 - 18)
        let y = min(max(preferredY, estimatedHeight / 2 + 34), size.height - estimatedHeight / 2 - 34)
        return CGPoint(x: x, y: y)
    }

    private var estimatedActionMenuHeight: CGFloat {
        var rows = 2
        if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows += 1
        }
        if canEdit {
            rows += 1
        }
        if message.chatCallLogMeta == nil {
            rows += 1
        }
        return CGFloat(rows) * 56 + 18
    }

    private var isMine: Bool {
        message.senderId == app.bootstrap?.me.id
    }

    private var previewText: String {
        if let callLogMeta = message.chatCallLogMeta {
            return callLogMeta.menuTitle(isMine: message.senderId == app.bootstrap?.me.id)
        }
        if !message.body.isEmpty {
            return message.body
        }
        let attachments = !message.attachments.isEmpty ? message.attachments : legacyAttachments
        if attachments.contains(where: \.isVoiceLike) {
            return "Голосовое сообщение"
        }
        if attachments.contains(where: \.isCircleLike) {
            return "Кружок"
        }
        let imageCount = attachments.filter { $0.type == "image" || $0.url.lowercased().hasImageExtension }.count
        let videoCount = attachments.filter { $0.type == "video" || $0.url.lowercased().hasVideoExtension }.count
        if imageCount > 0 && videoCount > 0 {
            return "\(imageCount) фото, \(videoCount) видео"
        }
        if imageCount > 1 {
            return "\(imageCount) фото"
        }
        if videoCount > 1 {
            return "\(videoCount) видео"
        }
        if imageCount == 1 {
            return "Фотография"
        }
        if videoCount == 1 {
            return "Видео"
        }
        if !attachments.isEmpty {
            return attachments.first?.name.ifBlank("Файл") ?? "Файл"
        }
        if message.forwardFrom != nil {
            return "Пересланное сообщение"
        }
        return "Без текста"
    }

    private var canEdit: Bool {
        message.senderId == app.bootstrap?.me.id && !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var legacyAttachments: [AloMessageAttachment] {
        guard !message.attachmentUrl.isEmpty else { return [] }
        return [
            AloMessageAttachment([
                "type": message.attachmentType,
                "url": message.attachmentUrl,
                "name": message.attachmentName
            ])
        ]
    }
}

private struct MessageActionPreviewBubble: View {
    @EnvironmentObject private var app: AloAppModel
    let message: AloChatMessage
    let previewText: String

    var body: some View {
        let isMine = message.senderId == app.bootstrap?.me.id
        previewContent(isMine: isMine)
            .shadow(color: Color.black.opacity(0.24), radius: 12, y: 6)
    }

    @ViewBuilder
    private func previewContent(isMine: Bool) -> some View {
        if let callLogMeta = message.chatCallLogMeta {
            callPreview(callLogMeta, isMine: isMine)
        } else if let attachment = firstAttachment, attachment.isVoiceLike {
            voicePreview(attachment, isMine: isMine)
        } else if let attachment = firstAttachment, attachment.isCircleLike {
            circlePreview(attachment, isMine: isMine)
        } else if let attachment = firstAttachment {
            attachmentPreview(attachment, isMine: isMine)
        } else {
            textPreview(isMine: isMine)
        }
    }

    private func voicePreview(_ attachment: AloMessageAttachment, isMine: Bool) -> some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            if let forwardFrom = message.forwardFrom {
                Text("Переслано от \(forwardFrom.user?.name ?? "пользователя")")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isMine ? Color.white.opacity(0.86) : AloTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VoiceMessageAttachmentView(
                attachment: attachment,
                isMine: isMine,
                showMessageMeta: true,
                createdAt: message.createdAt,
                editedAt: message.editedAt,
                isRead: !message.readAt.isEmpty,
                onLongPress: {}
            )
            .environmentObject(app)

            previewReactionFooter(showMeta: false, isMine: isMine)
        }
        .frame(width: 220, alignment: isMine ? .trailing : .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isMine ? AloTheme.outgoing : AloTheme.incoming)
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
    }

    private func textPreview(isMine: Bool) -> some View {
        Group {
            if message.reactions.isEmpty {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(previewText)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.white)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 3) {
                        Text(AloFormatters.messageTime(message.createdAt))
                        if isMine {
                            MessageReadStatusChecks(isRead: !message.readAt.isEmpty)
                        }
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .layoutPriority(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(previewText)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.white)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)

                    previewReactionFooter(showMeta: true, isMine: isMine)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(isMine ? AloTheme.outgoing : AloTheme.incoming)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func callPreview(_ callLogMeta: ChatCallLogMeta, isMine: Bool) -> some View {
        ChatCallLogAttachment(
            meta: callLogMeta,
            isMine: isMine,
            isRead: !message.readAt.isEmpty,
            createdAt: message.createdAt
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isMine ? AloTheme.outgoing : AloTheme.incoming)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func circlePreview(_ attachment: AloMessageAttachment, isMine: Bool) -> some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            CircleMessageAttachmentView(attachment: attachment)
                .frame(width: 196, height: 196)
                .overlay(alignment: .bottomTrailing) {
                    Text(AloFormatters.messageTime(message.createdAt))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.38))
                        .clipShape(Capsule())
                        .padding(8)
                }
        }
    }

    private func attachmentPreview(_ attachment: AloMessageAttachment, isMine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MessageActionAttachmentPreview(attachment: attachment, isMine: isMine)
                .environmentObject(app)

            if !message.body.isEmpty {
                Text(message.body)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.white)
                    .lineLimit(3)
            }

            previewReactionFooter(showMeta: true, isMine: isMine)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(width: 260, alignment: .leading)
        .background(isMine ? AloTheme.outgoing : AloTheme.incoming)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var firstAttachment: AloMessageAttachment? {
        let attachments = !message.attachments.isEmpty ? message.attachments : legacyAttachments
        return attachments.first
    }

    @ViewBuilder
    private func previewReactionFooter(showMeta: Bool, isMine: Bool) -> some View {
        if !message.reactions.isEmpty || showMeta {
            HStack(alignment: .bottom, spacing: 8) {
                if !message.reactions.isEmpty {
                    MessageReactionStrip(
                        reactions: Array(message.reactions.prefix(3)),
                        onTap: { _ in }
                    )
                }

                Spacer(minLength: 6)

                if showMeta {
                    HStack(spacing: 3) {
                        Text(AloFormatters.messageTime(message.createdAt))
                        if isMine {
                            MessageReadStatusChecks(isRead: !message.readAt.isEmpty)
                        }
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .layoutPriority(1)
                }
            }
        }
    }

    private var legacyAttachments: [AloMessageAttachment] {
        guard !message.attachmentUrl.isEmpty else { return [] }
        return [
            AloMessageAttachment([
                "type": message.attachmentType,
                "url": message.attachmentUrl,
                "name": message.attachmentName
            ])
        ]
    }
}

private struct MessageActionAttachmentPreview: View {
    @EnvironmentObject private var app: AloAppModel
    let attachment: AloMessageAttachment
    let isMine: Bool

    var body: some View {
        ZStack {
            (isMine ? Color.white.opacity(0.10) : AloTheme.background.opacity(0.86))

            if attachment.isVoiceLike {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(isMine ? AloTheme.outgoing : AloTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.92))
                        .clipShape(Circle())
                    VoiceScrubberWaveform(progress: 0, levels: attachment.waveform)
                        .frame(height: 24)
                }
                .padding(.horizontal, 12)
            } else if let url = previewURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        ProgressView().tint(AloTheme.accent)
                    }
                }
            } else {
                Image(systemName: attachment.isCircleLike ? "video.circle.fill" : "doc.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
            }

            if attachment.type == "video" || attachment.isCircleLike {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.46))
                    .clipShape(Circle())
            }
        }
        .frame(height: attachment.isVoiceLike ? 58 : 132)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var previewURL: URL? {
        app.api.absoluteURL(attachment.posterUrl.ifBlank(attachment.url))
    }
}

private struct MessageActionButton: View {
    let title: String
    let systemName: String
    var tint: Color = AloTheme.text
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button {
            AloHaptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                Spacer()
            }
            .foregroundStyle(disabled ? AloTheme.muted.opacity(0.45) : tint)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct ChatAttachmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var attachments: [AloLocalAttachment]
    @State private var pickedItems = [PhotosPickerItem]()
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(AloTheme.muted.opacity(0.55))
                .frame(width: 54, height: 5)
                .frame(maxWidth: .infinity)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Вложения")
                        .font(.system(size: 24, weight: .bold))
                    Text("Можно выбрать несколько фото или видео.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                }
                Spacer()
                Button("Готово") {
                    dismiss()
                }
                .font(.system(size: 16, weight: .bold))
            }

            PhotosPicker(
                selection: $pickedItems,
                maxSelectionCount: 10,
                matching: .any(of: [.images, .videos])
            ) {
                Label("Выбрать из галереи", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(AloTheme.accent)
                    .clipShape(Capsule())
            }

            if isLoading {
                HStack {
                    ProgressView().tint(AloTheme.accent)
                    Text("Загружаем предпросмотр...")
                        .foregroundStyle(AloTheme.muted)
                }
                .font(.system(size: 15, weight: .semibold))
            }

            if attachments.isEmpty {
                ContentUnavailableView(
                    "Медиа не выбраны",
                    systemImage: "photo",
                    description: Text("Выбери фото или видео, и они появятся здесь перед отправкой.")
                )
                .foregroundStyle(AloTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                    ForEach(attachments) { attachment in
                        LocalAttachmentThumb(attachment: attachment)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onChange(of: pickedItems) { _, newItems in
            Task { await loadPickedItems(newItems) }
        }
    }

    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        isLoading = true
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
                    name: "media-\(index + 1).\(ext)"
                )
            )
        }
        attachments = next
        isLoading = false
    }
}

private struct ForwardTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversations: [AloConversationSummary]
    let currentPeerId: Int
    let onPick: (AloConversationSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(AloTheme.muted.opacity(0.55))
                .frame(width: 54, height: 5)
                .frame(maxWidth: .infinity)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Кому переслать")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Выбери чат, сообщение появится в поле ввода.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AloTheme.muted)
                        .frame(width: 40, height: 40)
                        .background(AloTheme.surfaceRaised)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(conversations) { conversation in
                        Button {
                            onPick(conversation)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                AloAvatar(name: conversation.peer.name, url: conversation.peer.avatarUrl, size: 52)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(conversation.peer.name)
                                            .font(.system(size: 17, weight: .bold))
                                            .foregroundStyle(AloTheme.text)
                                            .lineLimit(1)
                                        if conversation.peerId == currentPeerId {
                                            Text("текущий")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(AloTheme.accent)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(AloTheme.accent.opacity(0.14))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(conversation.lastBody.ifBlank("Чат"))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AloTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(AloTheme.accent)
                            }
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                            .background(AloTheme.border)
                            .padding(.leading, 64)
                    }
                }
            }
        }
        .padding(18)
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

private struct MessageSelectionToolbar: View {
    let count: Int
    let onCancel: () -> Void
    let onForward: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Выбрано: \(count)")
                    .font(.system(size: 16, weight: .bold))
                Text("Можно переслать или удалить")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
            }
            Spacer()
            Button(action: onForward) {
                Image(systemName: "arrowshape.turn.up.right.fill")
                    .frame(width: 44, height: 44)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash.fill")
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(AloTheme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AloTheme.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(AloTheme.border, lineWidth: 1))
    }
}

private struct ForwardDraftBar: View {
    let title: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(AloTheme.accent)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                Text("Отправь в этот чат или отмени")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(12)
        .background(AloTheme.surface.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }
}

private struct EditDraftBar: View {
    let preview: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(AloTheme.accent)
                .frame(width: 4)
            Image(systemName: "square.and.pencil")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AloTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Редактировать сообщение")
                    .font(.system(size: 15, weight: .bold))
                Text(preview.ifBlank("Сообщение"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(12)
        .background(AloTheme.surface.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }
}

private struct ChatPeerInfoPanel: View {
    @EnvironmentObject private var app: AloAppModel
    let conversation: AloConversationDetail
    let messages: [AloChatMessage]
    let onClose: () -> Void
    let onOpenProfile: () -> Void
    let onAudioCall: () -> Void
    let onVideoCall: () -> Void

    @State private var selectedMediaTab: PeerMediaTab = .photos
    @State private var selectedGroupAvatarItem: PhotosPickerItem?
    @State private var isLeaveGroupConfirmationPresented = false
    @State private var isDeleteGroupConfirmationPresented = false

    var body: some View {
        ZStack {
            AloTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    hero
                    quickActions
                    if conversation.kind == "group" {
                        groupMembersSection
                        groupDangerSection
                    }
                    mediaTabs
                    mediaContent
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 26)
            }
        }
        .onChange(of: selectedGroupAvatarItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                await MainActor.run {
                    app.updateGroupAvatar(conversation: conversation, data: data, mime: mime)
                    selectedGroupAvatarItem = nil
                }
            }
        }
        .confirmationDialog(
            "Покинуть группу?",
            isPresented: $isLeaveGroupConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Покинуть", role: .destructive) {
                app.leaveGroupChat(conversation)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(conversation.groupMemberRole == "owner" ? "Если в группе есть участники, владелец будет передан следующему участнику. Если участников нет, группа удалится." : "Вы сможете вернуться только если вас добавят снова.")
        }
        .confirmationDialog(
            "Удалить группу?",
            isPresented: $isDeleteGroupConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Удалить группу", role: .destructive) {
                app.deleteGroupChat(conversation)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Группа, сообщения и список участников будут удалены для всех.")
        }
    }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 10) {
                AloAvatar(name: conversation.title, url: conversation.avatarUrl, size: 94)
                    .padding(.top, 34)
                Text(conversation.title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(AloTheme.text)
                    .lineLimit(1)
                Text(conversation.online ? "в сети" : conversation.subtitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 42, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
            .padding(.top, 7)
        }
        .background(AloTheme.surface.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            if conversation.kind != "group" {
                PeerActionButton(title: "Профиль", systemName: "person", action: onOpenProfile)
            }
            PeerActionButton(title: "Поиск", systemName: "magnifyingglass", action: {})
            PeerActionButton(title: "Тихий", systemName: "bell.slash", action: {})
            PeerActionButton(title: "Медиа", systemName: "paperclip", action: {})
            if conversation.kind == "group", conversation.canManageGroup {
                PhotosPicker(
                    selection: $selectedGroupAvatarItem,
                    matching: .images
                ) {
                    PeerActionButtonLabel(title: "Аватарка", systemName: "photo")
                }
                .buttonStyle(.plain)
            }
            PeerActionButton(title: "Звонок", systemName: "phone", action: onAudioCall)
            PeerActionButton(title: "Видео", systemName: "video", action: onVideoCall)
        }
    }

    private var mediaTabs: some View {
        HStack(spacing: 0) {
            ForEach(PeerMediaTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                        selectedMediaTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(selectedMediaTab == tab ? AloTheme.text : AloTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background {
                            if selectedMediaTab == tab {
                                Capsule()
                                    .fill(AloTheme.surfaceRaised)
                                    .matchedGeometryEffect(id: "peerMediaTab", in: tabNamespace)
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

    @Namespace private var tabNamespace

    private var groupMembersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(conversation.groupMembers.count) участников")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(AloTheme.text)

            ForEach(conversation.groupMembers.prefix(16)) { member in
                HStack(spacing: 11) {
                    AloAvatar(name: member.name, url: member.avatarUrl, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(AloTheme.text)
                            .lineLimit(1)
                        Text(member.username.isEmpty ? member.roleLabel : "@\(member.username)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AloTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !member.roleLabel.isEmpty {
                        Text(member.roleLabel)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(AloTheme.muted)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.surface.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var groupDangerSection: some View {
        VStack(spacing: 10) {
            Button(role: .destructive) {
                isLeaveGroupConfirmationPresented = true
            } label: {
                Label("Покинуть группу", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(AloTheme.surface.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)

            if conversation.groupMemberRole == "owner" {
                Button(role: .destructive) {
                    isDeleteGroupConfirmationPresented = true
                } label: {
                    Label("Удалить группу", systemImage: "trash")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(AloTheme.surface.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        let attachments = filteredAttachments
        if attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedMediaTab.emptyTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(AloTheme.text)
                Text(selectedMediaTab.emptySubtitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .frame(minHeight: 170, alignment: .topLeading)
            .background(AloTheme.surface.opacity(0.68))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)], spacing: 3) {
                ForEach(attachments.prefix(24)) { attachment in
                    RemoteAttachmentCell(attachment: attachment)
                        .frame(height: 164)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: selectedMediaTab)
        }
    }

    private var allAttachments: [AloMessageAttachment] {
        messages.flatMap { message in
            if !message.attachments.isEmpty { return message.attachments }
            if message.attachmentUrl.isEmpty { return [] }
            return [
                AloMessageAttachment([
                    "type": message.attachmentType,
                    "url": message.attachmentUrl,
                    "name": message.attachmentName
                ])
            ]
        }
    }

    private var filteredAttachments: [AloMessageAttachment] {
        allAttachments.filter { selectedMediaTab.matches($0) }
    }
}

private struct PeerActionButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PeerActionButtonLabel(title: title, systemName: systemName)
        }
        .buttonStyle(.plain)
    }
}

private struct PeerActionButtonLabel: View {
    let title: String
    let systemName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .frame(width: 24)
            Text(title)
                .font(.system(size: 16, weight: .bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(AloTheme.text)
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(AloTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }
}

private enum PeerMediaTab: String, CaseIterable, Identifiable {
    case photos
    case videos
    case voices
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "Фото"
        case .videos: return "Видео"
        case .voices: return "ГС"
        case .files: return "Файлы"
        }
    }

    var emptyTitle: String {
        switch self {
        case .photos: return "Фотографий пока нет"
        case .videos: return "Видео пока нет"
        case .voices: return "Голосовых пока нет"
        case .files: return "Файлов пока нет"
        }
    }

    var emptySubtitle: String {
        switch self {
        case .photos: return "Когда в чате появятся изображения, они будут здесь."
        case .videos: return "Видео из переписки появятся в этом разделе."
        case .voices: return "Голосовые и кружки будут собраны здесь."
        case .files: return "Документы и остальные файлы будут здесь."
        }
    }

    func matches(_ attachment: AloMessageAttachment) -> Bool {
        let type = attachment.type.lowercased()
        let url = attachment.url.lowercased()
        switch self {
        case .photos:
            return type == "image" || url.hasImageExtension
        case .videos:
            return type == "video" || url.hasVideoExtension
        case .voices:
            return type == "audio" || type == "voice" || type == "circle" || url.hasSuffix(".m4a") || url.hasSuffix(".aac") || url.hasSuffix(".mp3")
        case .files:
            return !PeerMediaTab.photos.matches(attachment) &&
                !PeerMediaTab.videos.matches(attachment) &&
                !PeerMediaTab.voices.matches(attachment)
        }
    }
}

private struct ChatCallScreen: View {
    let kind: ChatCallKind
    let conversation: AloConversationDetail
    let onEnd: () -> Void

    @State private var isMuted = false
    @State private var isCameraOff = false
    @State private var isSpeakerOn = true
    @State private var startedAt = Date()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AloTheme.background,
                    Color(red: 0.035, green: 0.07, blue: 0.13),
                    AloTheme.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer(minLength: 22)
                AloAvatar(name: conversation.title, url: conversation.avatarUrl, size: 112)
                VStack(spacing: 6) {
                    Text(conversation.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(AloTheme.text)
                        .lineLimit(1)
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("\(kind.title) · \(callTime(context.date.timeIntervalSince(startedAt)))")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AloTheme.muted)
                            .monospacedDigit()
                    }
                }

                if kind == .video {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(AloTheme.surface)
                        .overlay {
                            VStack(spacing: 10) {
                                Image(systemName: isCameraOff ? "video.slash.fill" : "video.fill")
                                    .font(.system(size: 36, weight: .bold))
                                Text(isCameraOff ? "Камера выключена" : "Видео готово")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .foregroundStyle(AloTheme.muted)
                        }
                        .frame(height: 240)
                        .padding(.horizontal, 18)
                }

                Spacer()

                HStack(spacing: 16) {
                    CallControlButton(systemName: isMuted ? "mic.slash.fill" : "mic.fill", title: "Микрофон", isActive: !isMuted) {
                        isMuted.toggle()
                    }
                    if kind == .video {
                        CallControlButton(systemName: isCameraOff ? "video.slash.fill" : "video.fill", title: "Камера", isActive: !isCameraOff) {
                            isCameraOff.toggle()
                        }
                    }
                    CallControlButton(systemName: isSpeakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill", title: "Звук", isActive: isSpeakerOn) {
                        isSpeakerOn.toggle()
                    }
                    CallControlButton(systemName: "phone.down.fill", title: "Завершить", isDestructive: true, isActive: true, action: onEnd)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 26)
            }
        }
        .onAppear { startedAt = Date() }
    }

    private func callTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CallControlButton: View {
    let systemName: String
    let title: String
    var isDestructive = false
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 58, height: 58)
                    .background(isDestructive ? Color.red : (isActive ? AloTheme.surfaceRaised : AloTheme.surface))
                    .foregroundStyle(isDestructive ? Color.white : AloTheme.text)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

private final class ChatAudioRecorder: NSObject, ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var levels: [CGFloat] = []

    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    private var meterTimer: Timer?

    func start() {
        Task { @MainActor in
            let granted = await requestPermission()
            guard granted else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("alo-voice-\(UUID().uuidString).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                outputURL = url
                recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder?.isMeteringEnabled = true
                recorder?.record()
                updateLevels([])
                startMetering()
            } catch {
                stopMetering(clearLevels: true)
                recorder = nil
                outputURL = nil
            }
        }
    }

    func stop(completion: @escaping (AloLocalAttachment?, [CGFloat]) -> Void) {
        stopMetering(clearLevels: false)
        recorder?.stop()
        recorder = nil
        guard let outputURL,
              let data = try? Data(contentsOf: outputURL),
              !data.isEmpty else {
            completion(nil, [])
            return
        }
        let waveform = Self.extractWaveform(from: outputURL, samples: 28)
        try? FileManager.default.removeItem(at: outputURL)
        self.outputURL = nil
        completion(
            AloLocalAttachment(
                data: data,
                mime: "audio/m4a",
                type: "audio",
                name: "voice-\(Int(Date().timeIntervalSince1970)).m4a",
                waveform: waveform
            ),
            waveform
        )
    }

    func cancel() {
        stopMetering(clearLevels: true)
        recorder?.stop()
        recorder = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    private func startMetering() {
        stopMetering(clearLevels: false)
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            recorder.updateMeters()
            let average = recorder.averagePower(forChannel: 0)
            let peak = recorder.peakPower(forChannel: 0)
            let power = max(average, peak - 8)
            let normalized = pow(10, power / 34)
            let level = CGFloat(max(0.10, min(1, normalized)))
            self.updateLevels(Array((self.levels + [level]).suffix(28)))
        }
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMetering(clearLevels: Bool) {
        meterTimer?.invalidate()
        meterTimer = nil
        if clearLevels {
            updateLevels([])
        }
    }

    private func updateLevels(_ nextLevels: [CGFloat]) {
        objectWillChange.send()
        levels = nextLevels
    }

    private static func extractWaveform(from url: URL, samples: Int) -> [CGFloat] {
        guard samples > 0,
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ) else {
            return []
        }

        do {
            try file.read(into: buffer)
        } catch {
            return []
        }

        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }

        let stride = max(1, frameCount / samples)
        return (0..<samples).map { sampleIndex in
            let start = min(sampleIndex * stride, frameCount - 1)
            let end = min(start + stride, frameCount)
            var sum: Float = 0
            var count: Float = 0

            for frame in start..<end {
                let value = channelData[0][frame]
                sum += value * value
                count += 1
            }

            let rms = sqrt(sum / max(count, 1))
            return CGFloat(max(0.10, min(1, sqrt(rms) * 1.6)))
        }
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

private final class ChatCircleRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let objectWillChange = ObservableObjectPublisher()

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "alo.circle.recorder.session", qos: .userInitiated)
    private let movieOutput = AVCaptureMovieFileOutput()
    private var outputURL: URL?
    private var completion: ((AloLocalAttachment?) -> Void)?
    private var pendingStopCompletion: ((AloLocalAttachment?) -> Void)?
    private var isStartingRecording = false
    private var isConfigured = false
    private var isConfiguring = false
    private var currentVideoInput: AVCaptureDeviceInput?
    private var currentCameraPosition: AVCaptureDevice.Position = .front
    private(set) var isTorchEnabled = false {
        didSet { objectWillChange.send() }
    }

    func start() {
        Task { @MainActor in
            let configured = await configureIfNeeded()
            guard configured else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("alo-circle-\(UUID().uuidString).mov")
            outputURL = url
            isStartingRecording = true
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async {
                    guard self.outputURL == url else { return }
                    self.isStartingRecording = false
                    if let connection = self.movieOutput.connection(with: .video),
                       connection.isVideoMirroringSupported {
                        connection.isVideoMirrored = self.currentCameraPosition == .front
                    }
                    if !self.movieOutput.isRecording {
                        self.movieOutput.startRecording(to: url, recordingDelegate: self)
                    }
                    self.finishPendingStopIfNeeded()
                }
            }
        }
    }

    func stop(completion: @escaping (AloLocalAttachment?) -> Void) {
        guard movieOutput.isRecording else {
            if isStartingRecording {
                pendingStopCompletion = completion
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self else { return }
                if self.movieOutput.isRecording {
                    self.completion = completion
                    self.movieOutput.stopRecording()
                } else {
                    self.cleanupOutputFile()
                    completion(nil)
                }
            }
            return
        }
        self.completion = completion
        movieOutput.stopRecording()
    }

    func cancel() {
        pendingStopCompletion = nil
        isStartingRecording = false
        completion = nil
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        cleanupOutputFile()
    }

    func switchCamera() {
        Task { @MainActor in
            guard isConfigured else { return }
            currentCameraPosition = currentCameraPosition == .front ? .back : .front
            session.beginConfiguration()
            if let currentVideoInput {
                session.removeInput(currentVideoInput)
            }
            if !addVideoInput(position: currentCameraPosition) {
                currentCameraPosition = currentCameraPosition == .front ? .back : .front
                _ = addVideoInput(position: currentCameraPosition)
            }
            session.commitConfiguration()
            applyTorchIfNeeded()
        }
    }

    func toggleTorch() {
        Task { @MainActor in
            isTorchEnabled.toggle()
            applyTorchIfNeeded()
        }
    }

    private func finishPendingStopIfNeeded() {
        guard let pendingStopCompletion else { return }
        self.pendingStopCompletion = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.stop(completion: pendingStopCompletion)
        }
    }

    private func cleanupOutputFile() {
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        guard error == nil,
              let data = try? Data(contentsOf: outputFileURL),
              !data.isEmpty else {
            DispatchQueue.main.async {
                self.cleanupOutputFile()
                self.completion?(nil)
                self.completion = nil
            }
            return
        }
        try? FileManager.default.removeItem(at: outputFileURL)
        DispatchQueue.main.async {
            self.outputURL = nil
            self.completion?(
                AloLocalAttachment(
                    data: data,
                    mime: "video/quicktime",
                    type: "circle",
                    name: "circle-\(Int(Date().timeIntervalSince1970)).mov"
                )
            )
            self.completion = nil
        }
    }

    @MainActor
    private func configureIfNeeded() async -> Bool {
        if isConfigured { return true }
        if isConfiguring { return false }
        isConfiguring = true
        defer { isConfiguring = false }

        let cameraGranted = await requestAccess(for: .video)
        guard cameraGranted else { return false }
        let microphoneGranted = await requestAccess(for: .audio)

        session.beginConfiguration()
        session.sessionPreset = .medium

        currentCameraPosition = .front
        if !addVideoInput(position: currentCameraPosition) {
            session.commitConfiguration()
            return false
        }

        if microphoneGranted,
           let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        session.commitConfiguration()
        isConfigured = true
        return true
    }

    @MainActor
    private func addVideoInput(position: AVCaptureDevice.Position) -> Bool {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let videoInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(videoInput) else {
            return false
        }
        session.addInput(videoInput)
        currentVideoInput = videoInput
        return true
    }

    @MainActor
    private func applyTorchIfNeeded() {
        guard let device = currentVideoInput?.device,
              device.hasTorch else {
            isTorchEnabled = false
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = isTorchEnabled ? .on : .off
            device.unlockForConfiguration()
        } catch {
            isTorchEnabled = false
        }
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }
}

private struct CircleCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

private struct CircleVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = .resizeAspectFill
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
            layer.masksToBounds = true
        }
    }
}

private extension Notification.Name {
    static let aloVoicePlaybackDidStart = Notification.Name("aloVoicePlaybackDidStart")
    static let aloVoicePlaybackDidStop = Notification.Name("aloVoicePlaybackDidStop")
    static let aloVoicePlaybackToggleRequested = Notification.Name("aloVoicePlaybackToggleRequested")
    static let aloVoicePlaybackStopRequested = Notification.Name("aloVoicePlaybackStopRequested")
    static let aloVoicePlaybackSpeedChanged = Notification.Name("aloVoicePlaybackSpeedChanged")
}

private enum AloHaptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

private extension AloLocalAttachment {
    var isLocalVoiceLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "audio" ||
            normalizedType == "voice" ||
            normalizedName.hasPrefix("voice-") ||
            normalizedName.hasSuffix(".m4a") ||
            normalizedName.hasSuffix(".aac") ||
            normalizedName.hasSuffix(".mp3")
    }

    var isLocalCircleLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "circle" || normalizedName.hasPrefix("circle-")
    }

    var isRecordedDraft: Bool {
        isLocalVoiceLike || isLocalCircleLike
    }
}

private extension String {
    var hasImageExtension: Bool {
        hasSuffix(".jpg") || hasSuffix(".jpeg") || hasSuffix(".png") || hasSuffix(".webp") || hasSuffix(".gif") || hasSuffix(".avif")
    }

    var hasVideoExtension: Bool {
        hasSuffix(".mp4") || hasSuffix(".mov") || hasSuffix(".m4v") || hasSuffix(".webm")
    }
}

private extension AloMessageAttachment {
    var isVoiceLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedURL = url.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "audio" ||
            normalizedType == "voice" ||
            normalizedName.hasPrefix("voice-") ||
            normalizedURL.hasSuffix(".m4a") ||
            normalizedURL.hasSuffix(".aac") ||
            normalizedURL.hasSuffix(".mp3") ||
            normalizedURL.hasSuffix(".wav")
    }

    var isCircleLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "circle" ||
            normalizedName.hasPrefix("circle-") ||
            normalizedName.contains("video-note")
    }
}
