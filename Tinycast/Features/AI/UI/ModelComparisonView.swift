import SwiftUI

/// The window's comparison mode: pick two to four models, ask once, read the replies side by side.
struct ModelComparisonView: View {
    @Environment(AIChatCoordinator.self) private var coordinator
    @Environment(\.metrics) private var metrics
    let state: ModelComparisonState
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ModelComparisonComposer(state: state, coordinator: coordinator)
                .frame(maxWidth: Theme.Size.aiChatReadingWidth)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.bottom, Theme.Spacing.xxl)
                .padding(.top, Theme.Spacing.sm)
        }
        .dropDestination(for: URL.self) { files, _ in
            coordinator.attach(files: files, to: state)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .overlay {
            if isDropTargeted { ChatDropHint() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(state.comparison?.question?.text ?? "Compare Models")
                .font(metrics.typography.rowTitle.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: Theme.Spacing.xl)
            Button {
                coordinator.closeComparison()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close Comparison  esc")
            .accessibilityLabel("Close Comparison")
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.md)
    }

    @ViewBuilder private var content: some View {
        if let comparison = state.comparison {
            ModelComparisonColumns(comparison: comparison, state: state)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "rectangle.split.3x1")
                .font(.largeTitle)
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(pickSummary)
                .font(metrics.typography.rowTitle)
                .multilineTextAlignment(.center)
            Text("⌘1–⌘4 focus a column · ⌘↩ continues it as a chat · ⌘. stops them all")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            if coordinator.modelOptions.count < ModelComparison.modelLimit.lowerBound,
                !coordinator.isModelCatalogLoading
            {
                Button("Configure AI…", action: coordinator.showSettings)
            }
        }
        .padding(Theme.Spacing.xxl)
    }

    private var pickSummary: String {
        let names = state.picks.map { coordinator.modelTitle(of: $0) }
        guard !names.isEmpty else { return "Choose two to four models below, then ask once." }
        let list = names.formatted(.list(type: .and))
        return ModelComparison.canCompare(state.picks)
            ? "Ask \(list) the same question."
            : "Comparing \(list). Choose at least one more model."
    }
}

/// One card per model; below the minimum width they stop sharing the row and scroll sideways.
private struct ModelComparisonColumns: View {
    @Environment(AIChatCoordinator.self) private var coordinator
    let comparison: ModelComparison
    let state: ModelComparisonState

    var body: some View {
        let count = CGFloat(comparison.columns.count)
        let (gap, minimum) = (Theme.Spacing.lg, Theme.Size.aiComparisonColumnMinimum)
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(comparison.columns.enumerated()), id: \.element.id) { index, column in
                        ModelComparisonColumn(
                            column: column, number: index + 1,
                            title: coordinator.modelTitle(of: column.model),
                            icon: coordinator.modelIcon(of: column.model),
                            isFocused: index == comparison.focusedIndex, scrolls: true,
                            onFocus: { state.focus(index) },
                            onCopy: { coordinator.copy(column.id, in: state) },
                            onContinue: { coordinator.continueAsChat(column.id, in: state) },
                            onRetry: { coordinator.retry(column.id, in: state) })
                        .containerRelativeFrame(.horizontal) { length, _ in
                            max(minimum, (length - gap * (count - 1)) / count)
                        }
                        .id(column.id)
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
            }
            .contentMargins(.horizontal, Theme.Spacing.xxl, for: .scrollContent)
            .onChange(of: comparison.focusedIndex) { _, index in
                guard comparison.columns.indices.contains(index) else { return }
                withAnimation(.snappy) { proxy.scrollTo(comparison.columns[index].id) }
            }
        }
    }
}

/// One model's reply with its timings; the same card sits under a reply for Compare With….
struct ModelComparisonColumn: View {
    @Environment(\.metrics) private var metrics
    let column: ModelComparison.Column
    /// Its ⌘-number in the window; nil for the inline card, which has no chords.
    let number: Int?
    let title: String
    let icon: PopoverMenuIcon
    let isFocused: Bool
    /// The window's columns share its height and scroll on their own; the inline card grows.
    let scrolls: Bool
    let onFocus: () -> Void
    let onCopy: () -> Void
    let onContinue: () -> Void
    let onRetry: () -> Void
    var onClose: (() -> Void)?

    private var chords: Bool { number != nil && isFocused }
    private var isComplete: Bool { column.reply.state == .complete }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            header
            Text(stats)
                .font(metrics.typography.keyCap)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(2)
            if scrolls {
                ScrollView { reply.frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: .infinity)
            } else {
                reply
            }
            actions
        }
        .padding(metrics.spacing.lg)
        .frame(maxHeight: scrolls ? .infinity : nil, alignment: .top)
        .background(shape.fill(Theme.Colors.cardFill))
        .overlay {
            shape.strokeBorder(
                isFocused ? Theme.Colors.focusRing : Theme.Colors.cardStroke,
                lineWidth: isFocused ? Theme.Size.focusRing : 1)
        }
        .contentShape(shape)
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(number.map { "Column \($0), \(title)" } ?? "Compared with \(title)")
        .accessibilityValue(stats)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .accessibilityAction(named: "Copy Reply") { onCopy() }
        .accessibilityAction(named: "Continue as Chat") { if isComplete { onContinue() } }
        .accessibilityAction(named: "Retry") { if !column.isStreaming { onRetry() } }
    }

    private var header: some View {
        HStack(spacing: metrics.spacing.sm) {
            MenuIconImage(icon: icon)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text(title)
                .font(metrics.typography.rowTitle.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: metrics.spacing.sm)
            if let number {
                Text("⌘\(number)")
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            if let onClose {
                button("xmark", "Close Comparison", action: onClose)
            }
        }
    }

    @ViewBuilder private var reply: some View {
        let message = column.reply
        if message.text.isEmpty, message.searches.isEmpty, message.reasoning.isEmpty,
            column.isStreaming
        {
            ProgressView().controlSize(.small)
        } else {
            VStack(alignment: .leading, spacing: metrics.spacing.lg) {
                ForEach(Array(message.segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let text):
                        ChatMarkdownText(
                            blocks: MarkdownBlock.parse(ChatChoices.split(text).text),
                            failed: message.state == .failed)
                    case .search(let search):
                        ChatSearchRow(search: search)
                    case .reasoning(let block):
                        ChatReasoningBlock(
                            block: block, isThinking: column.isStreaming && block.duration == nil)
                    case .tools:
                        EmptyView()
                    }
                }
            }
            .font(metrics.typography.rowTitle)
            .foregroundStyle(message.state == .failed ? Theme.Colors.destructive : .primary)
            .lineSpacing(metrics.spacing.chatLine)
            .textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack(spacing: metrics.spacing.sm) {
            button("doc.on.doc", "Copy Reply", chord: "⇧⌘C", action: onCopy)
                .disabled(column.reply.text.isEmpty)
            button("arrow.clockwise", "Retry", chord: "⌘R", action: onRetry)
                .disabled(column.isStreaming)
            Spacer(minLength: 0)
            Button(action: onContinue) {
                Label("Continue as Chat", systemImage: "bubble.left.and.text.bubble.right")
                    .font(metrics.typography.rowTrailing)
            }
            .buttonStyle(.glass)
            .disabled(!isComplete)
            .help(chords ? "Continue as Chat  ⌘↩" : "Continue as Chat")
        }
    }

    private var stats: String {
        var parts: [String] = []
        if let first = column.timeToFirstToken { parts.append("\(seconds(first)) to first token") }
        if let total = column.totalTime {
            parts.append("\(seconds(total)) total")
        } else if column.isStreaming {
            parts.append("Streaming…")
        }
        if let usage = ChatUsageLabel.text(column.reply.usage) { parts.append(usage) }
        return parts.joined(separator: " · ")
    }

    private func seconds(_ interval: TimeInterval) -> String {
        interval.formatted(.number.precision(.fractionLength(1))) + "s"
    }

    private func button(
        _ symbol: String, _ label: String, chord: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: metrics.size.chatMessageAction, height: metrics.size.chatMessageAction)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chords ? chord.map { "\(label)  \($0)" } ?? label : label)
        .accessibilityLabel(label)
    }
}

/// Compare With…'s answer, drawn under the reply it re-asks until it is closed or continued.
struct ModelComparisonInlineCard: View {
    @Environment(AIChatCoordinator.self) private var coordinator
    let state: ModelComparisonState

    var body: some View {
        if let column = state.comparison?.columns.first {
            ModelComparisonColumn(
                column: column, number: nil, title: coordinator.modelTitle(of: column.model),
                icon: coordinator.modelIcon(of: column.model), isFocused: false, scrolls: false,
                onFocus: {},
                onCopy: { coordinator.copy(column.id, in: state) },
                onContinue: { coordinator.continueAsChat(column.id, in: state) },
                onRetry: { coordinator.retry(column.id, in: state) },
                onClose: { coordinator.closeInlineComparison() })
        }
    }
}

/// The comparison's own composer: every pick is asked the same text and the same files.
private struct ModelComparisonComposer: View {
    let state: ModelComparisonState
    let coordinator: AIChatCoordinator

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if !state.pendingAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(state.pendingAttachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                coordinator.removeAttachment(attachment.id, in: state)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            ZStack(alignment: .topLeading) {
                if state.draft.isEmpty {
                    Text("Ask every model the same thing…")
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                ChatComposerTextView(text: $state.draft, focusKey: state.id) {
                    coordinator.submitComparison(state)
                }
            }
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    coordinator.chooseFiles(for: state)
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .disabled(state.isStreaming)
                .help("Attach files every picked model can read")
                .accessibilityLabel("Attach Files")
                ModelComparisonPicker(state: state, coordinator: coordinator)
                Spacer(minLength: 0)
                sendButton
            }
        }
        .padding(Theme.Spacing.xl)
        .background {
            Color.clear.glassEffect(
                .regular, in: RoundedRectangle(cornerRadius: Theme.Radius.dialog, style: .continuous))
        }
    }

    private var sendButton: some View {
        Button {
            coordinator.submitComparison(state)
        } label: {
            Image(systemName: state.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .disabled(!state.isStreaming && !coordinator.canCompare(state))
        .help(state.isStreaming ? "Stop All  ⌘." : "Compare  ↵")
        .accessibilityLabel(state.isStreaming ? "Stop All" : "Compare")
    }
}

/// The picks as toggles, grouped as the chat's own picker groups them; frozen while asking.
private struct ModelComparisonPicker: View {
    let state: ModelComparisonState
    let coordinator: AIChatCoordinator

    var body: some View {
        let groups = coordinator.modelGroups
        Menu {
            if coordinator.isModelCatalogLoading {
                Text("Loading models…")
            }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.options) { option in
                        Toggle(
                            isOn: Binding(
                                get: { ModelComparison.isPicked(option.selection, in: state.picks) },
                                set: { _ in coordinator.togglePick(option, in: state) })
                        ) {
                            Label {
                                Text(option.title)
                            } icon: {
                                MenuIconImage(icon: option.menuIcon)
                            }
                        }
                    }
                }
            }
            if groups.isEmpty, !coordinator.isModelCatalogLoading {
                Button("Configure AI…", action: coordinator.showSettings)
            }
        } label: {
            Label(title, systemImage: "rectangle.split.3x1")
                .labelStyle(.titleAndIcon)
        }
        .composerPill()
        .disabled(state.isStreaming)
        .help("Choose 2 to 4 models to compare")
        .accessibilityLabel("Models to Compare")
        .accessibilityValue(title)
    }

    private var title: String {
        switch state.picks.count {
        case 0: "Choose Models"
        case 1: coordinator.modelTitle(of: state.picks[0])
        case let count: "\(count) Models"
        }
    }
}
