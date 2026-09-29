import CoreServices
import Foundation

/// FSEvents over a set of folders, delivered as batches of changed paths.
final class ExtensionFolderWatcher {
    /// FSEvents holds a batch this long after its first event, which is the debounce.
    static let latency: TimeInterval = 0.3

    let changes: AsyncStream<Set<URL>>
    private let stream: FSEventStreamRef
    private let sink: Sink

    private final class Sink: Sendable {
        let continuation: AsyncStream<Set<URL>>.Continuation
        init(_ continuation: AsyncStream<Set<URL>>.Continuation) { self.continuation = continuation }
    }

    init?(folders: [URL]) {
        guard !folders.isEmpty else { return nil }
        let (changes, continuation) = AsyncStream.makeStream(
            of: Set<URL>.self, bufferingPolicy: .bufferingNewest(8))
        let sink = Sink(continuation)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let changed = Set(list.prefix(count).map { URL(fileURLWithPath: $0) })
            if !changed.isEmpty { sink.continuation.yield(changed) }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, folders.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
        else {
            continuation.finish()
            return nil
        }
        self.changes = changes
        self.stream = stream
        self.sink = sink
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "extension-folder-watcher"))
        FSEventStreamStart(stream)
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        sink.continuation.finish()
    }
}
