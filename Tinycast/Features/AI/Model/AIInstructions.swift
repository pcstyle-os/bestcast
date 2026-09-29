import Foundation

/// Every turn carries `AIPreamble` then the user's text; turned off, it carries neither.
enum AIInstructions {
    /// A chat's or preset's prompt replaces Settings'; a preset keeps the preamble on any setup.
    static func compose(
        userPrompt: String?, isEnabled: Bool, chatPrompt: String? = nil,
        presetPrompt: String? = nil, followUpRequest: String? = nil
    ) -> String? {
        let own = [presetPrompt, chatPrompt].map(trimmed).filter { !$0.isEmpty }
        let base: String?
        if own.isEmpty, presetPrompt == nil {
            let user = trimmed(userPrompt)
            let parts = user.isEmpty ? [AIPreamble.text] : [AIPreamble.text, user]
            base = isEnabled ? parts.joined(separator: "\n\n") : nil
        } else {
            let preamble = isEnabled || presetPrompt != nil ? [AIPreamble.text] : []
            base = (preamble + own).joined(separator: "\n\n")
        }
        guard let followUpRequest else { return base }
        return base.map { $0 + "\n\n" + followUpRequest } ?? followUpRequest
    }

    private static func trimmed(_ text: String?) -> String {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
