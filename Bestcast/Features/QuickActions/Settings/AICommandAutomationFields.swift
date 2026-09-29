import SwiftUI

/// The editor's "Run by itself" block: a schedule, a clipboard trigger and a banner switch.
struct AICommandAutomationFields: View {
    @Environment(AppCore.self) private var core
    @Environment(AISettingsStore.self) private var aiSettings
    @Binding var automation: AICommandAutomation
    let instructions: String

    private enum Cadence: String, CaseIterable, Identifiable {
        case never, daily, weekdays, hourly, atLogin

        var id: Self { self }

        var title: String {
            switch self {
            case .never: return "Never"
            case .daily: return "Daily"
            case .weekdays: return "Weekdays"
            case .hourly: return "Every few hours"
            case .atLogin: return "At login"
            }
        }
    }

    private var cadence: Binding<Cadence> {
        Binding {
            switch automation.schedule {
            case nil: return .never
            case .daily: return .daily
            case .weekdays: return .weekdays
            case .everyHours: return .hourly
            case .atLogin: return .atLogin
            }
        } set: { cadence in
            let (hour, minute) = time
            switch cadence {
            case .never: automation.schedule = nil
            case .daily: automation.schedule = .daily(hour: hour, minute: minute)
            case .weekdays: automation.schedule = .weekdays(hour: hour, minute: minute)
            case .hourly: automation.schedule = .everyHours(hours)
            case .atLogin: automation.schedule = .atLogin
            }
        }
    }

    private var time: (hour: Int, minute: Int) {
        switch automation.schedule {
        case .daily(let hour, let minute), .weekdays(let hour, let minute): return (hour, minute)
        default: return (9, 0)
        }
    }

    private var hours: Int {
        if case .everyHours(let hours) = automation.schedule { return hours }
        return 4
    }

    private var timeOfDay: Binding<Date> {
        Binding {
            let (hour, minute) = time
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())
                ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let hour = parts.hour ?? 9
            let minute = parts.minute ?? 0
            switch automation.schedule {
            case .daily: automation.schedule = .daily(hour: hour, minute: minute)
            case .weekdays: automation.schedule = .weekdays(hour: hour, minute: minute)
            default: break
            }
        }
    }

    private var hoursBinding: Binding<Int> {
        Binding { hours } set: { automation.schedule = .everyHours($0) }
    }

    private var pattern: Binding<String> {
        Binding { automation.clipboardPattern ?? "" } set: {
            automation.clipboardPattern = $0.isEmpty ? nil : $0
        }
    }

    private var notifies: Binding<Bool> {
        Binding { automation.notifies } set: { on in
            automation.notifies = on
            guard on else { return }
            Task {
                guard await !core.aiInboxCoordinator.requestNotificationPermission() else { return }
                automation.notifies = false
                core.showMessage(
                    "Allow Bestcast's notifications in System Settings first", tone: .danger)
            }
        }
    }

    private var blocker: String? {
        automation.isEmpty ? nil : AICommandSchedulePolicy.backgroundBlocker(for: instructions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Run by itself")
                .font(.callout.weight(.medium))
            HStack(spacing: Theme.Spacing.lg) {
                Picker("Schedule", selection: cadence) {
                    ForEach(Cadence.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                switch cadence.wrappedValue {
                case .daily, .weekdays:
                    DatePicker("At", selection: timeOfDay, displayedComponents: .hourAndMinute)
                        .fixedSize()
                        .accessibilityLabel("Run at")
                case .hourly:
                    Stepper(value: hoursBinding, in: 1...24) {
                        Text(hours == 1 ? "Every hour" : "Every \(hours) hours")
                            .monospacedDigit()
                    }
                    .fixedSize()
                    .accessibilityValue(hours == 1 ? "Every hour" : "Every \(hours) hours")
                case .never, .atLogin:
                    EmptyView()
                }
            }
            TextField("On copy matching regex, e.g. ^https://github\\.com/", text: pattern)
                .settingsEditorTextField()
                .accessibilityLabel("Clipboard trigger pattern")
            Toggle("Show a notification when a reply lands", isOn: notifies)
                .disabled(automation.isEmpty)
            Text(caption)
                .font(.caption)
                .foregroundStyle(captionStyle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var captionStyle: AnyShapeStyle {
        blocker == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.Colors.destructive)
    }

    private var caption: String {
        if let blocker { return blocker }
        if !aiSettings.scheduledCommandsEnabled {
            return "Scheduled Commands are off in Settings → AI, so none of this runs yet."
        }
        return "Replies land in the AI Inbox. A copy that matches is read as {clipboard}; "
            + "missed runs catch up once."
    }
}
