import Foundation
import PDFKit

/// Walks what a chat attached and reads each file's text; every call runs off-main.
nonisolated enum ChatLibraryScanner {
    struct Walk: Sendable {
        let files: [URL]
        /// Readable kinds passed over for size; an image or a binary is simply not a candidate.
        let skipped: Int
        let isTruncated: Bool
    }

    struct Page: Sendable {
        /// 1-based, and only a PDF has pages.
        let number: Int?
        let text: String
    }

    /// Entries looked at, files or not: attaching a home folder must not walk it for minutes.
    private static let maxVisited = 40_000

    static func files(in roots: [URL]) -> Walk {
        var files: [URL] = []
        var seen = Set<String>()
        var skipped = 0
        var visited = 0
        func consider(_ file: URL, size: Int) -> Bool {
            guard ChatLibraryPolicy.indexes(fileName: file.lastPathComponent) else { return true }
            let ceiling =
                AIAttachmentPolicy.kind(forFileName: file.lastPathComponent) == .pdf
                ? ChatLibraryPolicy.maxPDFBytes : ChatLibraryPolicy.maxTextFileBytes
            guard size <= ceiling else {
                skipped += 1
                return true
            }
            guard seen.insert(file.standardizedFileURL.path).inserted else { return true }
            files.append(file)
            return files.count < ChatLibraryPolicy.maxFiles
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        for root in roots {
            let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values?.isDirectory == true else {
                guard consider(root, size: values?.fileSize ?? 0) else {
                    return Walk(files: files, skipped: skipped, isTruncated: true)
                }
                continue
            }
            guard
                let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in walker {
                visited += 1
                if visited > maxVisited || Task.isCancelled {
                    return Walk(files: files, skipped: skipped, isTruncated: true)
                }
                let entry = try? url.resourceValues(forKeys: Set(keys))
                if entry?.isDirectory == true {
                    if ChatLibraryPolicy.skippedFolders.contains(url.lastPathComponent) {
                        walker.skipDescendants()
                    }
                    continue
                }
                guard entry?.isRegularFile == true else { continue }
                guard consider(url, size: entry?.fileSize ?? 0) else {
                    return Walk(files: files, skipped: skipped, isTruncated: true)
                }
            }
        }
        return Walk(files: files, skipped: skipped, isTruncated: false)
    }

    /// Nil when there is no text to read: a scanned PDF, a binary, or bytes that are not UTF-8.
    static func pages(of file: URL) -> [Page]? {
        if AIAttachmentPolicy.kind(forFileName: file.lastPathComponent) == .pdf {
            return autoreleasepool { pdfPages(of: file) }
        }
        guard let data = try? Data(contentsOf: file), !data.contains(0),
            let text = String(data: data, encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return [Page(number: nil, text: text)]
    }

    /// In process, unlike clipboard OCR, so each page's text layout is released before the next.
    private static func pdfPages(of file: URL) -> [Page]? {
        guard let document = PDFDocument(url: file), !document.isLocked else { return nil }
        var pages: [Page] = []
        for index in 0..<document.pageCount {
            guard !Task.isCancelled else { return nil }
            let text = autoreleasepool { document.page(at: index)?.string }
            guard let text, !text.isEmpty else { continue }
            pages.append(Page(number: index + 1, text: text))
        }
        return pages.isEmpty ? nil : pages
    }
}
