import Foundation

// Guards PassiveAIHeuristics: answer offers, content kinds, suggested actions and the debounce.

@main
@MainActor
struct PassiveAITests {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool) {
        if !condition {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func main() {
        inlineAnswers()
        contentKinds()
        selectionSuggestions()
        schedule()
        summaries()
        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("passive-ai-test: all passed")
    }

    static func offers(_ query: String, calc: Bool = false, exact: Bool = false) -> Bool {
        PassiveAIHeuristics.shouldOfferInlineAnswer(
            query: query, isCalculatorAnswer: calc, exactlyMatchesEntry: exact)
    }

    static func inlineAnswers() {
        for question in [
            "what is the capital of france", "how do I undo a git commit",
            "why is the sky blue", "explain monads simply", "tell me a fun fact",
            "is it safe to delete derived data?", "capital of peru?",
            "translate good morning to polish", "can you convert heic to png on a mac"
        ] {
            check("offers an answer for “\(question)”", offers(question))
        }
        for query in [
            "safari", "sys", "do not disturb", "2+2", "12 * (3 + 4)", "10 usd in eur",
            "5 km to miles", "= 3^2", "github.com", "https://example.com/what?", "~/Documents",
            "what", "how are", "", "   "
        ] {
            check("offers nothing for “\(query)”", !offers(query))
        }
        check("an exact entry match is never answered", !offers("what is my ip", exact: true))
        check("a calculator answer is never answered", !offers("what is 2 plus 2", calc: true))
        check("a leading number reads as math", PassiveAIHeuristics.looksLikeMath("3 cups in ml"))
        check("prose is not math", !PassiveAIHeuristics.looksLikeMath("what is a matrix"))
        check(
            "a very long paste is not a question",
            !offers("why " + String(repeating: "a ", count: 400)))
    }

    static func kind(_ text: String) -> PassiveContentKind { PassiveAIHeuristics.kind(of: text) }

    static func contentKinds() {
        check("json object", kind(#"{"name": "tinycast", "version": 2}"#) == .json)
        check("json array of objects", kind(#"[{"a": 1}, {"a": 2}]"#) == .json)
        check("braces that do not parse are not json", kind("{ not json }") != .json)
        check("https url", kind("https://example.com/path?q=1") == .url)
        check("www url", kind("www.apple.com") == .url)
        check("url with surrounding space", kind("  https://apple.com  ") == .url)
        check("email", kind("adam@example.com") == .email)
        check("phone", kind("+48 123 456 789") == .phone)
        check("phone with parentheses", kind("(555) 123-4567") == .phone)
        check("an ip address is not a phone", kind("192.168.1.10") != .phone)
        check("a short number is not a phone", kind("12345") != .phone)
        check(
            "python traceback",
            kind(
                """
                Traceback (most recent call last):
                  File "main.py", line 3, in <module>
                ZeroDivisionError: division by zero
                """) == .errorTrace)
        check(
            "java stack",
            kind(
                """
                java.lang.NullPointerException: boom
                    at com.example.Foo.bar(Foo.java:10)
                    at com.example.Foo.main(Foo.java:4)
                """) == .errorTrace)
        check("one-line error", kind("TypeError: undefined is not a function") == .errorTrace)
        check(
            "swift code",
            kind(
                """
                func greet(_ name: String) -> String {
                    return "Hello, \\(name)"
                }
                """) == .code)
        check("javascript one-liner", kind("const total = items.reduce((a, b) => a + b, 0);") == .code)
        check("sql", kind("SELECT id, name FROM users WHERE active = 1;") == .code)
        check("street address", kind("1 Infinite Loop, Cupertino, CA 95014") == .address)
        check("polish address", kind("ul. Marszałkowska 10\n00-590 Warszawa") == .address)
        check(
            "prose",
            kind("The meeting moved to Thursday, so let's plan the review for next week instead.")
                == .prose)
        check("empty is prose", kind("   ") == .prose)
        check("a sentence with a url is prose", kind("see https://apple.com for details") == .prose)
        let huge = "{\"key\": \"" + String(repeating: "x", count: 10_000) + "\"}"
        check("json cut at the detection limit still reads as json", kind(huge) == .json)
        check("every kind has a title", PassiveContentKind.allCases.allSatisfy { !$0.title.isEmpty })
    }

    static func selectionSuggestions() {
        let code = PassiveAIHeuristics.suggestions(for: "x", kind: .code, isForeignLanguage: false)
        check("code leads with explain and find bugs", code.prefix(2) == [.explain, .findBugs])
        let trace = PassiveAIHeuristics.suggestions(
            for: "x", kind: .errorTrace, isForeignLanguage: true)
        check("a trace is technical before it is foreign", trace.first == .explain)
        let foreign = PassiveAIHeuristics.suggestions(
            for: "Dzień dobry", kind: .prose, isForeignLanguage: true)
        check("foreign text leads with translate", foreign.first == .translate)
        let long = PassiveAIHeuristics.suggestions(
            for: String(repeating: "word ", count: 200), kind: .prose, isForeignLanguage: false)
        check("long text leads with summarize", long.first == .summarize)
        let short = PassiveAIHeuristics.suggestions(
            for: "their going to the store", kind: .prose, isForeignLanguage: false)
        check("short text leads with improve writing", short.first == .improveWriting)
        for list in [code, trace, foreign, long, short] {
            check("three distinct suggestions", list.count == 3 && Set(list).count == 3)
        }
        check(
            "polish is foreign to an english reader",
            PassiveAIHeuristics.isForeign(dominantLanguage: "pl", preferredLanguages: ["en-US"]))
        check(
            "a regional variant is not foreign",
            !PassiveAIHeuristics.isForeign(dominantLanguage: "en", preferredLanguages: ["en-GB"]))
        check(
            "any preferred language counts",
            !PassiveAIHeuristics.isForeign(
                dominantLanguage: "pl", preferredLanguages: ["en-US", "pl-PL"]))
        check(
            "an unknown language is not foreign",
            !PassiveAIHeuristics.isForeign(dominantLanguage: nil, preferredLanguages: ["en"]))
        check(
            "undetermined is not foreign",
            !PassiveAIHeuristics.isForeign(dominantLanguage: "und", preferredLanguages: ["en"]))
    }

    static func schedule() {
        var schedule = PassiveInlineSchedule()
        guard case .schedule(let first, let firstGeneration) = schedule.noteQuery(
            "what is rust", eligible: true)
        else {
            check("an eligible query schedules", false)
            return
        }
        check("the scheduled query is trimmed", first == "what is rust")
        check("a fresh schedule is current", schedule.isCurrent(firstGeneration))
        check(
            "the same query again keeps the pending answer",
            schedule.noteQuery("what is rust ", eligible: true) == .keep)
        check("keeping does not retire it", schedule.isCurrent(firstGeneration))
        let next = schedule.noteQuery("what is rusty", eligible: true)
        check("a keystroke retires the old answer", !schedule.isCurrent(firstGeneration))
        guard case .schedule(_, let secondGeneration) = next else {
            check("a changed eligible query reschedules", false)
            return
        }
        check("the newer answer is current", schedule.isCurrent(secondGeneration))
        check("an ineligible query clears", schedule.noteQuery("safari", eligible: false) == .clear)
        check("clearing retires the pending answer", !schedule.isCurrent(secondGeneration))
        check("nothing is pending after a clear", schedule.pending == nil)
        check("clearing twice still clears", schedule.noteQuery("saf", eligible: false) == .clear)
        guard case .schedule(_, let third) = schedule.noteQuery("why is it", eligible: true) else {
            check("an eligible query after a clear schedules", false)
            return
        }
        schedule.reset()
        check("hiding the palette retires the answer", !schedule.isCurrent(third))
        check(
            "the same query after a reset asks again",
            schedule.noteQuery("why is it", eligible: true) != .keep)
        check("the delay is the promised pause", PassiveInlineSchedule.delay == .milliseconds(600))
    }

    static func summaries() {
        check(
            "a short clip is not summarised",
            !PassiveAIHeuristics.isSummaryEligible(String(repeating: "a", count: 400)))
        check(
            "a long clip is summarised",
            PassiveAIHeuristics.isSummaryEligible(String(repeating: "a", count: 401)))
        check(
            "a label and quotes are stripped",
            PassiveAIHeuristics.oneLine("Title: \"Quarterly budget notes.\"\nmore")
                == "Quarterly budget notes")
        check("blank output is nothing", PassiveAIHeuristics.oneLine(" \n\n ") == nil)
        let capped = PassiveAIHeuristics.oneLine(String(repeating: "word ", count: 50), limit: 20)
        check("a long line is capped", capped?.count == 20 && capped?.hasSuffix("…") == true)
    }
}
