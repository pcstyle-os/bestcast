import Foundation
import NaturalLanguage

/// Apple's on-device sentence embeddings; nothing here touches the network.
nonisolated enum ChatEmbeddingService {
    /// The text's dominant language, when macOS ships a sentence embedding for it.
    static func language(of sample: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(20_000)))
        guard let language = recognizer.dominantLanguage,
            NLEmbedding.sentenceEmbedding(for: language) != nil
        else { return nil }
        return language.rawValue
    }

    static func vector(for text: String, language: String) -> [Float]? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: NLLanguage(language)) else {
            return nil
        }
        return embedding.vector(for: text).map { $0.map(Float.init) }
    }

    static func dimension(for language: String) -> Int {
        NLEmbedding.sentenceEmbedding(for: NLLanguage(language))?.dimension ?? 0
    }

    /// Each lane loads its own model, about 17 MB more resident, so two lanes is the ceiling.
    static let maxLanes = 2

    static func vectors(
        for texts: [String], language: String, progress: @escaping @Sendable (Int) -> Void
    ) async -> [[Float]?] {
        let lanes = max(1, min(maxLanes, ProcessInfo.processInfo.activeProcessorCount / 2))
        let stride = (texts.count + lanes - 1) / max(lanes, 1)
        return await withTaskGroup(of: (Int, [[Float]?]).self) { group in
            for lane in 0..<lanes {
                let range = min(lane * stride, texts.count)..<min((lane + 1) * stride, texts.count)
                guard !range.isEmpty else { continue }
                let slice = Array(texts[range])
                group.addTask {
                    guard let embedding = NLEmbedding.sentenceEmbedding(for: NLLanguage(language))
                    else { return (range.lowerBound, slice.map { _ in nil }) }
                    var vectors: [[Float]?] = []
                    vectors.reserveCapacity(slice.count)
                    for text in slice {
                        guard !Task.isCancelled else { break }
                        vectors.append(embedding.vector(for: text).map { $0.map(Float.init) })
                        progress(1)
                    }
                    return (range.lowerBound, vectors)
                }
            }
            var result = [[Float]?](repeating: nil, count: texts.count)
            for await (start, vectors) in group {
                for (offset, vector) in vectors.enumerated() { result[start + offset] = vector }
            }
            return result
        }
    }
}
