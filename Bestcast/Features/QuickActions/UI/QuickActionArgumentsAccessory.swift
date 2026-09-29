import SwiftUI

/// An AI Command's `{argument}` fields in root search, keyed by the name its prompt gives each.
@MainActor
enum QuickActionArgumentsAccessory {
    /// Nil for a command whose prompt declares no argument, which is every plain transform.
    static func make(
        action: CustomQuickAction?,
        vm: PaletteState,
        metrics: InterfaceMetrics,
        focus: FocusState<String?>.Binding,
        onOpenOptions: @escaping (String) -> Void,
        onSubmit: @escaping () -> Void
    ) -> PaletteHeaderAccessory? {
        guard let action else { return nil }
        let arguments = AICommandTemplate.arguments(in: action.instructions).map {
            InlineArgument(
                id: $0.name, title: $0.name, options: $0.options, isOptional: $0.isOptional)
        }
        guard !arguments.isEmpty else { return nil }
        let value = { (name: String) in binding(action: action, name: name, vm: vm) }
        let firstOwed = {
            arguments.first { !$0.isOptional && value($0.id).wrappedValue.isEmpty }?.id
        }
        return PaletteHeaderAccessory(
            width: InlineArgumentFields.totalWidth(for: arguments, hasIcon: true, metrics: metrics),
            fieldNames: arguments.map(\.id),
            firstIncompleteField: firstOwed(),
            optionsMenu: { id in
                guard let argument = arguments.first(where: { $0.id == id }),
                    !argument.options.isEmpty
                else { return nil }
                return menu(for: argument, value: value(id))
            },
            placement: .afterQuery,
            // Identity per row, so "which fields were left unanswered" starts clean on the next one.
            view: AnyView(
                InlineArgumentFields(
                    arguments: arguments, symbol: action.symbol, value: value, focused: focus,
                    openOptions: onOpenOptions,
                    // Raycast's rule: ↵ never runs short, it moves to the required field instead.
                    onSubmit: {
                        guard let owed = firstOwed() else { return onSubmit() }
                        focus.wrappedValue = owed
                    }
                )
                .id(action.entryID))
        )
    }

    /// The typed values keyed by argument name, stripped of blanks — what the run funnel is handed.
    static func values(for action: CustomQuickAction, vm: PaletteState) -> [String: String] {
        var values: [String: String] = [:]
        for argument in AICommandTemplate.arguments(in: action.instructions) {
            let typed =
                vm.commandArguments[PaletteState.argumentKey(action.entryID, argument.name)] ?? ""
            if !typed.isEmpty { values[argument.name] = typed }
        }
        return values
    }

    private static func binding(
        action: CustomQuickAction, name: String, vm: PaletteState
    ) -> Binding<String> {
        let key = PaletteState.argumentKey(action.entryID, name)
        return Binding(get: { vm.commandArguments[key] ?? "" }, set: { vm.commandArguments[key] = $0 })
    }

    private static func menu(
        for argument: InlineArgument, value: Binding<String>
    ) -> PopoverMenuContent {
        PopoverMenuContent(
            header: argument.title,
            items: argument.options.map { option in
                PopoverMenuItem(
                    title: option,
                    icon: value.wrappedValue == option ? .symbol("checkmark") : .blank
                ) {
                    value.wrappedValue = option
                }
            })
    }
}
