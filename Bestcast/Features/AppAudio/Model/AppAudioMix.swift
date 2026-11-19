import Foundation

/// One app's place in the mixer. See docs/features/app-audio.md.
struct AppAudioSetting: Codable, Equatable, Sendable {
    /// The slider's position, 0…1; `gain` is what the samples are multiplied by.
    var volume: Double = 1
    var muted = false
    /// A device UID, or nil to follow the system's default output.
    var outputUID: String?

    /// Squared, so the slider's middle sounds like the middle rather than nearly full.
    var gain: Float { muted ? 0 : Float(min(max(volume, 0), 1) * min(max(volume, 0), 1)) }

    /// An untouched app plays straight through, with no tap and no added latency.
    var needsTap: Bool { muted || volume < 1 || outputUID != nil }
}

/// One mixer row: an app and every audio process that plays on its behalf.
struct AppAudioGroup: Equatable, Sendable {
    /// A bundle ID, or a command-line player's executable name, which has none.
    var appID: String
    var processes: [AudioProcessInfo]
    var isPlaying: Bool { processes.contains(where: \.isPlaying) }
}

struct AudioProcessInfo: Equatable, Sendable {
    var objectID: UInt32
    var pid: Int32
    var appID: String
    var isPlaying: Bool
}

enum AppAudioGrouping {
    /// A helper (`com.google.Chrome.helper`) belongs to the app whose bundle ID prefixes its own.
    static func owner(of processBundleID: String, among apps: Set<String>) -> String {
        var candidate = processBundleID
        while let dot = candidate.lastIndex(of: ".") {
            candidate = String(candidate[..<dot])
            if apps.contains(candidate) { return candidate }
        }
        return processBundleID
    }

    /// Rows for apps playing now, plus any app the reader adjusted that still has a process.
    static func groups(
        _ processes: [AudioProcessInfo], apps: Set<String>, adjusted: Set<String>, excluding own: String
    ) -> [AppAudioGroup] {
        var byOwner: [String: [AudioProcessInfo]] = [:]
        for process in processes where !process.appID.isEmpty {
            let owner = owner(of: process.appID, among: apps)
            guard owner != own else { continue }
            byOwner[owner, default: []].append(process)
        }
        return byOwner
            .map { AppAudioGroup(appID: $0.key, processes: $0.value) }
            .filter { $0.isPlaying || adjusted.contains($0.appID) }
            .sorted { $0.appID < $1.appID }
    }
}
