import Foundation

/// One retrievable stretch of a file; `page` is 1-based, and only a PDF's chunks carry one.
struct ChatLibraryChunk: Codable, Equatable, Hashable, Sendable {
    let path: String
    let page: Int?
    let text: String
}

/// A chat's on-device library: every chunk and its vector, ranked afresh for each turn.
struct ChatLibraryIndex: Codable, Equatable, Sendable {
    /// What the reader attached, folders and files alike; Reindex walks these again.
    let roots: [String]
    /// The embedding's language; nil when none fits, and then the words alone rank.
    let language: String?
    let dimension: Int
    let chunks: [ChatLibraryChunk]
    /// Packed unit-length Float32s, `dimension` per chunk: a plist of a million numbers loads slowly.
    let vectors: Data
    let fileCount: Int
    /// Files passed over: unreadable, unsupported or past a cap.
    let skippedCount: Int
    /// A cap cut the walk short, so part of what was attached is not in here.
    let isTruncated: Bool

    var hasVectors: Bool { language != nil && dimension > 0 && vectors.count == chunks.count * dimension * 4 }

    /// Only a strong match counts: past the best one, a passage half as relevant is noise.
    static let relevanceFloor = 0.5
    /// Words matter less once meaning is scored; they still lift a passage naming the exact term.
    static let lexicalWeight = 0.35

    /// Best first, inside `budget` bytes, with at most `perFile` from one file so none crowds out.
    func passages(
        for query: String, vector: [Float]?, budget: Int, limit: Int = 8, perFile: Int = 3
    ) -> [ChatLibraryChunk] {
        let terms = Self.terms(in: query)
        let unit = vector.flatMap { hasVectors && $0.count == dimension ? Self.normalized($0) : nil }
        guard !chunks.isEmpty else { return [] }
        guard unit != nil || !terms.isEmpty else { return openings(budget: budget, limit: limit) }
        let stored = unit == nil ? [] : unpackedVectors()
        var scores: [(index: Int, score: Double)] = []
        scores.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            let lexical = terms.isEmpty ? 0 : Self.overlap(terms, chunk.text)
            guard let unit else {
                if lexical > 0 { scores.append((index, lexical)) }
                continue
            }
            var dot: Float = 0
            let base = index * dimension
            for offset in 0..<dimension { dot += unit[offset] * stored[base + offset] }
            scores.append((index, Double(dot) + Self.lexicalWeight * lexical))
        }
        scores.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        guard let best = scores.first?.score, best > 0 else {
            return openings(budget: budget, limit: limit)
        }
        var picked: [ChatLibraryChunk] = []
        var used = 0
        var perPath: [String: Int] = [:]
        for candidate in scores {
            guard candidate.score >= best * Self.relevanceFloor, picked.count < limit else { break }
            let chunk = chunks[candidate.index]
            let cost = chunk.text.utf8.count
            guard perPath[chunk.path, default: 0] < perFile, used + cost <= budget else { continue }
            picked.append(chunk)
            used += cost
            perPath[chunk.path, default: 0] += 1
        }
        return picked
    }

    /// "Summarise this" names nothing to match, so each file's first chunk stands in for it.
    func openings(budget: Int, limit: Int = 8) -> [ChatLibraryChunk] {
        var seen = Set<String>()
        var picked: [ChatLibraryChunk] = []
        var used = 0
        for chunk in chunks where picked.count < limit && seen.insert(chunk.path).inserted {
            guard used + chunk.text.utf8.count <= budget else { continue }
            picked.append(chunk)
            used += chunk.text.utf8.count
        }
        return picked
    }

    /// Folded and split on anything not a letter or digit; short and common words say nothing.
    static func terms(in text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var terms = Set<String>()
        for word in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let isNumber = word.allSatisfy(\.isNumber)
            guard word.count >= (isNumber ? 2 : 3), !stopWords.contains(String(word)) else { continue }
            terms.insert(String(word))
        }
        return terms
    }

    /// The share of the query's terms the passage holds, from 0 to 1.
    static func overlap(_ terms: Set<String>, _ text: String) -> Double {
        guard !terms.isEmpty else { return 0 }
        let present = Self.terms(in: text)
        return Double(terms.count { present.contains($0) }) / Double(terms.count)
    }

    static func normalized(_ vector: [Float]) -> [Float]? {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0, length.isFinite else { return nil }
        return vector.map { $0 / length }
    }

    /// Each vector made unit length first, so ranking is a dot product; an unusable one stays zero.
    static func packed(_ vectors: [[Float]?], dimension: Int) -> Data {
        var flat = [Float](repeating: 0, count: vectors.count * dimension)
        for (index, vector) in vectors.enumerated() {
            guard let vector, vector.count == dimension, let unit = normalized(vector) else { continue }
            flat.replaceSubrange(index * dimension..<(index + 1) * dimension, with: unit)
        }
        return flat.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Copied out rather than bound in place: a decoded `Data` promises no Float alignment.
    private func unpackedVectors() -> [Float] {
        let count = vectors.count / MemoryLayout<Float>.size
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = vectors.copyBytes(to: buffer) / MemoryLayout<Float>.size
        }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was",
        "one", "our", "out", "has", "have", "him", "his", "how", "its", "may", "who", "did", "does",
        "this", "that", "with", "from", "they", "them", "then", "than", "what", "when", "where",
        "which", "while", "will", "would", "there", "their", "about", "into", "your", "been",
        "were", "more", "some", "such", "only", "also", "just", "like", "file", "files", "document",
        "tell", "show", "give", "please", "summarize", "summarise", "explain"
    ]
}
