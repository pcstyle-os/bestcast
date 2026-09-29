import Foundation

/// Every turn carries `AIPreamble` then the user's text; turned off, it carries neither.
enum AIInstructions {
    /// The user's own text goes last, so it can qualify the preamble rather than fight it.
    static func compose(userPrompt: String?, isEnabled: Bool) -> String? {
        guard isEnabled else { return nil }
        let trimmed = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? AIPreamble.text : AIPreamble.text + "\n\n" + trimmed
    }

    /// A chat's own prompt takes the place of Settings' one; with the preamble off it goes alone.
    static func compose(userPrompt: String?, isEnabled: Bool, chatPrompt: String?) -> String? {
        let chat = chatPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !chat.isEmpty else { return compose(userPrompt: userPrompt, isEnabled: isEnabled) }
        return isEnabled ? AIPreamble.text + "\n\n" + chat : chat
    }
}
