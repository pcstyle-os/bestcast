import Foundation

/// The window's per-message actions: edit, retry, branch, speak, and the chat's own prompt.
extension AIChatCoordinator {
    func beginEdit(_ id: UUID, in chat: AIChatState) {
        chat.beginEditing(id)
    }

    func cancelEdit(in chat: AIChatState) {
        chat.cancelEditing()
    }

    /// The last question, the one ⌘K's Edit Last Message loads.
    func lastQuestion(in chat: AIChatState) -> UUID? {
        chat.session.messages.last { $0.role == .user }?.id
    }

    /// A picked model becomes the chat's, as the picker makes it, before the question goes again.
    func retry(reply id: UUID?, with option: AIModelOption?, in chat: AIChatState) {
        guard !chat.isStreaming else { return }
        if let option { selectModel(option, in: chat) }
        regenerate(in: chat, reply: id)
    }

    /// Saved at once, then opened: a branch is an ordinary chat from its first moment.
    func branch(from messageID: UUID, in chat: AIChatState) {
        guard !chat.isTemporary, let branch = chat.session.branch(through: messageID) else { return }
        let title = title(of: chat)
        history.save(branch)
        history.rename(id: branch.id, to: "\(title) (branch)")
        openChat(id: branch.id)
    }

    func newTemporaryChat() {
        chats.newWindowChat(temporary: true)
    }

    func setInstructions(_ text: String, in chat: AIChatState) {
        chat.setInstructions(text)
    }

    func speak(_ message: ChatMessage) {
        speaker.toggle(message.id, text: message.text)
    }

    /// Built per render; a streaming chat offers nothing that would cut it, so it skips the models.
    func messageActions(for chat: AIChatState) -> ChatMessageActions {
        ChatMessageActions(
            modelGroups: chat.isStreaming ? [] : modelGroups, isBusy: chat.isStreaming,
            canBranch: !chat.isTemporary, speakingID: speaker.speakingID,
            editingID: chat.editingMessageID,
            edit: { [weak self, weak chat] id in
                guard let self, let chat else { return }
                beginEdit(id, in: chat)
            },
            retry: { [weak self, weak chat] id, option in
                guard let self, let chat else { return }
                retry(reply: id, with: option, in: chat)
            },
            branch: { [weak self, weak chat] id in
                guard let self, let chat else { return }
                branch(from: id, in: chat)
            },
            speak: { [weak self] message in self?.speak(message) })
    }
}
