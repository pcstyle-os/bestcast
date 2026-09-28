import AppKit
import SwiftUI

/// Focusable only to start a recording. See docs/features/hotkeys.md#recorder.
struct ShortcutRecorder: View {
    let action: HotKeyAction
    /// Drops the empty well's fill: a column of identical pills reads louder than its rows.
    var isQuiet = false

    @Environment(HotKeyManager.self) private var hotKeys
    /// Observed so a modifier-only binding surfaces its warning when the grant changes.
    private var modifierTapMonitor: ModifierTapMonitor { hotKeys.modifierTapMonitor }
    @State private var hovered = false

    private var isRecording: Bool { hotKeys.recordingAction == action }

    /// Sits back a shade until pointed at, without reading as something you cannot press.
    private var unsetInk: Color {
        isRecording || !isQuiet || hovered
            ? Theme.Colors.textSecondary : Theme.Colors.textTertiary
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous)
        // The width is kept either way, so a column of recorders stays aligned as they fill in.
        let showsFill = !isQuiet || isRecording || hovered || hotKeys.binding(for: action) != nil
        content
            .padding(.horizontal, Theme.Spacing.sm + 1)
            .frame(width: Theme.Size.shortcutRecorder, height: 24)
            .background(shape.fill(Theme.Colors.cardFill).opacity(showsFill ? 1 : 0))
            .background {
                if isRecording { ShortcutRecorderHitRegion(capture: hotKeys.capture) }
            }
            .overlay(shape.strokeBorder(Theme.Colors.cardStroke, lineWidth: 1))
            // An over-long binding truncates rather than resizing the field.
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture(perform: toggleRecording)
            // Only under Keyboard Navigation, as a button is; recording still runs on the monitors.
            .focusable(interactions: .activate)
            .contentShape(.focusEffect, shape)
            .onKeyPress(keys: [.space, .return]) { _ in
                toggleRecording()
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard hotKeys.binding(for: action) != nil else { return .ignored }
                hotKeys.setBinding(nil, for: action)
                return .handled
            }
            .onHover { hovered = $0 }
            // Hand the callout this field's bounds while it's the open one.
            .anchorPreference(key: ShortcutRecorderAnchorKey.self, value: .bounds) {
                isRecording ? $0 : nil
            }
            // Rows are lazy: a recording row scrolled away must release the session.
            .onDisappear { if isRecording { hotKeys.recordingAction = nil } }
            // A reused table row can hand this field another action while the old one records.
            .onChange(of: action) { old, new in
                if hotKeys.recordingAction == old { hotKeys.recordingAction = nil }
                hotKeys.retryRegistration(for: new)
            }
            // Opening Settings is when the reader looks, so a chord freed since then goes live.
            .onAppear { hotKeys.retryRegistration(for: action) }
            .animation(.easeOut(duration: 0.12), value: hovered)
            // One element: the triangle and the hover-only clear button become its named actions.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(hotKeys.displayName(of: action)) Hotkey")
            .accessibilityValue(spokenValue)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggleRecording() }
            .accessibilityActions {
                if hotKeys.registrationIssue(for: action) != nil {
                    Button("Retry Hotkey") { hotKeys.retryRegistration(for: action) }
                }
                if needsAccessibilityGrant {
                    Button("Open Accessibility Settings") { Permissions.openAccessibilitySettings() }
                }
                if hotKeys.binding(for: action) != nil {
                    Button("Clear Hotkey") { hotKeys.setBinding(nil, for: action) }
                }
            }
    }

    private func toggleRecording() {
        hotKeys.recordingAction = isRecording ? nil : action
    }

    private var needsAccessibilityGrant: Bool {
        hotKeys.binding(for: action)?.usesModifierTapMonitor == true
            && modifierTapMonitor.needsAccessibility
    }

    /// The binding in words, then whatever keeps it from firing — what the triangle's tooltip says.
    private var spokenValue: String {
        if isRecording { return "Listening" }
        guard let binding = hotKeys.binding(for: action) else { return "Not set" }
        let keys = Self.spokenName(of: binding)
        if needsAccessibilityGrant {
            return "\(keys). Modifier-only hotkeys need Accessibility access."
        }
        guard let issue = hotKeys.registrationIssue(for: action) else { return keys }
        return "\(keys). \(issue.message)"
    }

    private static func spokenName(of binding: HotKeyBinding) -> String {
        switch binding {
        case .combo(let shortcut): KeyCapChip.spokenChord(shortcut.keycaps)
        case .doubleTap(let modifier): "Double-tap " + KeyCapChip.spokenChord([modifier.glyph])
        case .globe: "Globe"
        case .doubleGlobe: "Double-tap Globe"
        }
    }

    @ViewBuilder
    private var content: some View {
        if let binding = hotKeys.binding(for: action) {
            boundLabel(binding)
        } else {
            Text(isRecording ? "Listening…" : "Record Hotkey")
                .font(Theme.Typography.keyCap)
                .foregroundStyle(unsetInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func boundLabel(_ binding: HotKeyBinding) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            // A modifier-only binding is dead without the grant, so say so where the binding is.
            if needsAccessibilityGrant {
                Button {
                    Permissions.openAccessibilitySettings()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Modifier-only hotkeys need Accessibility access. Click to grant it.")
            } else if let issue = hotKeys.registrationIssue(for: action) {
                Button {
                    hotKeys.retryRegistration(for: action)
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(issue.message)
            }
            ForEach(Array(binding.keycaps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(Theme.Typography.keyCap)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(
                        minWidth: Theme.Size.recorderKeyCap, minHeight: Theme.Size.recorderKeyCap
                    )
                    .background(
                        RoundedRectangle(
                            cornerRadius: Theme.Radius.recorderKeyCap, style: .continuous
                        )
                        .fill(Color.primary.opacity(0.08))
                    )
            }
        }
        .frame(maxWidth: .infinity)
        // Overlaid, not a row member, so it costs the caps no width.
        .overlay(alignment: .trailing) {
            Button {
                hotKeys.setBinding(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
        }
    }
}

/// Where a click keeps the recording going; anywhere else, the session's mouse monitor ends it.
struct ShortcutRecorderHitRegion: NSViewRepresentable {
    let capture: ShortcutCaptureSession

    func makeNSView(context: Context) -> PassiveView {
        let view = PassiveView()
        view.capture = capture
        capture.setActiveRecorderView(view)
        return view
    }

    func updateNSView(_ view: PassiveView, context: Context) {
        if view.capture !== capture { view.capture?.clearActiveRecorderView(view) }
        view.capture = capture
        capture.setActiveRecorderView(view)
    }

    static func dismantleNSView(_ view: PassiveView, coordinator: ()) {
        view.capture?.clearActiveRecorderView(view)
    }

    final class PassiveView: NSView {
        weak var capture: ShortcutCaptureSession?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
