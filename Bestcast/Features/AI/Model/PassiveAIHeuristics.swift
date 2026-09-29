import Foundation

/// What a piece of text is, told apart by shape alone so no model is ever asked.
enum PassiveContentKind: String, CaseIterable, Sendable {
    case code
    case url
    case email
    case address
    case phone
    case json
    case errorTrace
    case prose

    var title: String {
        switch self {
        case .code: return "Code"
        case .url: return "Link"
        case .email: return "Email Address"
        case .address: return "Address"
        case .phone: return "Phone Number"
        case .json: return "JSON"
        case .errorTrace: return "Error"
        case .prose: return "Text"
        }
    }

    /// Anything a reader would call a program: the actions that fit code fit these too.
    var isTechnical: Bool { self == .code || self == .json || self == .errorTrace }
}

/// An action offered on a passively read selection, ranked by `PassiveAIHeuristics.suggestions`.
enum PassiveSelectionAction: String, CaseIterable, Sendable {
    case explain
    case findBugs
    case translate
    case summarize
    case improveWriting
    case rewrite

    var title: String {
        switch self {
        case .explain: return "Explain"
        case .findBugs: return "Find Bugs"
        case .translate: return "Translate"
        case .summarize: return "Summarize"
        case .improveWriting: return "Improve Writing"
        case .rewrite: return "Rewrite"
        }
    }
}

/// The inline answer's debounce: every keystroke retires the answer the last one asked for.
struct PassiveInlineSchedule: Equatable, Sendable {
    static let delay: Duration = .milliseconds(600)

    enum Step: Equatable, Sendable {
        /// The query is the one already pending or shown; nothing restarts.
        case keep
        case clear
        case schedule(query: String, generation: Int)
    }

    private(set) var generation = 0
    private(set) var pending: String?

    mutating func noteQuery(_ query: String, eligible: Bool) -> Step {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if eligible, trimmed == pending { return .keep }
        generation += 1
        guard eligible else {
            pending = nil
            return .clear
        }
        pending = trimmed
        return .schedule(query: trimmed, generation: generation)
    }

    mutating func reset() {
        generation += 1
        pending = nil
    }

    func isCurrent(_ generation: Int) -> Bool { generation == self.generation && pending != nil }
}

/// Every passive-AI call that needs no model: cheap, pure, and capped so a paste cannot stall it.
enum PassiveAIHeuristics {
    /// Past this a text clip earns a one-line summary; shorter ones already read as their title.
    static let summaryThreshold = 400
    /// A selection this long is offered Summarize first.
    static let longSelection = 600
    /// Kind detection reads no further than this.
    static let detectionLimit = 4_096
    /// What the on-device model is handed to title a clip; its window is small.
    static let summaryExcerpt = 3_000
    static let summaryLength = 72

    static let answerInstructions = """
        Answer in at most two short sentences. Plain text only: no markdown, no lists, no preamble. \
        If you are not sure, say so briefly.
        """

    static let summaryInstructions = """
        Write a title of at most eight words for this clipboard text. Reply with the title only: \
        no quotes, no trailing punctuation, no preamble.
        """

    // MARK: - Inline answer

    private static let interrogatives: Set<String> = [
        "what", "what's", "whats", "why", "how", "how's", "who", "who's", "whom", "whose", "when",
        "where", "which"
    ]
    private static let auxiliaries: Set<String> = [
        "is", "are", "was", "were", "can", "could", "should", "would", "will", "does", "do", "did",
        "has", "have", "may", "might", "shall", "isn't", "aren't", "can't", "don't", "doesn't"
    ]
    private static let imperatives: Set<String> = [
        "explain", "define", "write", "summarize", "summarise", "translate", "describe", "compare",
        "suggest", "draft", "rewrite", "generate", "list", "outline", "brainstorm", "recommend"
    ]
    private static let imperativePhrases = [
        "tell me", "give me", "help me", "show me how", "teach me", "remind me what"
    ]

    /// A query worth an answer, never one that names something to open or sums something up.
    static func shouldOfferInlineAnswer(
        query: String, isCalculatorAnswer: Bool, exactlyMatchesEntry: Bool
    ) -> Bool {
        guard !isCalculatorAnswer, !exactlyMatchesEntry else { return false }
        return isQuestionOrInstruction(query) && !looksLikeMath(query)
    }

    static func isQuestionOrInstruction(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 500, trimmed.contains(where: \.isLetter),
            !looksLikeLocation(trimmed)
        else { return false }
        let words = trimmed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2, let first = words.first?.trimmingCharacters(in: .punctuationCharacters)
        else { return false }
        if trimmed.hasSuffix("?") { return true }
        if interrogatives.contains(first) { return words.count >= 3 }
        // "do not disturb" is a command to find, so a bare auxiliary needs a longer sentence.
        if auxiliaries.contains(first) { return words.count >= 4 }
        if imperatives.contains(first) { return trimmed.count >= 10 }
        let lowered = words.joined(separator: " ")
        return imperativePhrases.contains { lowered.hasPrefix($0 + " ") }
    }

    /// Arithmetic, a conversion or a bare number: the calculator's to answer, not a model's.
    static func looksLikeMath(_ query: String) -> Bool {
        let compact = query.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return false }
        if compact.first == "=" { return true }
        let mathSymbols = Set("0123456789.,+-*/^%()=×÷x·")
        let mathCount = compact.filter { mathSymbols.contains($0) }.count
        if Double(mathCount) / Double(compact.count) >= 0.6 { return true }
        // "10 usd in eur", "5 km to miles": a leading number is a conversion, however it reads.
        let firstToken = query.split(whereSeparator: \.isWhitespace).first ?? ""
        return firstToken.first.map { $0.isNumber || $0 == "$" || $0 == "€" || $0 == "£" } ?? false
    }

    /// A path or an address is something to open, never a question.
    private static func looksLikeLocation(_ text: String) -> Bool {
        if text.hasPrefix("/") || text.hasPrefix("~") { return true }
        return text.contains("://") || (!text.contains(" ") && text.contains("."))
    }

    // MARK: - Content kind

    static func kind(of text: String) -> PassiveContentKind {
        let trimmed = String(text.prefix(detectionLimit)).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .prose }
        if isJSON(trimmed, complete: text.count <= detectionLimit) { return .json }
        let singleToken = !trimmed.contains(where: \.isWhitespace)
        if singleToken, isURL(trimmed) { return .url }
        if singleToken, isEmail(trimmed) { return .email }
        if isPhone(trimmed) { return .phone }
        let lines = trimmed.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        if isErrorTrace(trimmed, lines: lines) { return .errorTrace }
        if isCode(lines) { return .code }
        if isAddress(trimmed, lines: lines) { return .address }
        return .prose
    }

    private static func isJSON(_ text: String, complete: Bool) -> Bool {
        guard let first = text.first, first == "{" || first == "[" else { return false }
        // A clip cut at the detection limit cannot parse; a quoted key still says what it is.
        guard complete else { return text.contains(#/"[^"\n]+"\s*:/#) }
        guard text.last == (first == "{" ? "}" : "]") else { return false }
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        // `[1]` parses, but a lone bracketed list reads as text to anyone who copied it.
        return object is [String: Any] || (object as? [Any])?.isEmpty == false && text.contains(":")
    }

    private static func isURL(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.hasPrefix("www."), text.count > 5 { return true }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp", "file", "mailto", "ssh"].contains(scheme) && url.host() != nil
            || scheme == "mailto"
    }

    private static func isEmail(_ text: String) -> Bool {
        text.wholeMatch(of: #/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#) != nil
    }

    private static func isPhone(_ text: String) -> Bool {
        guard text.count <= 24 else { return false }
        let allowed = Set("0123456789+()-. ")
        guard text.allSatisfy({ allowed.contains($0) }) else { return false }
        let digits = text.filter(\.isNumber).count
        // A dotted run is a version or an IP far more often than a number to dial.
        return (7...15).contains(digits) && text.filter({ $0 == "." }).count < 2
    }

    private static let strongTraceMarkers = [
        "Traceback (most recent call last)", "Exception in thread", "panic:", "Fatal error:",
        "fatal error:", "Uncaught ", "Stack trace:", "stack backtrace:"
    ]

    private static func isErrorTrace(_ text: String, lines: [String]) -> Bool {
        if strongTraceMarkers.contains(where: text.contains) { return true }
        if text.contains(#/Thread \d+ Crashed/#) { return true }
        let frames = lines.filter { line in
            line.hasPrefix("at ") || line.hasPrefix("File \"")
                || line.contains(#/^#\d+\s/#) || line.contains(#/^\d+\s+\S+\s+0x[0-9a-fA-F]+/#)
        }.count
        let lowered = text.lowercased()
        if frames >= 2, lowered.contains("error") || lowered.contains("exception") { return true }
        guard let first = lines.first else { return false }
        return first.contains(#/^[A-Za-z_.$]*(Error|Exception)(\s*\[[^\]]*\])?:\s/#)
    }

    private static let codeLeads = [
        "func ", "def ", "class ", "struct ", "enum ", "import ", "return ", "let ", "var ",
        "const ", "fn ", "pub ", "public ", "private ", "package ", "#include", "#import", "using ",
        "interface ", "SELECT ", "INSERT ", "UPDATE ", "CREATE ", "<div", "</", "<?php", "@", "//",
        "if (", "for (", "while (", "} else", "elif ", "try {", "catch", "export ", "async ", "#!/"
    ]

    private static func isCode(_ lines: [String]) -> Bool {
        guard !lines.isEmpty else { return false }
        let codeLines = lines.filter(isCodeLine).count
        guard codeLines > 0 else { return false }
        let hasSymbols = lines.contains { $0.contains(where: { "{}();=<>[]".contains($0) }) }
        return hasSymbols && Double(codeLines) / Double(lines.count) >= 0.4
    }

    private static func isCodeLine(_ line: String) -> Bool {
        if codeLeads.contains(where: line.hasPrefix) { return true }
        if let last = line.last, ";{}".contains(last) { return true }
        if line.contains("=>") || line.contains("->") || line.contains("::") { return true }
        if line.contains(#/^\w+(\.\w+)*\(.*\)$/#) { return true }
        let assigns = line.contains(#/\w+ = [^=]/#)
        return assigns && line.contains(where: { "();[]{}".contains($0) })
    }

    private static let streetWords: Set<String> = [
        "street", "st", "st.", "avenue", "ave", "ave.", "road", "rd", "rd.", "boulevard", "blvd",
        "lane", "ln", "drive", "dr", "dr.", "way", "court", "ct", "place", "pl", "square", "sq",
        "ul.", "ulica", "al.", "straße", "strasse", "str.", "rue", "via", "calle", "avenida", "platz"
    ]

    private static func isAddress(_ text: String, lines: [String]) -> Bool {
        guard text.count <= 200, lines.count <= 5, text.contains(where: \.isNumber) else {
            return false
        }
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
        let hasStreet = words.contains(where: streetWords.contains)
        let hasPostal =
            text.contains(#/\b\d{5}(-\d{4})?\b/#) || text.contains(#/\b\d{2}-\d{3}\b/#)
            || text.contains(#/\b[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}\b/#)
        return hasStreet && words.count <= 30 || hasPostal && (lines.count >= 2 || text.contains(","))
    }

    // MARK: - Selection suggestions

    /// The top three actions for a selection: its kind decides, then its language and length.
    static func suggestions(
        for text: String, kind: PassiveContentKind, isForeignLanguage: Bool
    ) -> [PassiveSelectionAction] {
        if kind.isTechnical { return [.explain, .findBugs, .summarize] }
        if isForeignLanguage { return [.translate, .explain, .summarize] }
        if text.count >= longSelection { return [.summarize, .improveWriting, .rewrite] }
        return [.improveWriting, .rewrite, .translate]
    }

    /// The recognised language against the reader's own, compared by base language code only.
    static func isForeign(dominantLanguage: String?, preferredLanguages: [String]) -> Bool {
        guard let dominant = dominantLanguage.map(baseLanguage), !dominant.isEmpty,
            dominant != "und", !preferredLanguages.isEmpty
        else { return false }
        return !preferredLanguages.map(baseLanguage).contains(dominant)
    }

    private static func baseLanguage(_ identifier: String) -> String {
        String(identifier.lowercased().prefix { $0 != "-" && $0 != "_" })
    }

    // MARK: - Clipboard summaries

    static func isSummaryEligible(_ text: String) -> Bool {
        !text.dropFirst(summaryThreshold).isEmpty
    }

    /// What a model hands back, cut to one clean line; nil when nothing usable is left.
    static func oneLine(_ raw: String, limit: Int = summaryLength) -> String? {
        var line =
            raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if let label = line.firstMatch(of: #/^(?i:title|summary)\s*:\s*/#) {
            line.removeSubrange(label.range)
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_\"'“”‘’` "))
        while let last = line.last, ".:;,".contains(last) { line.removeLast() }
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
