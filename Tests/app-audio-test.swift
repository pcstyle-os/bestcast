// `AppAudioSetting` and `AppAudioGrouping`: what a slider does to the samples, when an app needs a tap,
// and which row a helper process belongs to.

import Foundation

@main
struct AppAudioTests {
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

    static func process(_ id: UInt32, _ bundle: String, playing: Bool = true) -> AudioProcessInfo {
        AudioProcessInfo(objectID: id, pid: Int32(id), appID: bundle, isPlaying: playing)
    }

    static func main() {
        check("an untouched app needs no tap", !AppAudioSetting().needsTap && AppAudioSetting().gain == 1)
        check("half the slider is a quarter of the amplitude", AppAudioSetting(volume: 0.5).gain == 0.25)
        check("a lowered app is tapped", AppAudioSetting(volume: 0.99).needsTap)
        check("muted is silent whatever the slider says", AppAudioSetting(volume: 1, muted: true).gain == 0)
        check("a muted app at full volume is still tapped", AppAudioSetting(muted: true).needsTap)
        check("another output is tapped at full volume", AppAudioSetting(outputUID: "BuiltIn").needsTap)
        check("an out-of-range volume clamps", AppAudioSetting(volume: 1.7).gain == 1 && AppAudioSetting(volume: -1).gain == 0)

        let apps: Set = ["com.google.Chrome", "com.spotify.client", "com.bestcast.app.dev"]
        check(
            "a helper belongs to its app",
            AppAudioGrouping.owner(of: "com.google.Chrome.helper.Renderer", among: apps) == "com.google.Chrome")
        check(
            "a lookalike prefix is not an owner",
            AppAudioGrouping.owner(of: "com.google.ChromeRemote", among: apps) == "com.google.ChromeRemote")
        check(
            "an unknown process stands alone",
            AppAudioGrouping.owner(of: "com.apple.WebKit.GPU", among: apps) == "com.apple.WebKit.GPU")

        let groups = AppAudioGrouping.groups(
            [
                process(1, "com.google.Chrome.helper", playing: false),
                process(2, "com.google.Chrome.helper.Renderer"),
                process(3, "com.spotify.client", playing: false),
                process(4, "com.apple.Music", playing: false),
                process(5, "com.bestcast.app.dev"),
                process(6, ""),
            ],
            apps: apps, adjusted: ["com.spotify.client"], excluding: "com.bestcast.app.dev")
        check(
            "rows are playing or adjusted apps, never our own or a nameless process",
            groups.map(\.appID) == ["com.google.Chrome", "com.spotify.client"])
        check("a row taps every process of its app", groups.first?.processes.map(\.objectID) == [1, 2])

        let ring = AudioSampleRing(channels: 1, capacity: 64, maximumLag: 32)
        let ramp: [Float] = [0, 10, 20, 30, 40, 50]
        ring.write(ramp, frames: ramp.count, sourceChannels: 1)
        var out = [Float](repeating: -1, count: 4)
        ring.read(into: &out, frames: 2, outputChannels: 2, gain: 0.5, step: 1.5)
        check("a faster output interpolates between frames, at the gain, in stereo", out == [0, 0, 7.5, 7.5])
        ring.read(into: &out, frames: 2, outputChannels: 2, gain: 1, step: 1.5)
        check("the next read resumes between frames", out == [30, 30, 45, 45])
        ring.read(into: &out, frames: 2, outputChannels: 2, gain: 1, step: 1.5)
        check("a reader caught up plays silence, not stale frames", out == [0, 0, 0, 0])

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
