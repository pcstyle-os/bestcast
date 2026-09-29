import SwiftUI

/// The note's AI menu: pick or type an action, then keep or drop the reply it previews.
struct NoteAIView: View {
    @Environment(NotesCoordinator.self) private var notes

    private var surface: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.menuPanel, style: .continuous)
    }

    var body: some View {
        Group {
            if let session = notes.aiSession {
                NoteAISessionView(session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: surface)
        .clipShape(surface)
    }
}

private struct NoteAISessionView: View {
    @Bindable var session: NoteAISession
    @Environment(NotesCoordinator.self) private var notes
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            switch session.phase {
            case .menu:
                menu
            case .running, .preview:
                result
            case .failed(let message):
                failure(message)
            }
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI Actions")
        .onAppear(perform: focusQuery)
        .onChange(of: session.focusRevision) { _, _ in focusQuery() }
        .onKeyPress(.downArrow) {
            guard session.phase == .menu else { return .ignored }
            session.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard session.phase == .menu else { return .ignored }
            session.moveSelection(by: -1)
            return .handled
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            if session.phase == .menu {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .accessibilityHidden(true)
                TextField(placeholder, text: $session.query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit(activateSelection)
                    .accessibilityLabel(placeholder)
                    .accessibilityHint("Type to filter, or type a request for the model.")
            } else if let action = session.action {
                Image(systemName: action.symbol)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .accessibilityHidden(true)
                Text(action.title)
                    .font(Theme.Typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Spacing.md)
            }
            Text(session.target.isSelection ? "Selection" : "Whole note")
                .font(Theme.Typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textTertiary)
                .accessibilityLabel(
                    session.target.isSelection ? "Works on the selection" : "Works on the whole note")
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(height: Theme.Size.noteSearchHeight)
    }

    private var placeholder: String {
        switch session.level {
        case .root: "Ask AI to edit, or pick an action…"
        case .tones: "Change tone to…"
        case .languages: "Translate to…"
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private var menu: some View {
        let items = session.items
        if items.isEmpty {
            Text("No matching actions")
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.Size.menuRowSpacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            NoteAIMenuRow(
                                item: item, selected: index == session.selectedIndex,
                                onHover: { session.select(item) },
                                onActivate: { notes.activateAIItem(item) }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(Theme.Spacing.sm)
                }
                .overflowFade()
                .onChange(of: session.selectedIndex) { _, _ in
                    if let item = session.selectedItem { proxy.scrollTo(item.id) }
                }
            }
        }
    }

    private func activateSelection() {
        guard let item = session.selectedItem else { return }
        notes.activateAIItem(item)
    }

    // MARK: - Result

    private var result: some View {
        ScrollView {
            Group {
                if session.phase == .running, session.reply.isEmpty {
                    HStack(spacing: Theme.Spacing.md) {
                        ProgressView().controlSize(.small)
                        Text("Writing…").foregroundStyle(Theme.Colors.textSecondary)
                    }
                } else {
                    Text(rendered)
                        .lineSpacing(Theme.Spacing.xs)
                        .textSelection(.enabled)
                }
            }
            .font(Theme.Typography.rowTitle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
        }
        .overflowFade()
        .accessibilityLabel(session.phase == .running ? "Reply, still arriving" : "Suggested text")
    }

    /// One string rather than a `Text` per chunk, which would break the wrap.
    private var rendered: AttributedString {
        let chunks = session.diff
        guard !chunks.isEmpty else { return AttributedString(session.reply) }
        return chunks.reduce(into: AttributedString()) { result, chunk in
            switch chunk {
            case .equal(let text):
                result.append(AttributedString(text))
            case .inserted(let text):
                var run = AttributedString(text)
                run.foregroundColor = Theme.Colors.success
                result.append(run)
            case .deleted(let text):
                var run = AttributedString(text)
                run.foregroundColor = Theme.Colors.destructive
                run.strikethroughStyle = .single
                result.append(run)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(Theme.Typography.rowTitle)
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Theme.Spacing.xl)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: Theme.Spacing.md) {
            switch session.phase {
            case .menu:
                hint(["↑", "↓"], "Choose")
                hint(["↵"], "Run")
                Spacer(minLength: Theme.Spacing.sm)
                hint(["⎋"], session.level == .root ? "Close" : "Back")
            case .running:
                Spacer(minLength: Theme.Spacing.sm)
                hint(["⎋"], "Stop")
            case .preview:
                previewButtons
            case .failed:
                Spacer(minLength: Theme.Spacing.sm)
                Button("Back") { notes.handleAIEscape() }
                    .buttonStyle(.modalAction(.cancel, fillsWidth: false))
                    .help("Back  ⎋")
                if session.action != nil {
                    Button("Try Again", action: notes.retryAI)
                        .buttonStyle(.modalAction(.primary, fillsWidth: false))
                        .keyboardShortcut(.defaultAction)
                        .help("Try Again  ↵")
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    @ViewBuilder
    private var previewButtons: some View {
        Button("Discard") { notes.handleAIEscape() }
            .buttonStyle(.modalAction(.cancel, fillsWidth: false))
            .help("Discard  ⎋")
        Spacer(minLength: Theme.Spacing.sm)
        if let alternate = session.action?.alternatePlacement {
            Button(alternate.title) { notes.acceptAI(alternate: true) }
                .buttonStyle(.modalAction(.standard, fillsWidth: false))
                .keyboardShortcut(.return, modifiers: .command)
                .help("\(alternate.title)  ⌘↵")
        }
        if let placement = session.action?.placement {
            Button(placement.title) { notes.acceptAI(alternate: false) }
                .buttonStyle(.modalAction(.primary, fillsWidth: false))
                .keyboardShortcut(.defaultAction)
                .help("\(placement.title)  ↵")
        }
    }

    private func hint(_ caps: [String], _ label: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(caps, id: \.self) { KeyCapChip(text: $0, style: .outline, scale: .compact) }
            Text(label)
                .font(Theme.Typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(KeyCapChip.spokenChord(caps))")
    }

    private func focusQuery() {
        Task { @MainActor in
            await Task.yield()
            queryFocused = session.phase == .menu
        }
    }
}

private struct NoteAIMenuRow: View {
    let item: NoteAIMenu.Item
    let selected: Bool
    let onHover: () -> Void
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: item.symbol)
                    .font(
                        .system(
                            size: Theme.Typography.menuSymbolSize,
                            weight: Theme.Typography.menuSymbolWeight)
                    )
                    .foregroundStyle(Theme.Colors.menuSymbol)
                    .frame(width: Theme.Size.menuIcon, height: Theme.Size.menuIcon)
                Text(item.title)
                    .font(Theme.Typography.menuRow)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Spacing.sm)
                if case .open = item.command {
                    Image(systemName: "chevron.right")
                        .font(Theme.Typography.disclosure)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(
                maxWidth: .infinity, minHeight: Theme.Size.menuRowHeight,
                maxHeight: Theme.Size.menuRowHeight, alignment: .leading
            )
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.menuRow, style: .continuous)
                    .fill(selected ? Theme.Colors.menuHover : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
