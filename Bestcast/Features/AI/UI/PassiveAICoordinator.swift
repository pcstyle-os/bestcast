import AppKit
import NaturalLanguage
import Observation

/// Root search's streamed answer; only its row reads the text, so a token re-renders one view.
@MainActor
@Observable
final class PassiveAnswer {
    enum Phase: Equatable {
        case thinking
        case streaming
        case done
        case failed
    }

    let query: String
    let model: AIModelSelection
    fileprivate(set) var text = ""
    fileprivate(set) var phase = Phase.thinking

    init(query: String, model: AIModelSelection) {
        self.query = query
        self.model = model
    }
}

/// One row of root search's Selected Text section.
enum PassiveSelectionItem: Equatable, Identifiable {
    case action(PassiveSelectionAction)
    case ask

    var id: String {
        switch self {
        case .action(let action): return "passive-selection-" + action.rawValue
        case .ask: return "passive-selection-ask"
        }
    }

    var title: String {
        switch self {
        case .action(let action): return action.title
        case .ask: return "Ask AI about Selection"
        }
    }

    var systemImage: String {
        switch self {
        case .action(.explain): return "questionmark.bubble"
        case .action(.findBugs): return "ladybug"
        case .action(.translate): return "translate"
        case .action(.summarize): return "text.line.3.summary"
        case .action(.improveWriting): return "textformat"
        case .action(.rewrite): return "wand.and.sparkles"
        case .ask: return "sparkles"
        }
    }
}

/// What the previous app had selected when root search opened, with the actions it suggests.
struct PassiveSelection: Equatable {
    let text: String
    let kind: PassiveContentKind
    let items: [PassiveSelectionItem]
}

/// AI that helps unasked: root search's inline answer, selection suggestions, clip summaries.
@MainActor
@Observable
final class PassiveAICoordinator {
    private(set) var answer: PassiveAnswer?
    private(set) var selection: PassiveSelection?

    @ObservationIgnored private var schedule = PassiveInlineSchedule()
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private unowned let core: AppCore

    init(core: AppCore) {
        self.core = core
    }

    private var settings: PassiveAISettingsStore { core.aiSettings.passive }

    /// Nil when nothing may run: AI off, or no on-device model and no picked route.
    private var answerModel: AIModelSelection? {
        guard core.settings.aiEnabled, settings.inlineAnswers else { return nil }
        guard let model = settings.model, !model.isOnDevice else {
            return AppleIntelligenceProvider.status().isAvailable ? .appleIntelligence : nil
        }
        return model
    }

    /// On this Mac only, whatever route answers in root search: a clip is never sent unasked.
    var canSummarizeOnDevice: Bool {
        core.settings.aiEnabled && settings.clipboardIntelligence
            && AppleIntelligenceProvider.status().isAvailable
    }

    // MARK: - Inline answer

    /// Re-run on every query, mode and visibility change; each keystroke retires the last answer.
    func paletteChanged() {
        let palette = core.palette
        guard palette.isVisible else { return reset() }
        if !palette.query.isEmpty { selection = nil }
        guard palette.mode == .launcher else {
            schedule.reset()
            retireAnswer()
            return
        }
        switch schedule.noteQuery(palette.query, eligible: offersAnswer(for: palette.query)) {
        case .keep: return
        case .clear: retireAnswer()
        case .schedule(let query, let generation):
            retireAnswer()
            answerTask = Task { [weak self] in await self?.answer(query, generation: generation) }
        }
    }

    func reset() {
        schedule.reset()
        retireAnswer()
        selectionTask?.cancel()
        selectionTask = nil
        selection = nil
    }

    private func retireAnswer() {
        answerTask?.cancel()
        answerTask = nil
        if answer != nil { answer = nil }
    }

    private func offersAnswer(for query: String) -> Bool {
        guard answerModel != nil, core.palette.argumentEntryID == nil else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The cheap test first, so an ordinary search never pays for the calculator or the index.
        guard PassiveAIHeuristics.isQuestionOrInstruction(trimmed) else { return false }
        return PassiveAIHeuristics.shouldOfferInlineAnswer(
            query: trimmed, isCalculatorAnswer: answersElsewhere(query),
            exactlyMatchesEntry: exactlyMatchesEntry(trimmed))
    }

    /// The calculator, a colour or a web address already owns the lead row for this query.
    private func answersElsewhere(_ query: String) -> Bool {
        CalcMemo.evaluate(query, rates: core.currencyRates.rates, format: core.calcNumberFormat) != nil
            || ColorValue.parse(query) != nil || CommandCatalog.openInBrowser(for: query) != nil
    }

    private func exactlyMatchesEntry(_ query: String) -> Bool {
        let results = core.appIndex.orderedResults(
            query: core.palette.query, visibility: core.visibility, favorites: core.favorites,
            hotKeys: core.hotKeys)
        return results.entries.prefix(5).contains {
            $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func answer(_ query: String, generation: Int) async {
        do { try await Task.sleep(for: PassiveInlineSchedule.delay) } catch { return }
        guard schedule.isCurrent(generation), let model = answerModel,
            let provider = try? provider(for: model)
        else { return }
        let answer = PassiveAnswer(query: query, model: model)
        self.answer = answer
        publishLeadingRows(count: 1)
        let request = AIRequest(
            instructions: PassiveAIHeuristics.answerInstructions,
            messages: [AIMessage(role: .user, text: query)], maxOutputTokens: 160)
        do {
            for try await event in provider.stream(request) {
                guard !Task.isCancelled else { return }
                if case .text(let delta) = event {
                    answer.text += delta
                    answer.phase = .streaming
                }
                if case .finished = event { break }
            }
            guard !Task.isCancelled else { return }
            answer.text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            answer.phase = answer.text.isEmpty ? .failed : .done
        } catch {
            guard !Task.isCancelled else { return }
            answer.phase = .failed
        }
    }

    /// ↵ on the answer: the exchange becomes a saved chat, so Quick AI carries it on from there.
    func openAnswerInQuickAI() {
        guard let answer, core.settings.aiEnabled else { return }
        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard answer.phase == .done, !text.isEmpty else {
            return core.quickAICoordinator.ask(answer.query)
        }
        let session = ChatSession(
            messages: [
                ChatMessage(role: .user, text: answer.query),
                ChatMessage(role: .assistant, text: text)
            ], model: answer.model)
        core.chatHistory.save(session)
        guard core.aiChats.openInQuickAI(id: session.id) else {
            return core.quickAICoordinator.ask(answer.query)
        }
        core.paletteCoordinator.showPalette(mode: .ai)
    }

    func copyAnswer() -> Bool {
        guard let answer, answer.phase == .done, !answer.text.isEmpty else { return false }
        core.paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(answer.text)
        return true
    }

    // MARK: - Selected text

    /// Root search just opened: read the previous app's selection, never asking for access.
    func launcherShown() {
        selectionTask?.cancel()
        selection = nil
        guard core.settings.aiEnabled, settings.selectionSuggestions,
            core.settings.quickActionsEnabled, Permissions.isAccessibilityTrusted(),
            core.palette.query.isEmpty,
            let target = core.paletteCoordinator.targetApp,
            target.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return }
        let preferred = Locale.preferredLanguages
        selectionTask = Task { [weak self] in
            // A turn later, so the palette draws before a slow app answers the read.
            await Task.yield()
            guard let self, !Task.isCancelled, self.core.palette.isVisible,
                self.core.palette.query.isEmpty,
                let text = AccessibilityText.selection(in: target)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty, text.utf8.count <= QuickActionRunner.maxSelectionBytes
            else { return }
            let found = await Task.detached(priority: .userInitiated) {
                Self.describe(text, preferredLanguages: preferred)
            }.value
            guard !Task.isCancelled, self.core.palette.isVisible, self.core.palette.query.isEmpty
            else { return }
            self.selection = found
            self.publishLeadingRows(count: found.items.count)
        }
    }

    nonisolated private static func describe(
        _ text: String, preferredLanguages: [String]
    ) -> PassiveSelection {
        let kind = PassiveAIHeuristics.kind(of: text)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(PassiveAIHeuristics.detectionLimit)))
        let foreign = PassiveAIHeuristics.isForeign(
            dominantLanguage: recognizer.dominantLanguage?.rawValue,
            preferredLanguages: preferredLanguages)
        let actions = PassiveAIHeuristics.suggestions(for: text, kind: kind, isForeignLanguage: foreign)
        return PassiveSelection(
            text: text, kind: kind, items: actions.map(PassiveSelectionItem.action) + [.ask])
    }

    /// Rows landing above the highlight push it down, so ↵ still opens what it did a moment ago.
    private func publishLeadingRows(count: Int) {
        guard core.palette.mode == .launcher else { return }
        core.palette.selection += count
    }

    func run(_ item: PassiveSelectionItem) {
        guard let selection, core.settings.aiEnabled else { return }
        switch item {
        case .action(.explain):
            core.quickAICoordinator.ask(Self.prompt("Explain this", selection))
        case .action(.findBugs):
            core.quickAICoordinator.ask(Self.prompt("Find bugs in this", selection))
        case .action(.translate): core.quickActionCoordinator.run(.builtIn(.translate))
        case .action(.summarize): core.quickActionCoordinator.run(.builtIn(.summarize))
        case .action(.improveWriting): core.quickActionCoordinator.run(.builtIn(.fixGrammar))
        case .action(.rewrite): core.quickActionCoordinator.run(.builtIn(.rewrite))
        case .ask:
            core.aiChats.quickAI.startNewChat()
            core.paletteCoordinator.showPalette(mode: .ai, seeding: Self.quoted(selection.text))
        }
        self.selection = nil
    }

    private static func prompt(_ ask: String, _ selection: PassiveSelection) -> String {
        let label = selection.kind == .prose ? "text" : selection.kind.title.lowercased()
        return "\(ask) \(label):\n\n\(quoted(selection.text))"
    }

    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }.joined(separator: "\n") + "\n\n"
    }

    // MARK: - Summaries and titles

    /// Nil unless the on-device model answers: a background summary never leaves this Mac.
    func summarize(_ text: String) async -> String? {
        guard canSummarizeOnDevice else { return nil }
        let request = AIRequest(
            instructions: PassiveAIHeuristics.summaryInstructions,
            messages: [
                AIMessage(role: .user, text: String(text.prefix(PassiveAIHeuristics.summaryExcerpt)))
            ], maxOutputTokens: 40)
        let provider = AppleIntelligenceProvider(guardrails: .permissiveContentTransformations)
        guard let raw = await Self.collect(provider, request) else { return nil }
        return PassiveAIHeuristics.oneLine(raw)
    }

    /// A chat's title on the passive route, only when that route is this Mac's own model.
    func chatTitle(describing description: String) async -> String? {
        guard settings.isOnDevice, AppleIntelligenceProvider.status().isAvailable else { return nil }
        let request = AIRequest(
            instructions: ChatTitle.instructions,
            messages: [AIMessage(role: .user, text: description)])
        guard let raw = await Self.collect(AppleIntelligenceProvider(), request) else { return nil }
        return ChatTitle.sanitize(raw)
    }

    private static func collect(_ provider: any AIProvider, _ request: AIRequest) async -> String? {
        var text = ""
        do {
            for try await event in provider.stream(request) {
                if case .text(let delta) = event { text += delta }
                if case .finished = event { break }
            }
        } catch {
            return nil
        }
        return Task.isCancelled ? nil : text
    }

    private func provider(for model: AIModelSelection) throws -> any AIProvider {
        guard !model.isOnDevice else { return AppleIntelligenceProvider() }
        return try AIProviderFactory.make(
            selection: model, settings: core.aiSettings, subscription: core.chatGPTSubscription,
            installedAI: core.installedAI)
    }
}
