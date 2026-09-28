import Foundation

/// The paste target is whoever held focus a moment ago, never an activation the workspace missed.
@main
@MainActor
struct FrontmostAppTests {
    static var failures = 0
    static var passes = 0

    static let own: pid_t = 100
    static let chatGPT: pid_t = 200
    static let textEdit: pid_t = 300

    static func expect(_ actual: pid_t?, _ expected: pid_t?, _ message: String) {
        if actual == expected {
            passes += 1
        } else {
            failures += 1
            let got = actual.map(String.init) ?? "nil"
            print("FAIL: \(message) — got \(got), want \(expected.map(String.init) ?? "nil")")
        }
    }

    static func main() {
        expect(
            FrontmostApplication.resolve(focused: textEdit, workspace: chatGPT, own: own),
            textEdit, "live focus wins over a workspace that has not heard of the activation yet")
        expect(
            FrontmostApplication.resolve(focused: textEdit, workspace: textEdit, own: own),
            textEdit, "agreeing sources")
        expect(
            FrontmostApplication.resolve(focused: own, workspace: textEdit, own: own),
            textEdit, "our non-activating panel holds focus over the app it covers")
        expect(
            FrontmostApplication.resolve(focused: own, workspace: own, own: own),
            own, "Tinycast itself active: ours, which the palette then drops")
        expect(
            FrontmostApplication.resolve(focused: own, workspace: nil, own: own),
            own, "nothing else to fall back to")
        expect(
            FrontmostApplication.resolve(focused: nil, workspace: chatGPT, own: own),
            chatGPT, "no Accessibility grant leaves the workspace's answer")
        expect(
            FrontmostApplication.resolve(focused: nil, workspace: nil, own: own),
            nil, "no answer at all")

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
