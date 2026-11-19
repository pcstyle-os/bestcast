import Foundation

/// What a screen capture copies. See docs/features/screen-capture.md.
enum ScreenCaptureReading: Equatable, Sendable {
    /// One or more QR or bar codes: their payload is what the region was for, not the text around it.
    case codes([String])
    case text(String, lines: Int)
    case nothing

    init(lines: [String], codes: [String]) {
        let codes = codes.filter { !$0.isEmpty }
        if !codes.isEmpty {
            self = .codes(codes)
            return
        }
        let lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self = lines.isEmpty ? .nothing : .text(lines.joined(separator: "\n"), lines: lines.count)
    }

    var copied: String? {
        switch self {
        case .codes(let codes): codes.joined(separator: "\n")
        case .text(let text, _): text
        case .nothing: nil
        }
    }

    var message: String {
        switch self {
        case .codes(let codes) where codes.count > 1: "Copied \(codes.count) codes"
        case .codes(let codes):
            URL(string: codes[0]).flatMap(\.scheme).map { ["http", "https"].contains($0) } == true
                ? "Copied link from code" : "Copied code"
        case .text(_, let lines): lines == 1 ? "Copied 1 line" : "Copied \(lines) lines"
        case .nothing: "No text found"
        }
    }
}

/// `#RRGGBB` from sRGB components in 0…1, clamped, so a wide-gamut sample never overflows.
enum HexColor {
    static func string(red: Double, green: Double, blue: Double) -> String {
        "#" + [red, green, blue].map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }
            .joined()
    }
}
