import Foundation

/// Compare Models: one question to several routes side by side, or one reply re-asked inline.
extension AIChatCoordinator {
    var comparison: ModelComparisonState? { chats.comparison }

    /// Opens the window in its comparison mode, seeded with the chat's own model.
    func showComparison() {
        guard isEnabled else { return }
        if chats.comparison == nil {
            let seed = model(for: chats.window).map { [$0] } ?? []
            chats.comparison = ModelComparisonState(picks: seed)
        }
        showWindow()
    }

    func toggleComparison() {
        if chats.comparison == nil {
            showComparison()
        } else {
            closeComparison()
        }
    }

    /// Leaving is stopping: nothing a closed comparison streams is kept anywhere.
    func closeComparison() {
        chats.comparison?.cancel()
        chats.comparison = nil
    }

    /// Only what every pick can read may be attached, since each is sent the same turn.
    func capabilities(of state: ModelComparisonState) -> AIModelCapabilities {
        ModelComparison.common(state.picks.map { capabilities(of: $0) })
    }

    func togglePick(_ option: AIModelOption, in state: ModelComparisonState) {
        guard !state.isStreaming else { return }
        let before = state.picks.count
        state.togglePick(withDefaultEffort(option.selection))
        if state.picks.count == before {
            report("Compare up to \(ModelComparison.modelLimit.upperBound) models at a time.")
        }
    }

    func canCompare(_ state: ModelComparisonState) -> Bool {
        let hasInput = !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !state.pendingAttachments.isEmpty
        return hasInput && !state.isStreaming && ModelComparison.canCompare(state.picks)
    }

    /// Return and the button are one action: Compare, or Stop All while any column streams.
    func submitComparison(_ state: ModelComparisonState) {
        if state.isStreaming {
            state.cancel()
            return
        }
        guard isEnabled, canCompare(state) else { return }
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let question = ModelComparison.question(
            text, images: state.pendingAttachments.compactMap(\.image),
            documents: state.pendingAttachments.compactMap(\.document), now: now)
        let comparison = ModelComparison(context: question, models: state.picks, now: now)
        state.begin(comparison)
        state.draft = ""
        for column in comparison.columns { run(column, of: comparison, in: state) }
    }

    func retry(_ columnID: UUID, in state: ModelComparisonState) {
        guard isEnabled, state.retry(columnID), let comparison = state.comparison,
            let column = comparison.column(columnID)
        else { return }
        run(column, of: comparison, in: state)
    }

    func copy(_ columnID: UUID, in state: ModelComparisonState) {
        guard let reply = state.comparison?.column(columnID)?.reply, !reply.text.isEmpty else { return }
        Paster.copyPlainText(ChatChoices.split(reply.text).text)
        report("Reply copied", tone: .success)
    }

    /// The pick: question and answer saved as an ordinary chat with that model, then opened.
    func continueAsChat(_ columnID: UUID, in state: ModelComparisonState) {
        guard let comparison = state.comparison, let column = comparison.column(columnID) else {
            return
        }
        guard let session = comparison.session(continuing: columnID, now: Date()) else {
            report(
                column.isStreaming
                    ? "That reply is still arriving." : "Only a finished reply can be continued.")
            return
        }
        if let anchor = state.anchor {
            guard chats.holder(of: anchor.chat)?.isTemporary != true else {
                report("A temporary chat is never saved, so nothing can continue from it.")
                return
            }
            let title = history.conversation(id: anchor.chat)?.displayTitle ?? session.title
            history.save(session)
            history.rename(id: session.id, to: "\(title) (\(modelTitle(of: column.model)))")
            closeInlineComparison()
        } else {
            history.save(session)
            closeComparison()
        }
        openChat(id: session.id)
    }

    /// Another chat takes the window, so neither comparison has anywhere left to show.
    func leaveComparisons() {
        closeComparison()
        closeInlineComparison()
    }

    func chooseFiles(for state: ModelComparisonState) {
        guard let files = chooseFiles() else { return }
        attach(files: files, to: state)
    }

    func attach(files: [URL], to state: ModelComparisonState) {
        attach(files: files, into: state, accepting: capabilities(of: state))
    }

    func attachPastedFile(files: [URL], to state: ModelComparisonState) -> Bool {
        attachPastedFile(files: files, into: state, accepting: capabilities(of: state))
    }

    func removeAttachment(_ id: UUID, in state: ModelComparisonState) {
        state.removeAttachment(id)
    }

    func modelTitle(of selection: AIModelSelection) -> String {
        modelTitle(of: selection, among: modelOptions)
    }

    // MARK: - Inline

    /// Compare With…: the reply's own question, asked of `option` with the chat so far.
    func compare(reply replyID: UUID, with option: AIModelOption, in chat: AIChatState) {
        guard isEnabled, !chat.isStreaming,
            let index = chat.session.messages.firstIndex(where: { $0.id == replyID }), index > 0,
            chat.session.messages[index].role == .assistant,
            let context = chat.session.branch(through: chat.session.messages[index - 1].id)
        else { return }
        chats.inlineComparison?.cancel()
        let selection = withDefaultEffort(option.selection)
        let state = ModelComparisonState(
            picks: [selection], anchor: (chat: chat.session.id, reply: replyID))
        let comparison = ModelComparison(context: context, models: [selection], now: Date())
        state.begin(comparison)
        chats.inlineComparison = state
        for column in comparison.columns { run(column, of: comparison, in: state) }
    }

    func closeInlineComparison() {
        chats.inlineComparison?.cancel()
        chats.inlineComparison = nil
    }

    /// A regenerated or edited-away reply takes its comparison with it, rather than streaming unseen.
    func dropStaleInlineComparison(in chat: AIChatState) {
        guard let anchor = chats.inlineComparison?.anchor, anchor.chat == chat.session.id,
            !chat.session.messages.contains(where: { $0.id == anchor.reply })
        else { return }
        closeInlineComparison()
    }

    /// The inline comparison belonging to `chat`, if the reply it re-asks is still there.
    func inlineComparison(in chat: AIChatState) -> ModelComparisonState? {
        guard let state = chats.inlineComparison, let anchor = state.anchor,
            anchor.chat == chat.session.id,
            chat.session.messages.contains(where: { $0.id == anchor.reply })
        else { return nil }
        return state
    }

    // MARK: - Private

    /// Tools stay off: a side-by-side answer is compared on what the model says, not what it ran.
    private func run(
        _ column: ModelComparison.Column, of comparison: ModelComparison,
        in state: ModelComparisonState
    ) {
        let model = column.model
        do {
            let provider = try provider(for: model)
            let request = AIRequest(
                instructions: AIInstructions.compose(
                    userPrompt: aiSettings.systemPrompt, isEnabled: aiSettings.systemPromptEnabled,
                    chatPrompt: comparison.context.instructions),
                messages: comparison.requestMessages(textBudget: contextBudget(of: model)),
                webSearch: aiSettings.webSearchEnabled && capabilities(of: model).webSearch)
            state.run(column.id, using: provider, request: request)
        } catch {
            state.fail(column.id, message: error.localizedDescription)
        }
    }
}
