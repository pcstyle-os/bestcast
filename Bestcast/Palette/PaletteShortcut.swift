import Foundation

/// A chord aimed at the selected row. The palette recognises it; the screen decides what it does.
enum PaletteShortcut: Equatable {
    /// ⌘⌫ or ⌘⌦.
    case commandDelete
    /// ⌃X.
    case delete
    /// ⌃⇧X.
    case deleteAll
    /// ⇧⌘C: the file, or where a row has none, the deeplink that runs it.
    case copyFile
    /// ⌥⌘C.
    case copyName
    /// ⇧⌘B.
    case copyBundleID
    /// ⌃⌘C.
    case copyPath
    /// ⇧⌘T.
    case copyText
    /// ⇧⌘A, marking a clip for Paste Sequentially.
    case togglePasteQueue
    /// ⇧⌘↵, matched by the Return handler rather than `resolve`.
    case copyCalculation
    /// ⇧⌘V.
    case pasteFile
    /// ⌘Y.
    case quickLook
    /// ⇧⌘F.
    case toggleFavorite
    /// ⇧⌘H.
    case hideFromSearch
    /// ⇧⌘D, which unlike a hide also silences the row's hotkey.
    case disableCommand
    /// ⇧⌘,, the Settings pane that lists the highlighted row.
    case configureCommand
    /// ⌥⌘R.
    case recordHotKey
    /// ⌥⌘A.
    case editAlias
    /// ⌃⇧Q.
    case quit
    /// ⌘R.
    case restart
    /// ⌘N, a new one of whatever the screen holds.
    case newItem
    /// ⌥⌘,, the screen's own settings; ⌘, alone stays the app's.
    case settings
    /// ⌘J, Quick AI handing its conversation to the AI Chat window.
    case continueInChat
    /// ⇧⌘S, Quick AI staging the selected text of the app the palette covered.
    case attachSelection
    /// ⌘O, Quick AI's file and folder picker.
    case attachFiles
    /// ⌘., which AppKit binds to `cancelOperation:`, so it arrives as a token instead of a key.
    case pin
    /// ⌘1…⌘0, matched by key code in the panel and handed over as a slot.
    case favoriteSlot(Int)

    /// `matches` compares the pressed key through the active layout, so the letters stay positional.
    static func resolve(
        command: Bool, shift: Bool, option: Bool, control: Bool, isDeleteKey: Bool,
        matches: (Character) -> Bool
    ) -> Self? {
        if isDeleteKey { return command ? .commandDelete : nil }
        if command, matches("c") {
            if shift { return .copyFile }
            if option { return .copyName }
            return control ? .copyPath : nil
        }
        if command, shift, matches("v") { return .pasteFile }
        if command, shift, matches("t") { return .copyText }
        if command, shift, matches("a") { return .togglePasteQueue }
        if command, option, matches("a") { return .editAlias }
        if command, shift, matches("b") { return .copyBundleID }
        if command, matches("y") { return .quickLook }
        if control, matches("x") { return shift ? .deleteAll : .delete }
        if command, shift, matches("f") { return .toggleFavorite }
        if command, shift, matches("h") { return .hideFromSearch }
        if command, shift, matches("d") { return .disableCommand }
        if control, shift, matches("q") { return .quit }
        if command, option, matches("r") { return .recordHotKey }
        if command, matches("r") { return .restart }
        if command, !shift, matches("n") { return .newItem }
        if command, option, matches(",") { return .settings }
        if command, shift, matches(",") { return .configureCommand }
        if command, matches("j") { return .continueInChat }
        if command, shift, matches("s") { return .attachSelection }
        if command, !shift, !option, !control, matches("o") { return .attachFiles }
        return nil
    }

    /// The compact bar shows no selection, so a chord aimed at a highlighted row waits for the list.
    var requiresExpanded: Bool {
        switch self {
        case .copyFile, .copyName, .copyBundleID, .copyPath, .copyText, .togglePasteQueue,
            .pasteFile, .quickLook, .toggleFavorite, .hideFromSearch, .disableCommand,
            .configureCommand, .recordHotKey, .editAlias, .quit, .restart:
            true
        case .commandDelete, .delete, .deleteAll, .pin, .favoriteSlot, .continueInChat, .newItem,
            .settings, .copyCalculation, .attachSelection, .attachFiles:
            false
        }
    }

    var closesMenu: Bool {
        switch self {
        case .delete, .deleteAll, .copyFile, .copyName, .copyBundleID, .copyPath, .copyText,
            .togglePasteQueue, .copyCalculation, .quickLook, .toggleFavorite, .hideFromSearch,
            .disableCommand, .configureCommand, .recordHotKey, .editAlias, .newItem, .settings,
            .attachFiles:
            true
        case .commandDelete, .pasteFile, .quit, .restart, .pin, .favoriteSlot, .continueInChat,
            .attachSelection:
            false
        }
    }
}
