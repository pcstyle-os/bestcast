import SwiftUI

/// What the chat is reading from, how far indexing has got, and the way to stop or drop it.
struct ChatLibraryBar: View {
    @Environment(\.metrics) private var metrics
    let library: ChatLibraryState
    let onStop: () -> Void
    let onReindex: () -> Void
    let onRemove: () -> Void

    private var names: String {
        ListFormatter.localizedString(byJoining: library.roots.map(\.lastPathComponent))
    }

    private var status: String {
        switch library.phase {
        case .empty: return ""
        case .indexing(let progress): return progress.summary
        case .failed(let message): return message
        case .ready:
            guard let summary = library.summary else { return "" }
            var parts = [
                "\(summary.files.formatted()) \(summary.files == 1 ? "file" : "files")",
                "\(summary.passages.formatted()) passages"
            ]
            if summary.skipped > 0 { parts.append("\(summary.skipped.formatted()) skipped") }
            if summary.isTruncated { parts.append("limit reached") }
            if summary.isLexical { parts.append("word match only") }
            return parts.joined(separator: " · ")
        }
    }

    private var isFailed: Bool {
        if case .failed = library.phase { return true }
        return false
    }

    var body: some View {
        HStack(spacing: metrics.spacing.md) {
            Image(systemName: isFailed ? "exclamationmark.triangle" : "books.vertical")
                .font(metrics.typography.chip)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(names)
                    .font(metrics.typography.chip)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status)
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(2)
                if case .indexing(let progress) = library.phase {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Chatting with \(names). \(status)")
            if library.isIndexing {
                barButton("xmark.circle", "Stop Reading Files", action: onStop)
            } else {
                barButton("arrow.triangle.2.circlepath", "Reindex Files", action: onReindex)
                barButton("xmark", "Remove Files", action: onRemove)
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                .fill(Theme.Colors.controlSurface)
        )
    }

    private func barButton(
        _ symbol: String, _ title: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(metrics.typography.chip)
                .foregroundStyle(Theme.Colors.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}
