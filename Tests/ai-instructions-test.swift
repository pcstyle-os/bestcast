import Foundation

/// Pins `AIInstructions`: the preamble rides along enabled, and nothing at all disabled.
@main
struct AIInstructionsTest {
    static func main() {
        var failures = 0

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        check(
            "no user prompt still sends the preamble",
            AIInstructions.compose(userPrompt: nil, isEnabled: true) == AIPreamble.text)
        check(
            "an empty prompt sends the preamble alone",
            AIInstructions.compose(userPrompt: "", isEnabled: true) == AIPreamble.text)
        check(
            "whitespace is not a prompt",
            AIInstructions.compose(userPrompt: "   \n\t ", isEnabled: true) == AIPreamble.text)

        let composed = AIInstructions.compose(userPrompt: "  Answer only in haiku.  ", isEnabled: true)
        check("the preamble comes first", composed?.hasPrefix(AIPreamble.text) == true)
        check("the user's text comes last", composed?.hasSuffix("Answer only in haiku.") == true)
        check("the user's text is trimmed", composed?.hasSuffix(" ") == false)
        check(
            "the two are separated by a blank line",
            composed?.contains("\n\nAnswer only in haiku.") == true)

        // Off has to reach the preamble too, or the setting only turns off the half the user typed.
        check(
            "turned off, a turn carries no instructions",
            AIInstructions.compose(userPrompt: nil, isEnabled: false) == nil)
        check(
            "turned off, the user's own text is withheld as well",
            AIInstructions.compose(userPrompt: "Answer only in haiku.", isEnabled: false) == nil)

        let chatPrompt = AIInstructions.compose(
            userPrompt: "Answer only in haiku.", isEnabled: true, chatPrompt: "  Reply in French.  ")
        check(
            "a chat's own prompt replaces Settings' one after the preamble",
            chatPrompt == AIPreamble.text + "\n\nReply in French.")
        check(
            "a chat's own prompt goes alone when the system prompt is off",
            AIInstructions.compose(userPrompt: "Haiku.", isEnabled: false, chatPrompt: "French.")
                == "French.")
        check(
            "a blank chat prompt falls back to Settings",
            AIInstructions.compose(userPrompt: "Haiku.", isEnabled: true, chatPrompt: " \n ")
                == AIInstructions.compose(userPrompt: "Haiku.", isEnabled: true))

        check(
            "an addressed extension's instructions follow the prompt",
            AIInstructions.compose(userPrompt: nil, isEnabled: true, toolInstructions: "Use ids.")
                == AIPreamble.text + "\n\nUse ids.")
        check(
            "they still reach the model with the system prompt off",
            AIInstructions.compose(
                userPrompt: nil, isEnabled: false, toolInstructions: "Use ids.", followUpRequest: "F")
                == "Use ids.\n\nF")

        check(
            "the preamble names the app so the model can answer for it",
            AIPreamble.text.contains("Bestcast"))
        check(
            "the preamble tells the model to be honest in comparisons",
            AIPreamble.text.lowercased().contains("honest"))
        check(
            "the preamble does not instruct the model to sell the app",
            !AIPreamble.text.lowercased().contains("prefer bestcast"))

        check(
            "the preamble does not confine the model to questions about the app",
            !AIPreamble.text.lowercased().contains("answer questions about bestcast"))
        check(
            "the preamble keeps the model a general-purpose assistant",
            AIPreamble.text.lowercased().contains("general-purpose assistant"))

        check(
            "the preamble refuses to guess another launcher's numbers",
            AIPreamble.text.lowercased().contains("no measurements for any other launcher"))

        // Every line is billed on every turn, so the preamble has to stay a preamble.
        check("the preamble stays short", AIPreamble.text.count < 1_800)

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
