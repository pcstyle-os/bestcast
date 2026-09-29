import Foundation

/// A GitHub address to install from: `https://github.com/<owner>/<repo>[/tree/<ref>/<subdir>]`.
struct ExtensionGitURL: Sendable, Hashable {
    let owner: String
    let repository: String
    /// A branch or tag; one path segment, so a ref holding a slash reads as ref plus folder.
    let ref: String?
    let subdirectory: String?

    var cloneURL: URL {
        URL(string: "https://github.com/\(owner)/\(repository).git")!
    }

    var displayString: String {
        var text = "https://github.com/\(owner)/\(repository)"
        if let ref { text += "/tree/\(ref)" }
        if let subdirectory { text += "/\(subdirectory)" }
        return text
    }

    init?(_ text: String) {
        guard
            let components = URLComponents(
                string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            components.scheme?.lowercased() == "https",
            ["github.com", "www.github.com"].contains(components.host?.lowercased() ?? "")
        else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let repository = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        guard Self.isSafeSegment(parts[0]), Self.isSafeSegment(repository) else { return nil }
        owner = parts[0]
        self.repository = repository
        guard parts.count > 2 else {
            ref = nil
            subdirectory = nil
            return
        }
        guard parts[2] == "tree", parts.count >= 4, Self.isSafeSegment(parts[3]) else { return nil }
        ref = parts[3]
        let folder = parts.dropFirst(4)
        guard folder.allSatisfy(Self.isSafeSegment) else { return nil }
        subdirectory = folder.isEmpty ? nil : folder.joined(separator: "/")
    }

    /// Every segment reaches `git` or the filesystem: a leading dash is an option, `..` an escape.
    private static func isSafeSegment(_ segment: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return !segment.isEmpty && !segment.hasPrefix("-") && segment != "." && segment != ".."
            && segment.unicodeScalars.allSatisfy(allowed.contains)
    }
}
