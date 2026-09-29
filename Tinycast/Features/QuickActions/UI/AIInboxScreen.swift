import SwiftUI

/// Replies from AI Commands that ran by themselves: search, read, copy, continue or delete.
struct AIInboxScreen: PaletteScreen {
    let inbox: AIInboxStore
    let coordinator: AIInboxCoordinator
    let vm: PaletteState
    let openActions: () -> Void
    let metrics: InterfaceMetrics

    var rows: [AIInboxEntry] { inbox.search(vm.query) }
    let primaryActionTitle = "Copy Reply"

    private func entry(at selection: Int) -> AIInboxEntry? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func hasPrimaryAction(at selection: Int) -> Bool {
        entry(at: selection).map { $0.failure == nil } ?? false
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let entry = entry(at: selection) else { return nil }
        return AIInboxActionsMenu.content(entry: entry, coordinator: coordinator)
    }

    func spokenTitle(at selection: Int) -> String? { entry(at: selection)?.commandName }

    func activate(at selection: Int) {
        guard let entry = entry(at: selection) else { return }
        coordinator.copy(entry)
    }

    func secondary(at selection: Int) -> Bool { false }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        switch shortcut {
        case .commandDelete, .delete:
            guard let entry = entry(at: selection) else { return false }
            coordinator.delete(id: entry.id)
            return true
        case .deleteAll:
            Task { await coordinator.deleteAll() }
            return true
        case .continueInChat:
            guard let entry = entry(at: selection), entry.failure == nil else { return false }
            coordinator.openInChat(entry)
            return true
        default: return false
        }
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        let rows = rows
        if rows.isEmpty {
            EmptyResults(
                text: inbox.isAvailable
                    ? inbox.entries.isEmpty ? "No replies yet" : "No matching replies"
                    : "The AI Inbox is unavailable")
        } else {
            let selected = entry(at: selection)
            HStack(spacing: 0) {
                AIInboxList(
                    results: rows, selectedID: selected?.id, scroll: scroll,
                    onSelect: { entry in vm.selection = rows.firstIndex(of: entry) ?? 0 },
                    onActivate: { activate(at: vm.selection) },
                    onActions: { entry in
                        if let index = rows.firstIndex(of: entry) { vm.selection = index }
                        openActions()
                    }
                )
                .frame(width: metrics.size.clipboardListWidth)
                Rectangle().fill(Theme.Colors.separator).frame(width: Theme.Size.hairline)
                AIInboxPreview(entry: selected)
            }
        }
    }
}

@MainActor
enum AIInboxActionsMenu {
    static func content(
        entry: AIInboxEntry, coordinator: AIInboxCoordinator
    ) -> PopoverMenuContent {
        var items: [PopoverMenuItem] = []
        if entry.failure == nil {
            items.append(
                PopoverMenuItem(title: "Copy Reply", systemImage: "doc.on.doc", shortcut: "↵") {
                    coordinator.copy(entry)
                })
            items.append(
                PopoverMenuItem(
                    title: "Open in AI Chat", systemImage: "bubble.left.and.bubble.right",
                    shortcut: "⌘J"
                ) {
                    coordinator.openInChat(entry)
                })
        }
        items.append(
            PopoverMenuItem(
                title: "Delete Reply", systemImage: "trash", startsSection: !items.isEmpty,
                shortcut: "⌃X", isDestructive: true
            ) {
                coordinator.delete(id: entry.id)
            })
        items.append(
            PopoverMenuItem(
                title: "Delete All Replies", systemImage: "trash", shortcut: "⌃⇧X",
                isDestructive: true
            ) {
                Task { await coordinator.deleteAll() }
            })
        return PopoverMenuContent(header: entry.commandName, items: items)
    }
}

private struct AIInboxList: View {

    @Environment(\.metrics) private var metrics
    let results: [AIInboxEntry]
    let selectedID: AIInboxEntry.ID?
    let scroll: ScrollIntent
    let onSelect: (AIInboxEntry) -> Void
    let onActivate: () -> Void
    let onActions: (AIInboxEntry) -> Void

    private enum Row: Identifiable {
        case header(String)
        case entry(AIInboxEntry)

        var id: String {
            switch self {
            case .header(let title): return "header-" + title
            case .entry(let entry): return entry.id.uuidString
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var currentBucket: DateBucket?
        for entry in results {
            let bucket = DateBucket(for: entry.date)
            if bucket != currentBucket {
                rows.append(.header(bucket.title))
                currentBucket = bucket
            }
            rows.append(.entry(entry))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let title):
                            SectionHeader(title: title, isFirst: row.id == rows.first?.id)
                        case .entry(let entry):
                            AIInboxRow(entry: entry, selected: entry.id == selectedID)
                                .selectionFrame(entry.id == selectedID)
                                .contentShape(Rectangle())
                                .onTapGesture { onSelect(entry) }
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        onSelect(entry)
                                        onActivate()
                                    }
                                )
                                .onRightClick { onActions(entry) }
                                .accessibilityAction {
                                    onSelect(entry)
                                    onActivate()
                                }
                                .accessibilityAction(named: "Show Actions") { onActions(entry) }
                        }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID?.uuidString,
                atOrigin: selectedID != nil && selectedID == results.first?.id, proxy: proxy)
        }
    }
}

private struct AIInboxRow: View {

    @Environment(\.metrics) private var metrics
    let entry: AIInboxEntry
    let selected: Bool
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    private var time: String { entry.date.formatted(date: .omitted, time: .shortened) }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            RoundedRectangle(cornerRadius: metrics.radius.thumbnail, style: .continuous)
                .fill(Theme.Colors.controlSurface)
                .frame(width: metrics.size.rowIcon, height: metrics.size.rowIcon)
                .overlay(
                    Image(systemName: entry.failure == nil ? entry.symbol : "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(entry.commandName)
                    .font(metrics.typography.rowTitle)
                    .lineLimit(1)
                Text(entry.summary)
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(time)
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill)
        )
        .armedHover($hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.commandName)
        .accessibilityValue(
            [entry.failure.map { "Failed: " + $0 } ?? entry.summary, entry.cause.title, time]
                .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct AIInboxPreview: View {
    let entry: AIInboxEntry?

    var body: some View {
        if let entry {
            ChatTranscriptView(
                messages: [
                    ChatMessage(
                        id: entry.id, role: .assistant, text: entry.failure ?? entry.reply,
                        sentAt: entry.date)
                ],
                status: nil, usage: nil, surface: .palette)
        } else {
            Color.clear
        }
    }
}
