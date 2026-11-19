// `ScreenCaptureReading` and `HexColor`: what a capture copies and how it reports it.

import Foundation

@main
struct ScreenCaptureTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0

    static func check(_ name: String, _ condition: Bool) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func main() {
        let text = ScreenCaptureReading(lines: ["  error: cannot find  ", "", "^~~~"], codes: [])
        check("blank lines drop and edges trim", text.copied == "error: cannot find\n^~~~")
        check("the count is of kept lines", text.message == "Copied 2 lines")
        check("one line says so", ScreenCaptureReading(lines: ["ok"], codes: []).message == "Copied 1 line")

        let link = ScreenCaptureReading(lines: ["Scan me"], codes: ["https://tibo.dog"])
        check("a code beats the text around it", link.copied == "https://tibo.dog")
        check("a web link says it is one", link.message == "Copied link from code")
        let wifi = ScreenCaptureReading(lines: [], codes: ["WIFI:S:home;T:WPA;P:hunter2;;"])
        check("a non-web payload is just a code", wifi.message == "Copied code")
        let two = ScreenCaptureReading(lines: [], codes: ["a", "", "b"])
        check("several codes copy one per line", two.copied == "a\nb" && two.message == "Copied 2 codes")

        let empty = ScreenCaptureReading(lines: [" ", ""], codes: [""])
        check("whitespace and empty payloads are nothing", empty == .nothing && empty.copied == nil)

        check("hex rounds each channel", HexColor.string(red: 0.925, green: 0.298, blue: 0.541) == "#EC4C8A")
        check("hex clamps wide-gamut overshoot", HexColor.string(red: 1.04, green: -0.02, blue: 0.5) == "#FF0080")

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
