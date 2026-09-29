import SwiftUI

/// What the window's transcript offers on each message; the palette's transcript passes none.
struct ChatMessageActions {
    let modelGroups: [AIModelOptionGroup]
    /// A reply still arriving: nothing may cut or re-ask the chat under it.
    let isBusy: Bool
    /// A temporary chat is never written down, so nothing is branched off it either.
    let canBranch: Bool
    let speakingID: UUID?
    let editingID: UUID?
    let edit: (UUID) -> Void
    /// Nil asks the chat's own model again.
    let retry: (UUID, AIModelOption?) -> Void
    let branch: (UUID) -> Void
    let speak: (ChatMessage) -> Void
    private let modelsKey: Int

    init(
        modelGroups: [AIModelOptionGroup], isBusy: Bool, canBranch: Bool, speakingID: UUID?,
        editingID: UUID?, edit: @escaping (UUID) -> Void,
        retry: @escaping (UUID, AIModelOption?) -> Void, branch: @escaping (UUID) -> Void,
        speak: @escaping (ChatMessage) -> Void
    ) {
        self.modelGroups = modelGroups
        self.isBusy = isBusy
        self.canBranch = canBranch
        self.speakingID = speakingID
        self.editingID = editingID
        self.edit = edit
        self.retry = retry
        self.branch = branch
        self.speak = speak
        modelsKey = modelGroups.flatMap { $0.options.map(\.title) }.hashValue
    }

    /// The per-message facts a row draws from; the closures never change what it shows.
    struct State: Equatable {
        var isBusy: Bool
        var canBranch: Bool
        var isSpeaking: Bool
        var isDimmed: Bool
        var models: Int
    }

    /// From the edited question on, the transcript is what sending the edit will replace.
    func dimmedIDs(in messages: [ChatMessage]) -> Set<UUID> {
        guard let editingID, let start = messages.firstIndex(where: { $0.id == editingID })
        else { return [] }
        return Set(messages[start...].map(\.id))
    }

    func state(for message: ChatMessage, dimmed: Set<UUID>) -> State {
        State(
            isBusy: isBusy, canBranch: canBranch, isSpeaking: speakingID == message.id,
            isDimmed: dimmed.contains(message.id), models: modelsKey)
    }
}

/// The hover row under a message in the window: every action the message's menu also carries.
struct ChatMessageActionRow: View {
    @Environment(\.metrics) private var metrics
    let message: ChatMessage
    /// What Copy puts on the pasteboard: the drawn text, without the choices fence.
    let text: String
    let actions: ChatMessageActions
    let state: ChatMessageActions.State

    var body: some View {
        HStack(spacing: metrics.spacing.sm) {
            if message.role == .user {
                timestamp
                if !state.isBusy {
                    icon("pencil", "Edit Message") { actions.edit(message.id) }
                }
                ChatCopyButton(text: text)
                branchButton
            } else {
                ChatCopyButton(text: text, subject: "Reply")
                if !state.isBusy {
                    icon("arrow.clockwise", "Regenerate Response") { actions.retry(message.id, nil) }
                    ChatRetryMenu(groups: actions.modelGroups) { actions.retry(message.id, $0) }
                }
                branchButton
                icon(
                    state.isSpeaking ? "stop.fill" : "speaker.wave.2",
                    state.isSpeaking ? "Stop Speaking" : "Speak Reply"
                ) { actions.speak(message) }
                if let usage = ChatUsageLabel.text(message.usage) {
                    Text(usage)
                        .font(metrics.typography.keyCap)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                timestamp
            }
        }
    }

    @ViewBuilder private var branchButton: some View {
        if !state.isBusy, state.canBranch {
            icon("arrow.triangle.branch", "Branch from Here") { actions.branch(message.id) }
        }
    }

    private var timestamp: some View {
        Text(message.sentAt.formatted(date: .omitted, time: .shortened))
            .font(metrics.typography.keyCap)
            .foregroundStyle(Theme.Colors.textTertiary)
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: metrics.size.chatMessageAction, height: metrics.size.chatMessageAction)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Every model the chat could switch to, grouped by where it runs; picking one re-asks with it.
private struct ChatRetryMenu: View {
    @Environment(\.metrics) private var metrics
    let groups: [AIModelOptionGroup]
    let retry: (AIModelOption) -> Void

    var body: some View {
        Menu {
            ChatRetryModels(groups: groups, retry: retry)
        } label: {
            Image(systemName: "chevron.down")
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: metrics.size.chatMessageAction, height: metrics.size.chatMessageAction)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(groups.isEmpty)
        .help("Retry with Another Model")
        .accessibilityLabel("Retry with Another Model")
    }
}

private struct ChatRetryModels: View {
    let groups: [AIModelOptionGroup]
    let retry: (AIModelOption) -> Void

    var body: some View {
        ForEach(groups) { group in
            Section(group.title) {
                ForEach(group.options) { option in
                    Button(option.title) { retry(option) }
                }
            }
        }
    }
}

/// The same actions as the hover row, for a right-click and for VoiceOver's actions rotor.
struct ChatMessageMenu: ViewModifier {
    let message: ChatMessage
    let text: String
    let actions: ChatMessageActions?
    let state: ChatMessageActions.State?

    func body(content: Content) -> some View {
        if let actions, let state, message.state != .streaming {
            content
                .contextMenu { menu(actions, state) }
                .accessibilityAction(named: "Copy") { Paster.copyPlainText(text) }
                .accessibilityAction(named: message.role == .user ? "Edit" : "Regenerate") {
                    guard !state.isBusy else { return }
                    if message.role == .user {
                        actions.edit(message.id)
                    } else {
                        actions.retry(message.id, nil)
                    }
                }
        } else {
            content
        }
    }

    @ViewBuilder private func menu(
        _ actions: ChatMessageActions, _ state: ChatMessageActions.State
    ) -> some View {
        if message.role == .user, !state.isBusy {
            Button("Edit Message", systemImage: "pencil") { actions.edit(message.id) }
        }
        Button("Copy", systemImage: "doc.on.doc") { Paster.copyPlainText(text) }
        if message.role == .assistant {
            if !state.isBusy {
                Button("Regenerate", systemImage: "arrow.clockwise") { actions.retry(message.id, nil) }
                Menu("Retry With") {
                    ChatRetryModels(groups: actions.modelGroups) { actions.retry(message.id, $0) }
                }
            }
            Button(
                state.isSpeaking ? "Stop Speaking" : "Speak",
                systemImage: state.isSpeaking ? "stop.fill" : "speaker.wave.2"
            ) { actions.speak(message) }
        }
        if !state.isBusy, state.canBranch {
            Divider()
            Button("Branch from Here", systemImage: "arrow.triangle.branch") {
                actions.branch(message.id)
            }
        }
    }
}

/// A reply's own cost line; nothing when its route reported no counts.
enum ChatUsageLabel {
    static func text(_ usage: AIUsage?) -> String? {
        guard let usage, let total = usage.totalTokens else { return nil }
        let tokens = "\(total.formatted()) tokens"
        guard let cost = usage.costUSD else { return tokens }
        return tokens + " · " + cost.formatted(.currency(code: "USD").precision(.significantDigits(2)))
    }
}
