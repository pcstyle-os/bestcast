import Foundation

@main
nonisolated enum ClipboardTextHelper {
    static func main() async {
        guard CommandLine.arguments.count == 3,
            ["image", "pdf", "codes"].contains(CommandLine.arguments[1])
        else { exit(2) }
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            let text =
                CommandLine.arguments[1] == "codes"
                ? try await ClipboardTextExtractor.codes(at: url)
                : try await ClipboardTextExtractor.extract(at: url, isPDF: CommandLine.arguments[1] == "pdf")
            try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
        } catch {
            exit(1)
        }
    }
}
