import SwiftUI

struct SnippetsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(SnippetsStore.self) private var snippetsStore
    @Environment(AppSettings.self) private var settings

    @State private var editor: SnippetEditRequest?

    var body: some View {
        @Bindable var settings = settings
        return Form {
            FeatureSwitchSection(
                anchor: .snippetsSnippets,
                enableTitle: "Enable snippets",
                enableSubtitle: "Expand templates from the launcher or by keyword.",
                // Enabling is also keyword-expansion consent, so it uses the confirming setter.
                isEnabled: Binding(
                    get: { settings.snippetsEnabled },
                    set: { core.snippetCoordinator.setSnippetsEnabled($0) }),
                showsInLauncher: $settings.snippetsShowInLauncher,
                showsIcon: true,
                showsHeader: false)

            if settings.snippetsEnabled, core.snippetListener.status == .needsAccessibility {
                Section {
                    LabeledContent {
                        Button("Grant Access…") { Permissions.openAccessibilitySettings() }
                    } label: {
                        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .frame(width: SettingsListMetrics.iconSize)
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text("Keyword expansion needs Accessibility access")
                                    .foregroundStyle(.orange)
                                Text("Launcher search still works.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Group {
                FeatureCommandsSection(owner: .snippets, anchor: .snippetsCommands)
                library
                libraryNotices
                aiSection
            }
            .settingsEnabled(settings.snippetsEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.snippets)
        .settingsEditorPanel(item: $editor) { request in
            SnippetEditorPanel(record: request.record)
        }
        .onChange(of: core.pendingSnippetEdit?.id, initial: true) { _, _ in
            guard let request = core.pendingSnippetEdit else { return }
            editor = request
            core.pendingSnippetEdit = nil
        }
    }

    private var library: some View {
        Section {
            if sortedSnippets.isEmpty {
                Text(snippetsStore.state == .loading ? "Loading snippets…" : "No snippets yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedSnippets) { record in
                    SnippetSettingsRow(
                        record: record,
                        onEdit: { editor = SnippetEditRequest(record: record) },
                        onDelete: { Task { await confirmDeletion(of: record) } })
                }
            }

            LabeledContent {
                Button("Add…") { editor = SnippetEditRequest(record: nil) }
            } label: {
                SettingsRowTitle(.snippetsLibrary, "New Snippet")
            }

            LabeledContent {
                if settings.snippetsFolder != nil {
                    Button("Use Default", action: core.snippetCoordinator.resetSnippetsFolder)
                }
                Button("Choose…", action: core.snippetCoordinator.chooseSnippetsFolder)
                Button("Open Folder", action: core.snippetCoordinator.revealSnippetsInFinder)
                    .accessibilityHint("Reveals the snippets folder in Finder.")
            } label: {
                SettingsRowTitle(.snippetsLibrary, "Snippets Folder")
                Text((snippetsStore.snippetsDirectory.path as NSString).abbreviatingWithTildeInPath)
            }
        } header: {
            SettingsSectionHeader(.snippetsLibrary)
        }
    }

    /// Enabling is consent to send prompts from any keyword, so it uses the confirming setter.
    private var aiSection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { settings.snippetAIPlaceholders },
                    set: { core.snippetCoordinator.setAIPlaceholdersEnabled($0) })
            ) {
                SettingsRowTitle(.snippetsAI, "Fill AI placeholders")
                Text(
                    settings.aiEnabled
                        ? "Expanding {ai prompt=\"…\"} sends that prompt to your default model."
                        : "Needs AI, turned on in Settings → AI.")
            }
            .settingsEnabled(settings.aiEnabled)
        } header: {
            SettingsSectionHeader(.snippetsAI)
        }
    }

    @ViewBuilder
    private var libraryNotices: some View {
        if case .failed(let message) = snippetsStore.state {
            noticeSection(
                "Couldn’t load the snippet library", message, tint: .orange,
                retryHint: "Tries to load the snippet library again.")
        }

        if !snippetsStore.issues.isEmpty {
            noticeSection(
                snippetIssueTitle, snippetIssueMessage, tint: .orange,
                retryHint: "Reloads snippet files after you fix them on disk.")
        }

        // The editor reports its own failures, so this covers the ones with no panel behind.
        if editor == nil, let operationError = snippetsStore.operationError {
            noticeSection(
                "The snippet operation failed", operationError, tint: .red, retryHint: nil)
        }
    }

    private func noticeSection(
        _ title: String, _ message: String, tint: Color, retryHint: String?
    ) -> some View {
        Section {
            LabeledContent {
                if let retryHint {
                    Button("Retry", action: snippetsStore.retry)
                        .accessibilityHint(retryHint)
                }
            } label: {
                Label(title, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(tint)
                Text(message)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var sortedSnippets: [StoredSnippet] {
        snippetsStore.snippets.sorted {
            $0.snippet.name.localizedCaseInsensitiveCompare($1.snippet.name) == .orderedAscending
        }
    }

    private var snippetIssueTitle: String {
        let count = snippetsStore.issues.count
        return count == 1
            ? "1 snippet file couldn’t be loaded" : "\(count) snippet files couldn’t be loaded"
    }

    private var snippetIssueMessage: String {
        let first = snippetsStore.issues[0]
        if snippetsStore.issues.count == 1 {
            return "\(first.fileURL.lastPathComponent): \(first.message)"
        }
        return
            "\(first.fileURL.lastPathComponent): \(first.message) Plus \(snippetsStore.issues.count - 1) more."
    }

    private func confirmDeletion(of record: StoredSnippet) async {
        guard
            await core.confirm(
                title: "Delete “\(record.snippet.name)”?",
                message: "This removes \(record.fileURL.lastPathComponent) from your snippets folder.",
                symbol: "text.quote", confirmTitle: "Delete")
        else { return }
        try? await snippetsStore.delete(id: record.id)
    }
}

struct SnippetEditRequest: Identifiable {
    let id = UUID()
    /// nil for a snippet that has no file yet.
    let record: StoredSnippet?
}

private struct SnippetSettingsRow: View {
    let record: StoredSnippet
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SettingsRow(title: record.snippet.name, subtitle: metadata) {
            Image(systemName: "doc.text")
                .font(.system(size: Theme.Size.settingsRowIcon - Theme.Spacing.xs))
                .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
        } trailing: {
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit Snippet")
            .accessibilityLabel("Edit \(record.snippet.name)")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete Snippet")
            .accessibilityLabel("Delete \(record.snippet.name)")
        }
    }

    private var metadata: String {
        let filename = record.fileURL.lastPathComponent
        guard let keyword = record.snippet.keyword?.trimmingCharacters(in: .whitespacesAndNewlines),
            !keyword.isEmpty
        else { return filename }
        return "\(keyword) · \(filename)"
    }
}

private struct SnippetEditorPanel: View {
    /// nil while adding; otherwise the record whose file (and revision) the save targets.
    let record: StoredSnippet?

    @Environment(\.settingsEditorDismiss) private var dismiss
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(SnippetsStore.self) private var store
    @Environment(ExtensionSearchCoordinator.self) private var extensionSearch
    @FocusState private var isTemplateFocused: Bool
    @FocusState private var isDescriptionFocused: Bool
    @State private var isDescribing = false
    @State private var snippetDescription = ""
    @State private var generation: Task<Void, Never>?
    /// The template before the last Generate, so Revert can put it back.
    @State private var textBeforeGeneration: String?
    @State private var name: String
    @State private var keyword: String
    @State private var text: String
    @State private var selection: TextSelection?
    @State private var isEnabled: Bool
    @State private var showsConfirmation: Bool
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(record: StoredSnippet?) {
        self.record = record
        let snippet = record?.snippet
        _name = State(initialValue: snippet?.name ?? "")
        _keyword = State(initialValue: snippet?.keyword ?? "")
        _text = State(initialValue: snippet?.text ?? "")
        _isEnabled = State(initialValue: snippet?.isEnabled ?? true)
        _showsConfirmation = State(initialValue: snippet?.showsConfirmation ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(title: record == nil ? "Add Snippet" : "Edit Snippet")

            field(
                title: "Name", placeholder: "Email Sign-off", text: $name,
                hint: "Required. Shown in the library and launcher.")
            field(
                title: "Keyword", placeholder: "Optional, for example !notes", text: $keyword,
                hint: "Optional. Type this to expand the snippet.")

            templateEditor

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                optionToggle(
                    "Enabled", isOn: $isEnabled,
                    detail: "Disabled snippets cannot be expanded.")
                optionToggle(
                    "Show confirmation", isOn: $showsConfirmation,
                    detail: "Confirm on screen after this snippet is inserted.")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Spacing.md) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.modalAction(.cancel))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .settingsEditorPanelSurface()
    }

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Template")
                    .font(.callout.weight(.medium))
                Spacer()
                if settings.aiEnabled {
                    Button("Generate with AI…", systemImage: "sparkles", action: toggleDescribing)
                        .buttonStyle(.borderless)
                        .keyboardShortcut("j", modifiers: .command)
                        .help("Generate with AI  \u{2318}J")
                        .accessibilityLabel("Generate template with AI")
                }
                placeholderMenu
            }
            if isDescribing, settings.aiEnabled {
                generator
            }
            TextEditor(text: $text, selection: $selection)
                .font(.body.monospaced())
                .settingsEditorTextArea(height: Theme.Size.editorTextHeight)
                .focused($isTemplateFocused)
                .accessibilityLabel("Snippet template")
                .accessibilityHint("Enter the text Bestcast expands.")
        }
        .onDisappear(perform: stopGenerating)
    }

    private var generator: some View {
        HStack(spacing: Theme.Spacing.md) {
            TextField("Describe the snippet, for example a polite meeting decline", text: $snippetDescription)
                .settingsEditorTextField()
                .focused($isDescriptionFocused)
                .disabled(generation != nil)
                .onSubmit(generate)
                .accessibilityLabel("Snippet description")
                .accessibilityHint("Press Return to generate a template. Command-J closes this field.")
            if generation != nil {
                ProgressView().controlSize(.small)
                Button("Stop", action: stopGenerating)
                    .accessibilityLabel("Stop generating")
            } else if let textBeforeGeneration {
                Button("Revert") {
                    text = textBeforeGeneration
                    self.textBeforeGeneration = nil
                }
                .help("Put back the template from before Generate")
            }
            Button("Generate", action: generate)
                .disabled(
                    generation != nil
                        || snippetDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty)
        }
    }

    private func toggleDescribing() {
        if isDescribing {
            closeDescribing()
        } else {
            isDescribing = true
            isDescriptionFocused = true
        }
    }

    private func closeDescribing() {
        stopGenerating()
        isDescribing = false
        isTemplateFocused = true
    }

    /// Cleared here, not when the request ends, so a route slow to cancel cannot hold the field.
    private func stopGenerating() {
        generation?.cancel()
        generation = nil
    }

    private func generate() {
        let description = snippetDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard generation == nil, !description.isEmpty else { return }
        errorMessage = nil
        generation = Task {
            do {
                let draft = try await core.snippetCoordinator.draftSnippet(describing: description)
                guard !Task.isCancelled else { return }
                generation = nil
                textBeforeGeneration = text
                text = draft
                selection = nil
                isTemplateFocused = true
            } catch {
                guard !Task.isCancelled else { return }
                generation = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Every placeholder the engine understands; parameters are in docs/features/snippets.md.
    private var placeholderMenu: some View {
        Menu("Insert…") {
            Section("Text") {
                placeholderItem("{cursor}")
                placeholderItem("{clipboard}")
                placeholderItem("{selection}")
                placeholderItem("{uuid}")
            }
            Section("Date & Time") {
                placeholderItem("{date}")
                placeholderItem("{time}")
                placeholderItem("{datetime}")
                placeholderItem("{day}")
            }
            Section("Arguments") {
                placeholderItem("{argument name=\"Name\"}")
            }
            Section("Snippets") {
                placeholderItem("{snippet name=\"Name\"}")
            }
            if settings.aiEnabled, settings.snippetAIPlaceholders {
                Section("AI") {
                    placeholderItem("{ai prompt=\"Prompt\"}")
                }
            }
            let extensionTokens = extensionSearch.placeholderTokens
            if !extensionTokens.isEmpty {
                Section("Extensions") {
                    ForEach(extensionTokens, id: \.self) { placeholderItem($0) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Insert a placeholder")
    }

    private func placeholderItem(_ token: String) -> some View {
        Button(token) { insert(token) }
    }

    /// Replaces the selection or lands at the caret; appends when there is no usable one.
    private func insert(_ token: String) {
        if let selection, case .selection(let range) = selection.indices,
            range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex
        {
            text.replaceSubrange(range, with: token)
        } else {
            text += token
        }
        // Those indices belong to the replaced string, so they must not survive the next insert.
        selection = nil
        isTemplateFocused = true
    }

    private func field(
        title: String, placeholder: String, text: Binding<String>, hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.callout.weight(.medium))
            TextField(placeholder, text: text)
                .settingsEditorTextField()
                .accessibilityLabel("Snippet \(title.lowercased())")
                .accessibilityHint(hint)
        }
    }

    private func optionToggle(
        _ title: String, isOn: Binding<Bool>, detail: String
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var draft: Snippet {
        Snippet(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            text: text,
            keyword: trimmedOrNil(keyword),
            isEnabled: isEnabled,
            showsConfirmation: showsConfirmation)
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                // Saving keeps the revision, so an edit in between conflicts, not clobbers.
                if var updated = record {
                    updated.snippet = draft
                    try await store.save(updated)
                } else {
                    try await store.create(draft)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
