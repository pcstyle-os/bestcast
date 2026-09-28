// Standalone test for clipboard capture and paste, compiling the real sources rather than copies.
// Every case drives `NSPasteboard.withUniqueName()`: writing to `.general` would land in the
// reader's own running Tinycast as a genuine copy.
import AppKit
import UniformTypeIdentifiers

@main
@MainActor
struct PasteboardTests {
    static var failures = 0
    static var passes = 0
    static let cap = ClipboardManager.maxCapturedFiles

    static func main() {
        finderCopyReadsAsAFileNotItsName()
        everyFileFlavourIsRead()
        multipleFilesReadNewestLast()
        linksAndTextAreNotFiles()
        volatileAndMissingFilesFallThrough()
        theBatchIsCapped()
        rejectedFilesDoNotCountTowardTheCap()
        theBoundedReaderStopsAtItsLimit()
        aModernFileURLSuppressesTheLegacyFallback()
        fileEntriesWriteBackAsFiles()
        aVanishedFileWritesNothing()
        imageCaptureKeepsTheOfferedBytes()
        imagesWriteBackInTheirOwnType()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Reading
    /// One reader, every flavour: a board naming a file must never fall through to its name.
    static func everyFileFlavourIsRead() {
        withScratch { dir in
            let file = dir.appendingPathComponent("Tinycast-Settings-2026-08-20.json")
            try? Data("{}".utf8).write(to: file)

            // Finder's real shape: one item carrying the URL and the display name together.
            let item = NSPasteboardItem()
            item.setData(file.dataRepresentation, forType: .fileURL)
            item.setString(file.lastPathComponent, forType: .string)
            let single = board()
            single.writeObjects([item])
            expect(
                PasteboardFiles.urls(on: single) == [file],
                "a URL and a display name on one item reads as the file")

            // Some boards carry the URL as a string rather than as UTF-8 data.
            let asString = NSPasteboardItem()
            asString.setString(file.absoluteString, forType: .fileURL)
            let stringBoard = board()
            stringBoard.writeObjects([asString])
            expect(
                PasteboardFiles.urls(on: stringBoard) == [file],
                "and so does one carrying the URL as a string")

            // The pre-UTI flavour, still written by plenty of apps.
            let legacy = board()
            legacy.declareTypes([.init("NSFilenamesPboardType")], owner: nil)
            legacy.setPropertyList([file.path], forType: .init("NSFilenamesPboardType"))
            expect(
                PasteboardFiles.urls(on: legacy) == [file],
                "the legacy filenames flavour is read when no file URL is present")

            let text = board()
            text.declareTypes([.string], owner: nil)
            text.setString("Tinycast-Settings-2026-08-20.json", forType: .string)
            expect(
                PasteboardFiles.urls(on: text).isEmpty,
                "a bare file name is text, not a file")
        }
    }

    /// The reported bug: Finder puts the display name on `.string` beside `public.file-url`.
    static func finderCopyReadsAsAFileNotItsName() {
        withScratch { dir in
            let file = dir.appendingPathComponent("Screen Recording.mov")
            try? Data("movie".utf8).write(to: file)
            let pb = board()
            pb.declareTypes([.fileURL, .string], owner: nil)
            pb.setData(file.dataRepresentation, forType: .fileURL)
            pb.setString("Screen Recording.mov", forType: .string)

            expect(
                ClipboardManager.fileURLs(on: pb, volatileRoots: []) == [file.path],
                "a Finder copy reads as its path, never as its name")
        }
    }

    static func multipleFilesReadNewestLast() {
        withScratch { dir in
            let urls = ["a.txt", "b.txt", "c.txt"].map { name -> URL in
                let url = dir.appendingPathComponent(name)
                try? Data(name.utf8).write(to: url)
                return url
            }
            let pb = board()
            pb.writeObjects(urls as [NSURL])
            // Reversed, so inserting in order leaves the first file copied leading the history.
            expect(
                ClipboardManager.fileURLs(on: pb, volatileRoots: []) == urls.map(\.path).reversed(),
                "three files read back reversed")
        }
    }

    /// Only a real file URL counts, so a copied link stays a link.
    static func linksAndTextAreNotFiles() {
        let pb = board()
        pb.declareTypes([.string], owner: nil)
        pb.setString("https://example.com/report.pdf", forType: .string)
        expect(ClipboardManager.fileURLs(on: pb) == nil, "an http URL is not a file")

        let plain = board()
        plain.declareTypes([.string], owner: nil)
        plain.setString("just some prose", forType: .string)
        expect(ClipboardManager.fileURLs(on: plain) == nil, "and neither is prose")

        expect(ClipboardManager.fileURLs(on: board()) == nil, "an empty pasteboard reads as nil")
    }

    /// An app that stages a temp file beside better inline content must keep the inline content.
    static func volatileAndMissingFilesFallThrough() {
        let temp = URL(fileURLWithPath: "/private/tmp/tinycast-volatile-\(UUID().uuidString).png")
        try? Data("x".utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let pb = board()
        pb.writeObjects([temp as NSURL])
        expect(
            ClipboardManager.fileURLs(on: pb) == nil,
            "a file under /private/tmp is not durable, against the shipped roots")

        let gone = board()
        gone.writeObjects([URL(fileURLWithPath: "/nowhere/\(UUID().uuidString).txt") as NSURL])
        expect(ClipboardManager.fileURLs(on: gone) == nil, "and neither is one that is not there")
    }

    static func theBatchIsCapped() {
        withScratch { dir in
            let urls = (0..<40).map { index -> URL in
                let url = dir.appendingPathComponent("f\(index).txt")
                try? Data("x".utf8).write(to: url)
                return url
            }
            for legacy in [false, true] {
                for count in [1, cap - 1, cap, cap + 1, 40] {
                    let pb = fileBoard(Array(urls.prefix(count)), legacy: legacy)
                    defer { pb.releaseGlobally() }
                    expect(
                        ClipboardManager.fileURLs(on: pb, volatileRoots: [])
                            == Array(urls.prefix(min(count, cap)).map(\.path).reversed()),
                        "the first durable files stay reversed at the \(count)-file boundary (legacy: \(legacy))"
                    )
                }
            }
        }
    }

    static func rejectedFilesDoNotCountTowardTheCap() {
        withScratch { dir in
            let volatile = dir.appendingPathComponent("volatile", isDirectory: true)
            let staged = volatile.appendingPathComponent("staged.txt")
            let missing = dir.appendingPathComponent("missing.txt")
            let durableLink = dir.appendingPathComponent("durable-link")
            let volatileLink = dir.appendingPathComponent("volatile-link")
            let brokenLink = dir.appendingPathComponent("broken-link")
            let files = (0..<40).map { dir.appendingPathComponent("f\($0).txt") }
            do {
                try FileManager.default.createDirectory(at: volatile, withIntermediateDirectories: true)
                try Data("staged".utf8).write(to: staged)
                for file in files { try Data("file".utf8).write(to: file) }
                try FileManager.default.createSymbolicLink(at: durableLink, withDestinationURL: files[0])
                try FileManager.default.createSymbolicLink(at: volatileLink, withDestinationURL: staged)
                try FileManager.default.createSymbolicLink(at: brokenLink, withDestinationURL: missing)
            } catch {
                fail("cannot create file capture fixtures: \(error)")
                return
            }
            var root = volatile.resolvingSymlinksInPath().path
            if root.hasPrefix("/private/") { root.removeFirst("/private".count) }
            let rejected = [missing, staged, volatileLink, brokenLink]
            let accepted = [durableLink, files[0]] + files
            let mixed = Array(repeating: missing, count: 40) + rejected + accepted
            for legacy in [false, true] {
                let empty = fileBoard(rejected, legacy: legacy)
                defer { empty.releaseGlobally() }
                expect(
                    ClipboardManager.fileURLs(on: empty, volatileRoots: [root + "/"]) == nil,
                    "missing, volatile and broken targets fall through (legacy: \(legacy))")
                let pb = fileBoard(mixed, legacy: legacy)
                defer { pb.releaseGlobally() }
                expect(
                    ClipboardManager.fileURLs(on: pb, volatileRoots: [root + "/"])
                        == Array(accepted.prefix(cap).map(\.standardizedFileURL.path).reversed()),
                    "rejected files do not consume the cap; links and duplicates keep their order (legacy: \(legacy))"
                )
            }
        }
    }

    /// Bounding lives in the reader now, so both the limit and the predicate must stop exactly.
    static func theBoundedReaderStopsAtItsLimit() {
        let urls = (0..<100).map { URL(fileURLWithPath: "/fixture/\($0).txt") }
        let pb = fileBoard(urls, legacy: false)
        defer { pb.releaseGlobally() }
        expect(PasteboardFiles.urls(on: pb) == urls, "the attachment reader stays uncapped")
        for limit in [-1, 0, 1, cap - 1, cap, cap + 1, 100, Int.max] {
            var visited: [URL] = []
            let matched = PasteboardFiles.urls(on: pb, limit: limit) { url in
                visited.append(url)
                return true
            }
            let expected = Array(urls.prefix(max(0, limit)))
            expect(matched == expected, "a limit of \(limit) bounds the result in board order")
            expect(visited == expected, "and nothing is decoded past a limit of \(limit)")
        }
        var visited: [URL] = []
        let afterRejections = PasteboardFiles.urls(on: pb, limit: cap) { url in
            visited.append(url)
            return visited.count > 40
        }
        expect(
            afterRejections == Array(urls[40..<(40 + cap)]),
            "rejected URLs do not consume the limit")
        expect(
            visited == Array(urls.prefix(40 + cap)),
            "and every URL is tested once, with testing stopping at the limit")
    }

    /// A board naming a file in the modern flavour must never fall back, even when we reject it.
    static func aModernFileURLSuppressesTheLegacyFallback() {
        withScratch { dir in
            let legacy = dir.appendingPathComponent("legacy.txt")
            let modern = dir.appendingPathComponent("modern.txt")
            let missing = dir.appendingPathComponent("missing.txt")
            try? Data("legacy".utf8).write(to: legacy)
            try? Data("modern".utf8).write(to: modern)
            for url in [modern, missing, URL(string: "https://example.com/file")!] {
                let type = NSPasteboard.PasteboardType("NSFilenamesPboardType")
                let pb = board()
                defer { pb.releaseGlobally() }
                pb.declareTypes([type, .fileURL], owner: nil)
                pb.setPropertyList([legacy.path], forType: type)
                pb.setData(url.dataRepresentation, forType: .fileURL)

                let named = url.isFileURL ? [url] : [legacy]
                expect(
                    PasteboardFiles.urls(on: pb) == named,
                    "a modern file URL outranks the legacy paths beside it")
                var visited: [URL] = []
                let rejected = PasteboardFiles.urls(on: pb, limit: cap) { candidate in
                    visited.append(candidate)
                    return false
                }
                expect(rejected.isEmpty, "rejecting every candidate names no file")
                expect(visited == named, "and a rejected modern URL still suppresses the fallback")
                expect(
                    ClipboardManager.fileURLs(on: pb, volatileRoots: [])
                        == (url == missing ? nil : named.map(\.path)),
                    "so a missing modern file never captures the legacy path instead")
            }
        }
    }

    static func fileBoard(_ urls: [URL], legacy: Bool) -> NSPasteboard {
        let pb = board()
        if legacy {
            let type = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            pb.declareTypes([type], owner: nil)
            expect(pb.setPropertyList(urls.map(\.path), forType: type), "legacy fixture is written")
        } else {
            expect(pb.writeObjects(urls as [NSURL]), "file URL fixture is written")
        }
        return pb
    }

    // MARK: - Writing

    /// The round trip: what Finder handed us goes back out as a file, plus the path as text.
    static func fileEntriesWriteBackAsFiles() {
        withScratch { dir in
            let file = dir.appendingPathComponent("report.pdf")
            try? Data("pdf".utf8).write(to: file)
            let store = ClipboardStore(directory: dir.appendingPathComponent("store"))
            store.addFiles([file.path], sourceBundleID: nil)
            let pb = board()

            expect(Paster.write(store.items[0], store: store, to: pb), "a present file writes")
            let read = pb.readObjects(forClasses: [NSURL.self]) as? [URL]
            expect(read?.first?.path == file.path, "and reads back as the same file URL")
            expect(pb.string(forType: .string) == file.path, "with the path as text, not the name")
            expect(
                pb.types?.contains(ClipboardManager.internalType) == true,
                "marked, so the poller skips our own write")
        }
    }

    static func aVanishedFileWritesNothing() {
        withScratch { dir in
            let store = ClipboardStore(directory: dir.appendingPathComponent("store"))
            store.addFiles(["/nowhere/\(UUID().uuidString).txt"], sourceBundleID: nil)
            let pb = board()
            pb.declareTypes([.string], owner: nil)
            pb.setString("untouched", forType: .string)

            expect(!Paster.write(store.items[0], store: store, to: pb), "a vanished file refuses")
            expect(pb.string(forType: .string) == "untouched", "and leaves the pasteboard alone")
        }
    }

    // MARK: - Images

    /// A browser's TIFF+JPEG pair keeps the JPEG as sent; only a TIFF-only board is re-encoded.
    static func imageCaptureKeepsTheOfferedBytes() {
        let image = picture()
        let jpeg = encoded(image, as: .jpeg)
        let png = encoded(image, as: .png)
        let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation ?? Data()

        let browser = board(offering: [(.tiff, tiff), (jpegType, jpeg)])
        let read = ClipboardManager.image(on: browser)
        expect(read?.data == jpeg, "the JPEG is read rather than the TIFF declared before it")
        let kept = read.flatMap { ClipboardManager.storedImage($0.data, typeIdentifier: $0.typeIdentifier) }
        expect(kept?.data == jpeg && kept?.fileExtension == "jpeg", "and stored byte for byte")

        let screenshot = board(offering: [(.png, png), (.tiff, tiff)])
        expect(ClipboardManager.image(on: screenshot)?.data == png, "a PNG is kept as it came")

        let tiffOnly = board(offering: [(.tiff, tiff)])
        let converted = ClipboardManager.image(on: tiffOnly).flatMap {
            ClipboardManager.storedImage($0.data, typeIdentifier: $0.typeIdentifier)
        }
        let decoded = converted.flatMap { NSBitmapImageRep(data: $0.data) }
        expect(converted?.fileExtension == "png", "a TIFF-only board is stored as PNG")
        expect(converted.map { $0.data.count < tiff.count } == true, "which is smaller than the TIFF")
        expect(
            decoded?.pixelsWide == image.width && decoded?.pixelsHigh == image.height,
            "at the size it was copied")
        expect(decoded?.hasAlpha == true, "with its transparency")

        let again = ClipboardManager.storedImage(jpeg, typeIdentifier: jpegType.rawValue)
        expect(again?.digest == kept?.digest, "the same bytes always name the same digest")
        expect(again?.digest != converted?.digest, "and different bytes a different one")
        expect(kept?.digest.count == 32, "a 128-bit prefix, spelled in hex")
    }

    /// A blob goes back out as the type it was kept in, first; a JPEG also answers PNG and TIFF.
    static func imagesWriteBackInTheirOwnType() {
        withScratch { dir in
            let store = ClipboardStore(directory: dir.appendingPathComponent("store"))
            let image = picture()
            let jpeg = encoded(image, as: .jpeg)
            let png = encoded(image, as: .png)
            let jpegURL = store.imagesDir.appendingPathComponent("0a1b-photo.jpeg")
            let pngURL = store.imagesDir.appendingPathComponent("2c3d-shot.png")
            try? jpeg.write(to: jpegURL)
            try? png.write(to: pngURL)

            let photoBoard = board()
            let photo = ClipboardItem(imagePath: jpegURL.path, sourceBundleID: nil)
            // Drained, so the promise below is kept alive by the pasteboard and nothing of ours.
            let wrote = autoreleasepool { Paster.write(photo, store: store, to: photoBoard) }
            expect(wrote, "a JPEG blob writes")
            expect(photoBoard.types?.first == jpegType, "with the JPEG as the first type offered")
            expect(photoBoard.data(forType: jpegType) == jpeg, "as the JPEG it was kept as")
            let pngRead = photoBoard.data(forType: .png)
            expect(pngRead.map { $0.starts(with: pngSignature) } == true, "and reads as a real PNG")
            let decoded = pngRead.flatMap(NSBitmapImageRep.init(data:))
            let jpegPixels = NSBitmapImageRep(data: jpeg)
            expect(
                decoded?.pixelsWide == image.width && decoded?.pixelsHigh == image.height,
                "the PNG keeps the photo's odd size")
            expect(
                decoded?.colorAt(x: 11, y: 7) == jpegPixels?.colorAt(x: 11, y: 7)
                    && decoded?.colorAt(x: 30, y: 2) == jpegPixels?.colorAt(x: 30, y: 2),
                "and the JPEG's own pixels")
            let tiff = photoBoard.data(forType: .tiff).flatMap(NSBitmapImageRep.init(data:))
            expect(tiff?.pixelsWide == image.width, "and still reads as TIFF for readers that want one")
            expect(
                photoBoard.types?.contains(ClipboardManager.internalType) == true,
                "marked, so the poller skips our own write")

            let shotBoard = board()
            let shot = ClipboardItem(imagePath: pngURL.path, sourceBundleID: nil)
            expect(Paster.write(shot, store: store, to: shotBoard), "a PNG blob writes")
            expect(shotBoard.data(forType: .png) == png, "as itself")
            expect(shotBoard.data(forType: jpegType) == nil, "and nothing else")
        }
    }

    static let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Synthetic and uneven: odd sides, a gradient and partial alpha, so a swap or flatten shows.
    static func picture() -> CGImage {
        let width = 37
        let height = 23
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fatalError("no bitmap context") }
        for x in 0..<width {
            context.setFillColor(
                CGColor(red: CGFloat(x) / CGFloat(width), green: 0.3, blue: 0.7, alpha: 0.4))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height - x % 5))
        }
        guard let image = context.makeImage() else { fatalError("no image") }
        return image
    }

    static func encoded(_ image: CGImage, as type: UTType) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func board(offering representations: [(NSPasteboard.PasteboardType, Data)]) -> NSPasteboard {
        let pb = board()
        pb.declareTypes(representations.map { $0.0 }, owner: nil)
        for (type, data) in representations { pb.setData(data, forType: type) }
        return pb
    }

    // MARK: - Harness

    static func board() -> NSPasteboard { NSPasteboard.withUniqueName() }

    static func withScratch(_ body: (URL) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-pasteboard-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        body(dir)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            fail(message)
        }
    }

    static func fail(_ message: String) {
        failures += 1
        print("FAIL: \(message)")
    }
}

// MARK: - Stubs for what the shipped sources reach that this harness does not exercise

@MainActor
final class AppSettings {
    var clipboardDisabledApps: Set<String> = []
}

enum Permissions {
    static func ensureAccessibility() -> Bool { false }
}

final class NotificationToken {
    init(_ observer: Any, center: NotificationCenter) {}
}
