import Foundation

/// One unattended run of an AI Command: its reply, or why it produced none.
struct AIInboxEntry: Codable, Hashable, Identifiable, Sendable {
    enum Cause: String, Codable, Sendable {
        case schedule
        case login
        case clipboard

        var title: String {
            switch self {
            case .schedule: return "Scheduled"
            case .login: return "At login"
            case .clipboard: return "Clipboard match"
            }
        }
    }

    let id: UUID
    let commandID: UUID
    let commandName: String
    let symbol: String
    let cause: Cause
    let date: Date
    /// The turn a chat continues from, material and all.
    let prompt: String
    let reply: String
    let failure: String?

    init(
        id: UUID = UUID(), command: CustomQuickAction, cause: Cause, date: Date, prompt: String,
        reply: String, failure: String? = nil
    ) {
        self.id = id
        commandID = command.id
        commandName = command.name
        symbol = command.symbol
        self.cause = cause
        self.date = date
        self.prompt = prompt
        self.reply = reply
        self.failure = failure
    }

    var summary: String {
        let text = failure ?? reply
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
