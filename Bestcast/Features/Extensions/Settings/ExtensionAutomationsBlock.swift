import SwiftUI

/// One extension's triggers, each off until turned on here, and the extensions allowed to call it.
struct ExtensionAutomationsBlock: View {
    let installed: InstalledExtension
    @Environment(AppCore.self) private var core

    private var name: String { installed.manifest.name }

    var body: some View {
        let engine = core.extensions.triggers
        let triggers = installed.manifest.triggers
        let callers = engine.store.approvedCallers(extension: name)
        if !triggers.isEmpty || !callers.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Divider()
                heading("Automations")
                ForEach(triggers) { trigger in
                    TriggerRows(installed: installed, trigger: trigger, engine: engine)
                }
                if !callers.isEmpty {
                    heading("Allowed to use this extension")
                    ForEach(Array(callers.enumerated()), id: \.offset) { _, grant in
                        row(title: "\(grant.caller) → \(grant.export)") {
                            Button("Revoke") {
                                engine.store.revoke(caller: grant.caller, extension: name, export: grant.export)
                            }
                            .accessibilityLabel("Revoke \(grant.caller)’s use of \(grant.export)")
                        }
                    }
                }
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.tertiary)
            .padding(.top, Theme.Spacing.xs)
    }

    private func row<Control: View>(title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: Theme.Spacing.lg)
            control()
        }
    }
}

/// A trigger's switch, then the consents and the shortcut or link that belong to it alone.
private struct TriggerRows: View {
    let installed: InstalledExtension
    let trigger: ExtensionTrigger
    let engine: ExtensionTriggerEngine

    private var extensionName: String { installed.manifest.name }
    private var key: String { ExtensionTriggerEngine.key(extension: extensionName, trigger: trigger.name) }

    var body: some View {
        let state = engine.store.state(extension: extensionName, trigger: trigger.name)
        let isOn = ExtensionTriggerPolicy.isOn(trigger, state: state)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(trigger.title)
                    Text(state.lastError ?? trigger.event.title)
                        .font(.caption)
                        .foregroundStyle(state.lastError == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    history(state: state, isOn: isOn)
                }
                Spacer(minLength: Theme.Spacing.lg)
                if isOn, !engine.store.isPaused, trigger.event != .selectionHotkey {
                    Button("Run Now") { engine.runNow(trigger: trigger.name, of: extensionName) }
                        .accessibilityLabel("Run \(trigger.title) now")
                }
                Toggle(
                    trigger.title,
                    isOn: Binding(
                        get: { isOn },
                        set: { value in
                            Task { await engine.setEnabled(value, trigger: trigger, of: installed) }
                        })
                )
                .labelsHidden()
            }
            if trigger.event == .clipboardChanged {
                consent(
                    "Share copied text", state: state, value: \.sharesClipboardText,
                    help: "Off, the extension learns only that something was copied, and its kind.")
            }
            if trigger.replacesSelection {
                consent(
                    "Type the result into the front app", state: state, value: \.allowsTyping,
                    help: "Replaces the selection with what the automation returns.")
            }
            if trigger.event == .selectionHotkey {
                indented {
                    Text("Shortcut")
                    Spacer(minLength: Theme.Spacing.lg)
                    ShortcutRecorder(action: .extensionTrigger(id: key))
                }
            }
            if trigger.event == .deeplink {
                indented {
                    Text("bestcast://extensions/\(key)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private func history(state: ExtensionTriggerState, isOn: Bool) -> some View {
        let next = isOn ? engine.nextRuns[key] : nil
        if state.lastRun != nil || next != nil {
            HStack(spacing: Theme.Spacing.xs) {
                if let lastRun = state.lastRun {
                    Text("Last run \(lastRun.formatted(.relative(presentation: .named)))")
                }
                if let next {
                    Text("Next \(next.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    private func consent(
        _ title: String, state: ExtensionTriggerState,
        value: WritableKeyPath<ExtensionTriggerState, Bool>, help: String
    ) -> some View {
        indented {
            Text(title)
            Spacer(minLength: Theme.Spacing.lg)
            Toggle(
                title,
                isOn: Binding(
                    get: { state[keyPath: value] },
                    set: { isOn in
                        engine.store.update(extension: extensionName, trigger: trigger.name) {
                            $0[keyPath: value] = isOn
                        }
                    })
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help(help)
        }
    }

    private func indented<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { content() }
            .padding(.leading, Theme.Spacing.lg)
    }
}
