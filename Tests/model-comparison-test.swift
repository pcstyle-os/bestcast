import Foundation

// Guards ModelComparison: picks, per-column streaming, latency, cancel, retry and continuing.

@main
@MainActor
struct ModelComparisonTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static let start = Date(timeIntervalSinceReferenceDate: 1_000)
    static let gpt = AIModelSelection.codex(model: "gpt-5", effort: "medium")
    static let claude = AIModelSelection.claude(model: "opus", effort: nil)
    static let local = AIModelSelection.appleIntelligence
    static let grok = AIModelSelection.grok(model: "grok-4", effort: nil)
    static let cursor = AIModelSelection.cursor(model: "auto", effort: nil)

    static func main() {
        picksStayWithinTheLimit()
        everyColumnStreamsOnItsOwn()
        latencyIsMeasuredFromTheInjectedClock()
        cancelEndsEveryColumnAndLateEventsAreDropped()
        failureKeepsWhatArrived()
        retryResetsOnlyItsColumn()
        focusStaysOnAColumn()
        continuingMakesAChatWithFreshIDs()
        attachmentsFollowTheWeakestModel()
        requestsCarryTheWholeContext()
        print("model-comparison-test: \(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func comparison(_ models: [AIModelSelection]) -> ModelComparison {
        ModelComparison(
            context: ModelComparison.question("Which is faster?", now: start), models: models,
            now: start)
    }

    static func picksStayWithinTheLimit() {
        var picks: [AIModelSelection] = []
        picks = ModelComparison.toggling(gpt, in: picks)
        expect(!ModelComparison.canCompare(picks), "one pick is not a comparison")
        for model in [claude, local, grok] { picks = ModelComparison.toggling(model, in: picks) }
        expect(picks == [gpt, claude, local, grok], "picks keep their order")
        expect(ModelComparison.canCompare(picks), "four picks compare")
        picks = ModelComparison.toggling(cursor, in: picks)
        expect(picks.count == 4, "a fifth pick is refused")
        picks = ModelComparison.toggling(.codex(model: "gpt-5", effort: "high"), in: picks)
        expect(picks == [claude, local, grok], "another effort of a picked route unpicks it")
        expect(ModelComparison.isPicked(.claude(model: "opus", effort: "max"), in: picks),
            "a pick is matched by route and model")
    }

    static func everyColumnStreamsOnItsOwn() {
        var state = comparison([gpt, claude])
        let (first, second) = (state.columns[0].id, state.columns[1].id)
        expect(state.isStreaming, "a new comparison is streaming")
        state.apply(.text("Hel"), to: first, at: start + 1)
        state.apply(.text("Yes"), to: second, at: start + 2)
        state.apply(.text("lo"), to: first, at: start + 3)
        state.apply(.usage(AIUsage(inputTokens: 10, outputTokens: 5, costUSD: 0.01)), to: first,
            at: start + 3)
        state.apply(.finished, to: first, at: start + 4)
        expect(state.columns[0].reply.text == "Hello", "text lands in its own column")
        expect(state.columns[1].reply.text == "Yes", "the other column keeps its own text")
        expect(state.columns[0].reply.state == .complete, "finished completes the column")
        expect(state.columns[0].reply.usage?.totalTokens == 15, "usage is kept per column")
        expect(state.isStreaming, "one column still streaming keeps the comparison live")
        state.apply(.finished, to: second, at: start + 5)
        expect(!state.isStreaming, "every column finished ends the comparison")
        state.apply(.text("late"), to: first, at: start + 6)
        expect(state.columns[0].reply.text == "Hello", "a finished column takes nothing more")
    }

    static func latencyIsMeasuredFromTheInjectedClock() {
        var state = comparison([gpt, claude])
        let column = state.columns[0].id
        state.apply(.reasoning("Let me think"), to: column, at: start + 1)
        state.apply(.searching("speed", kind: .search, id: "s1"), to: column, at: start + 2)
        expect(state.columns[0].timeToFirstToken == nil, "thinking and searching are not an answer")
        state.apply(.text("Answer"), to: column, at: start + 3)
        state.apply(.finished, to: column, at: start + 7.5)
        let done = state.columns[0]
        expect(done.timeToFirstToken == 3, "first token time comes from the event's clock")
        expect(done.totalTime == 7.5, "total time runs to the end of the reply")
        expect(done.reply.reasoning.first?.duration == 2, "thinking closes when the answer starts")
        expect(done.reply.searches.allSatisfy(\.isComplete), "an answer settles open searches")
        expect(state.columns[1].totalTime == nil, "a column still streaming has no total")
    }

    static func cancelEndsEveryColumnAndLateEventsAreDropped() {
        var state = comparison([gpt, claude, local])
        let ids = state.columns.map(\.id)
        state.apply(.text("Partial"), to: ids[0], at: start + 1)
        state.apply(.finished, to: ids[2], at: start + 1)
        state.cancelAll(at: start + 2)
        expect(!state.isStreaming, "cancel ends every column")
        expect(state.columns[0].reply.state == .failed, "a streaming column is cancelled")
        expect(state.columns[0].reply.text == "Partial\n\n\(ModelComparison.cancelled)",
            "what arrived is kept above the cancel")
        expect(state.columns[1].reply.text == ModelComparison.cancelled, "an empty column says why")
        expect(state.columns[2].reply.state == .complete, "a finished column is left alone")
        state.apply(.text("more"), to: ids[1], at: start + 3)
        expect(state.columns[1].reply.text == ModelComparison.cancelled, "late text is dropped")
    }

    static func failureKeepsWhatArrived() {
        var state = comparison([gpt, claude])
        let column = state.columns[1].id
        state.apply(.text("Half"), to: column, at: start + 1)
        state.fail(column, message: "Rate limited", at: start + 2)
        expect(state.columns[1].reply.state == .failed, "a failure fails only its column")
        expect(state.columns[1].reply.text == "Half\n\nRate limited", "the reason follows the text")
        expect(state.columns[0].isStreaming, "the other column carries on")
        state.fail(column, message: "Again", at: start + 3)
        expect(state.columns[1].reply.text == "Half\n\nRate limited", "a column fails once")
    }

    static func retryResetsOnlyItsColumn() {
        var state = comparison([gpt, claude])
        let (first, second) = (state.columns[0].id, state.columns[1].id)
        expect(!state.retry(first, at: start + 1), "a streaming column is not retried")
        state.apply(.text("One"), to: first, at: start + 1)
        state.apply(.finished, to: first, at: start + 2)
        state.fail(second, message: "Offline", at: start + 2)
        expect(state.retry(second, at: start + 10), "a failed column retries")
        expect(state.columns[1].isStreaming && state.columns[1].reply.text.isEmpty,
            "the retried column starts over")
        expect(state.columns[1].startedAt == start + 10, "the retry restarts its clock")
        expect(state.columns[1].id == second && state.columns[1].model == claude,
            "the column keeps its identity and model")
        expect(state.columns[0].reply.text == "One", "the other column keeps its answer")
    }

    static func focusStaysOnAColumn() {
        var state = comparison([gpt, claude, local])
        state.focus(2)
        expect(state.focusedIndex == 2 && state.focusedColumn?.model == local, "focus moves")
        state.focus(3)
        expect(state.focusedIndex == 2, "a key past the last column is ignored")
        state.focus(-1)
        expect(state.focusedIndex == 2, "a negative index is ignored")
    }

    static func continuingMakesAChatWithFreshIDs() {
        var state = comparison([gpt, claude])
        let (first, second) = (state.columns[0].id, state.columns[1].id)
        expect(state.session(continuing: first, now: start) == nil, "a streaming column cannot continue")
        state.apply(.text("Fast"), to: first, at: start + 1)
        state.apply(.finished, to: first, at: start + 2)
        state.fail(second, message: "Offline", at: start + 2)
        expect(state.session(continuing: second, now: start) == nil, "a failed column cannot continue")
        guard let chat = state.session(continuing: first, now: start + 5),
            let again = state.session(continuing: first, now: start + 6)
        else { return expect(false, "a finished column continues") }
        expect(chat.model == gpt, "the chat takes the column's model")
        expect(chat.messages.map(\.text) == ["Which is faster?", "Fast"], "question then answer")
        expect(chat.messages.map(\.role) == [.user, .assistant], "roles survive")
        expect(Set(chat.messages.map(\.id)).isDisjoint(with: again.messages.map(\.id)),
            "continuing twice never reuses a stored message id")
        expect(chat.messages.last?.id != state.columns[0].reply.id, "the reply is reissued")
    }

    static func attachmentsFollowTheWeakestModel() {
        let common = ModelComparison.common([.codex, .claudeCommand])
        expect(common.images && !common.documents, "both read images, neither PDFs")
        expect(!ModelComparison.common([.codex, .appleIntelligence]).images,
            "one text-only model refuses pictures for all")
        expect(ModelComparison.common([]) == .none, "no picks take nothing")
        expect(!ModelComparison.common([.codex, .codex]).tools, "a comparison never calls tools")
    }

    static func requestsCarryTheWholeContext() {
        let chat = ChatSession(
            messages: [
                ChatMessage(role: .user, text: "First"),
                ChatMessage(role: .assistant, text: "Reply"),
                ChatMessage(role: .user, text: "Second")
            ])
        let state = ModelComparison(context: chat, models: [grok], now: start)
        expect(state.requestMessages().map(\.text) == ["First", "Reply", "Second"],
            "an inline comparison re-asks with the chat so far")
        expect(state.question?.text == "Second", "the question is the last user turn")
    }
}
