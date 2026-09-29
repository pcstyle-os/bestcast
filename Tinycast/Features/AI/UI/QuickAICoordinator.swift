import AppKit

/// The palette's AI screen: summoning, the open policy, and handing a chat on to the window.
@MainActor
final class QuickAICoordinator {
    private let chats: AIChatSurfacesState
    private let settings: AppSettings
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private unowned let core: AppCore
    /// The question ↑ took back into the composer; sending it replaces that exchange.
    private var editingMessageID: UUID?

    init(
        chats: AIChatSurfacesState, settings: AppSettings, palette: PaletteState,
        paletteCoordinator: PaletteCoordinator, core: AppCore
    ) {
        self.chats = chats
        self.settings = settings
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    private var chat: AIChatState { chats.quickAI }
    private var chatCoordinator: AIChatCoordinator { core.aiChatCoordinator }

    func show() {
        guard settings.aiEnabled else { return }
        // Not `togglePalette`: the open policy decides a chat only on the way in.
        guard !paletteCoordinator.isShowing(.ai) else {
            paletteCoordinator.hidePalette()
            return
        }
        applyOpenPolicy()
        paletteCoordinator.showPalette(mode: .ai)
    }

    /// ⇥ and the AI fallback: a fresh chat that carries the question, already asked.
    func ask(_ prompt: String) {
        guard settings.aiEnabled else { return }
        // No question is no reason to skip the open policy: this is a summon, not an ask.
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            show()
            return
        }
        chat.startNewChat()
        editingMessageID = nil
        paletteCoordinator.showPalette(mode: .ai)
        send(prompt)
    }

    /// A preset opens its own fresh chat, so its prompt never rewrites a conversation under way.
    func startPreset(id: UUID) {
        guard settings.aiEnabled, core.aiSettings.preset(id: id) != nil else { return }
        chat.startNewChat()
        editingMessageID = nil
        applyPreset(id: id)
        paletteCoordinator.showPalette(mode: .ai)
    }

    /// Picked from the model menu or ⌘K: the chat on screen takes the preset from its next turn.
    func applyPreset(id: UUID) {
        guard let preset = core.aiSettings.preset(id: id) else { return }
        chat.preset = preset
        if let model = preset.model { chat.setModel(model) }
    }

    var activePresetID: UUID? { chat.preset?.id }

    var presets: [QuickAIPreset] { core.aiSettings.quickAIPresets }

    func savePreset(_ preset: QuickAIPreset) {
        var presets = core.aiSettings.quickAIPresets
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        core.aiSettings.quickAIPresets = presets
        if chat.preset?.id == preset.id { chat.preset = preset }
    }

    /// Its launcher row goes too, so nothing keyed by that row outlives it.
    func deletePreset(id: UUID) {
        core.aiSettings.quickAIPresets.removeAll { $0.id == id }
        if chat.preset?.id == id { chat.preset = nil }
        let action = HotKeyAction.aiPreset(id: id)
        if core.hotKeys.recordingAction == action { core.hotKeys.recordingAction = nil }
        core.hotKeys.setBinding(nil, for: action)
        let entryID = QuickAIPreset.entryID(for: id)
        core.favorites.remove(keys: [entryID])
        core.visibility.removeItemKeys([entryID])
        core.aliases.removeKeys([entryID])
        core.launcherRanking.reset(itemKey: entryID)
    }

    /// Launcher rows follow the presets and the AI switch, like every other gated command.
    func applyPresetsPresence() {
        core.appIndex.setQuickAIPresets(settings.aiEnabled ? core.aiSettings.quickAIPresets : [])
    }

    /// Off leaves the screen too, so the palette never shows a feature that is gone.
    func leave() {
        if palette.mode == .ai || palette.mode == .aiHistory { palette.prepare(mode: .launcher) }
    }

    /// A file pasted at the launcher belongs in Quick AI, never in a search for its name.
    func attachPastedFileFromLauncher(files: [URL]) -> Bool {
        guard settings.aiEnabled, !files.isEmpty else { return false }
        show()
        return attachPastedFile(files: files)
    }

    func attachPastedFile(files: [URL]) -> Bool {
        chatCoordinator.attachPastedFile(files: files, to: chat)
    }

    /// The one place deciding whether summoning resumes; Pop to Root only forgets the screen.
    private func applyOpenPolicy() {
        // A reply still arriving was asked for; resetting would discard the answer.
        guard !chat.isStreaming else { return }
        let recent = core.chatHistory.conversations.first
        let hasTranscript = !chat.session.messages.isEmpty
        // Staged files are unsent work: neither branch may throw them away on a plain re-summon.
        let hasStaging = !chat.pendingAttachments.isEmpty
        // From history when nothing is resident, so the verdict still holds after a relaunch.
        let lastActiveAt = hasTranscript ? chat.session.updatedAt : recent?.updatedAt
        let decision = AIConversationOpenPolicy.decide(
            opensTo: core.aiSettings.opensTo, newAfter: core.aiSettings.newChatAfter,
            lastActiveAt: lastActiveAt, now: Date())
        switch decision {
        case .resume:
            guard !hasTranscript, !hasStaging, let recent else { return }
            // The window may have it open, in which case this summon starts fresh instead.
            chats.openInQuickAI(id: recent.id)
        case .startNew:
            // An empty chat is already new; resetting it would only drop what is staged in it.
            guard hasTranscript else { return }
            chat.startNewChat()
        }
    }

    @discardableResult
    func send(_ input: String) -> Bool {
        let lastQuestion = chat.session.messages.last { $0.role == .user }?.id
        let replacing = editingMessageID != nil && editingMessageID == lastQuestion
        let sent = chatCoordinator.send(input, in: chat, replacingLastExchange: replacing)
        if sent { editingMessageID = nil }
        return sent
    }

    func startNewChat() {
        chat.startNewChat()
        editingMessageID = nil
        // A fresh conversation, not a fresh root: whatever opened chat is still behind it.
        palette.replace(mode: .ai)
    }

    func showHistory() {
        palette.push(mode: .aiHistory)
    }

    /// A chat the window holds opens there, since two writers would each save over the other.
    func openChat(id: UUID) {
        editingMessageID = nil
        guard chats.openInQuickAI(id: id) else {
            continueInChat(id: id)
            return
        }
        // History is left behind rather than stacked under, so one back step leaves chat for good.
        _ = palette.pop()
        palette.replace(mode: .ai)
    }

    /// Chat History's ⌘J: a saved chat opens in the window, taken over from Quick AI if it is there.
    func continueInChat(id: UUID) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        chatCoordinator.openChat(id: id)
        chatCoordinator.showWindow()
    }

    func deleteChat(id: UUID) {
        chats.delete(id: id)
    }

    func deleteAllChats() async {
        await chatCoordinator.deleteAllChats()
    }

    /// The window takes the conversation over; the palette closes behind it, as Settings' does.
    func continueInChat() {
        let draft = palette.query
        palette.query = ""
        paletteCoordinator.hidePalette(restoreFocus: false)
        chatCoordinator.continueInWindow(draft: draft)
    }

    func stopResponse() {
        chatCoordinator.stopResponse(in: chat)
    }

    func regenerate() {
        chatCoordinator.regenerate(in: chat)
    }

    func copyLastResponse() {
        chatCoordinator.copyLastResponse(in: chat)
    }

    /// Backspace on an empty composer takes the last staged image before it backs out of chat.
    func removeLastAttachment() -> Bool {
        chat.removeLastAttachment()
    }

    func clearAttachments() {
        chat.clearAttachments()
    }

    func removeAttachment(_ id: UUID) {
        chat.removeAttachment(id)
    }

    // MARK: - Replies and context

    /// ↑ on an empty composer: the last question comes back, with what it carried, to be re-sent.
    func editLastMessage() -> Bool {
        guard !chat.isStreaming, chat.pendingAttachments.isEmpty,
            let question = chat.session.messages.last(where: { $0.role == .user })
        else { return false }
        chat.clearAttachments()
        // No preview: the chip would decode the full-size image on every header render.
        for image in question.images {
            chat.attach(ChatAttachment(payload: .image(image), name: "Image", preview: nil))
        }
        for document in question.documents {
            chat.attach(
                ChatAttachment(payload: .document(document), name: document.name, preview: nil))
        }
        palette.query = question.text
        editingMessageID = question.id
        return true
    }

    /// The last finished reply's follow-ups, as many as Quick AI shows.
    var followUps: [String] {
        guard !chat.isStreaming, let reply = chat.session.messages.last,
            reply.role == .assistant, reply.state == .complete
        else { return [] }
        return Array(ChatChoices.split(reply.text).choices.prefix(QuickAIInstructions.maxFollowUps))
    }

    var lastCodeBlock: String? {
        chat.lastAssistantText.flatMap(QuickAIInstructions.lastCodeBlock(in:))
    }

    var hasFinishedReply: Bool { !chat.isStreaming && chat.lastAssistantText != nil }

    func copyCodeBlock() {
        guard let code = lastCodeBlock else { return }
        Paster.copyPlainText(code)
        core.showMessage("Code block copied")
    }

    /// ⌘↵ on an empty composer: the reply goes where the user was typing, as a Quick Action's does.
    func pasteLastResponse() -> Bool {
        guard hasFinishedReply, let text = chat.lastAssistantText else { return false }
        let reply = ChatChoices.split(text).text
        guard targetAppName != nil, let target = paletteCoordinator.targetApp else {
            Paster.copyPlainText(reply)
            core.showMessage("No app to paste into — reply copied")
            return true
        }
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.textInjector.replaceSelection(
            with: reply, in: target,
            onFailed: { [weak self] in
                Paster.copyPlainText(reply)
                self?.core.showMessage(
                    "Quick AI couldn't paste the reply — copied instead", tone: .danger)
            })
        return true
    }

    var targetAppName: String? {
        guard let target = paletteCoordinator.targetApp,
            target.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }
        return target.localizedName
    }

    /// ⇧⌘S: read now, from the app the palette covered; nothing leaves until the user sends.
    func attachSelection() {
        let target = paletteCoordinator.targetApp
        let generation = chat.stagingGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await QuickActionRunner.selection(
                    in: target, using: core.textInjector)
                reshowIfHidden()
                guard chat.stagingGeneration == generation else { return }
                let name = "Selection from \(target?.localizedName ?? "App").txt"
                let document = AIDocument(data: Data(text.utf8), mimeType: "text/plain", name: name)
                let attachment = ChatAttachment(payload: .document(document), name: name, preview: nil)
                if let refusal = chat.attach(attachment) {
                    core.showMessage(refusal.message, tone: .neutral)
                }
            } catch let failure as QuickActionFailure {
                reshowIfHidden()
                await reportSelectionRefusal(failure)
            } catch {
                reshowIfHidden()
                core.showMessage(error.localizedDescription, tone: .danger)
            }
        }
    }

    /// The ⌘C fallback brings the target forward, which takes the palette down with it.
    private func reshowIfHidden() {
        guard !paletteCoordinator.isShowing(.ai) else { return }
        paletteCoordinator.showPalette(mode: .ai)
    }

    private func reportSelectionRefusal(_ failure: QuickActionFailure) async {
        guard failure.opensAccessibilitySettings else {
            core.showMessage(failure.localizedDescription, tone: .danger)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        guard
            await core.reportFailure(
                title: "Quick AI can't read your selection",
                message:
                    "Tinycast needs the Accessibility permission to read the text you have "
                    + "selected. If Tinycast is already listed, switch it off and on again.",
                symbol: "sparkles", recovery: "Open System Settings")
        else { return }
        Permissions.openAccessibilitySettings()
    }

    /// Checked, never requested: a capture from the background must not raise the system prompt.
    func attachScreenshot() {
        guard let target = paletteCoordinator.targetApp, let appName = targetAppName else {
            core.showMessage("No app window to capture", tone: .danger)
            return
        }
        guard chatCoordinator.capabilities(for: chat).images else {
            core.showMessage(ChatAttachmentRefusal.imagesUnsupported.message, tone: .neutral)
            return
        }
        guard Permissions.isScreenRecordingTrusted() else {
            core.showMessage("Screen Recording is off for Tinycast", tone: .danger)
            Task { await reportScreenRecordingRefusal() }
            return
        }
        let pid = target.processIdentifier
        let generation = chat.stagingGeneration
        Task { [weak self] in
            let outcome = await Task.detached { () -> ChatAttachmentReader.Outcome? in
                guard let png = try? await WindowCaptureService.captureFrontWindow(of: pid) else {
                    return nil
                }
                return ChatAttachmentReader.image(png)
            }.value
            guard let self, chat.stagingGeneration == generation else { return }
            switch outcome {
            case .staged(let staged)?:
                let attachment = ChatAttachment(
                    payload: staged.payload, name: "Screenshot of \(appName)",
                    preview: staged.preview)
                if let refusal = chat.attach(attachment) {
                    core.showMessage(refusal.message, tone: .neutral)
                }
            case .failed(let refusal)?:
                core.showMessage(refusal.message, tone: .neutral)
            case nil:
                core.showMessage("Couldn't capture \(appName)'s window", tone: .danger)
            }
        }
    }

    private func reportScreenRecordingRefusal() async {
        NSApp.activate(ignoringOtherApps: true)
        guard
            await core.reportFailure(
                title: "Quick AI can't capture that window",
                message:
                    "Tinycast needs the Screen Recording permission to attach a screenshot. "
                    + "Turn it on for Tinycast in System Settings, then try again.",
                symbol: "camera.viewfinder", recovery: "Open System Settings")
        else { return }
        Permissions.openScreenRecordingSettings()
    }
}
