import SwiftUI

/// One console window, pointed at whichever extension asked for it last.
@MainActor
@Observable
final class ExtensionConsoleWindowController {
    private(set) var extensionName: String?
    private(set) var title = ""

    @ObservationIgnored let console: ExtensionConsole
    @ObservationIgnored private let activation: ActivationPolicy
    @ObservationIgnored private lazy var window = AppWindowController(
        title: "Extension Console", contentSize: ExtensionConsoleView.initialSize,
        minimumSize: ExtensionConsoleView.minimumSize, resizable: true,
        autosaveName: "ExtensionConsoleWindow", activation: activation, closesOnEscape: true)

    init(console: ExtensionConsole, activation: ActivationPolicy) {
        self.console = console
        self.activation = activation
    }

    func show(extensionName: String, title: String) {
        self.extensionName = extensionName
        self.title = title
        window.show { ExtensionConsoleView(controller: self) }
    }
}

/// The recent log of one extension: filter by level, search, clear, copy.
struct ExtensionConsoleView: View {
    let controller: ExtensionConsoleWindowController

    static let initialSize = CGSize(width: 720, height: 440)
    static let minimumSize = CGSize(width: 480, height: 280)

    @State private var level: ExtensionConsoleLevel?
    @State private var query = ""

    private var entries: [ExtensionConsoleEntry] {
        guard let name = controller.extensionName else { return [] }
        return controller.console.buffers[name]?.filtered(level: level, query: query) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if entries.isEmpty {
                Text(query.isEmpty ? "Nothing logged yet." : "No lines match \u{201C}\(query)\u{201D}.")
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                log
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.terminalSurface)
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(controller.title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.md)
            Picker("Level", selection: $level) {
                Text("All").tag(ExtensionConsoleLevel?.none)
                ForEach(ExtensionConsoleLevel.allCases) { level in
                    Text(level.title).tag(Optional(level))
                }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .pointerStyle(.horizontalText)
                .frame(width: 180)
            Button("Copy") { Paster.copyPlainText(ExtensionConsoleBuffer.text(of: entries)) }
                .disabled(entries.isEmpty)
            Button("Clear") {
                if let name = controller.extensionName { controller.console.clear(name) }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ForEach(entries) { entry in
                        row(entry).id(entry.id)
                    }
                }
                .padding(Theme.Spacing.xl)
                .textSelection(.enabled)
            }
            .onChange(of: entries.last?.id, initial: true) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private func row(_ entry: ExtensionConsoleEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.textTertiary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(entry.message)
                    .foregroundStyle(tint(entry.level))
                if let stack = entry.stack {
                    Text(stack)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.Typography.code)
    }

    private func tint(_ level: ExtensionConsoleLevel) -> Color {
        switch level {
        case .log: Theme.Colors.textPrimary
        case .warn: Theme.Colors.warning
        case .error: Theme.Colors.destructive
        case .timing: Theme.Colors.textSecondary
        }
    }
}
