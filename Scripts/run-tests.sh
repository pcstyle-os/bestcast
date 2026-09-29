#!/bin/bash
# The test suite. There is no XCTest target: each harness compiles the shipped sources it guards,
# so a harness that stops compiling means a decision leaked out of a pure layer. See docs/testing.md.
#
# Never join a compile and its run with `&&`: `set -e` ignores a failure in a non-final AND-OR list
# member, which is how CI reported success over a harness that had not compiled since phase 10.

set -uo pipefail

# Absolute: the workers re-enter this script after the cd, where a relative $0 would not resolve.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

BIN="${TMPDIR:-/tmp}/bestcast-harness"
mkdir -p "$BIN"

# `--exec` is the worker half: xargs re-enters here once per queued harness.
if [ "${1:-}" = "--exec" ]; then
    shift
    name=$1 opt=$2
    shift 2
    : > "$BIN/$name.running"
    trap 'rm -f "$BIN/$name.running" "$BIN/$name.time"' EXIT
    fail() {
        printf '\033[31mFAIL\033[0m  %-25s %s\n' "$name" "$1"
        : > "$BIN/$name.failed"
        exit 0
    }
    TIMEFORMAT=%1R
    if ! compiled=$( { time swiftc -swift-version 6 "$opt" "$@" "Tests/$name.swift" -o "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2>&1 ); then
        fail "did not compile"
    fi
    { time "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2> "$BIN/$name.time" &
    pid=$!
    # macOS ships no `timeout`, so the worker polls; a wedged harness must fail, not stall the suite.
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((BESTCAST_TEST_TIMEOUT * 5)) ]; then
            { pkill -KILL -P "$pid"; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            printf '\n[run-tests] killed after %ss without finishing\n' "$BESTCAST_TEST_TIMEOUT" >> "$BIN/$name.log"
            fail "timed out after ${BESTCAST_TEST_TIMEOUT}s"
        fi
        ticks=$((ticks + 1))
        sleep 0.2
    done
    wait "$pid"
    status=$?
    took=$(< "$BIN/$name.time")
    if [ "$status" -gt 128 ]; then fail "crashed (signal $((status - 128))) after ${took}s"; fi
    if [ "$status" -ne 0 ]; then fail "assertion failed after ${took}s"; fi
    printf '\033[32mok\033[0m    %-25s %5ss  \033[2m(compile %ss)\033[0m\n' "$name" "$took" "$compiled"
    exit 0
fi

QUEUE="$BIN/queue"
: > "$QUEUE"
rm -f "$BIN"/*.failed "$BIN"/*.running

failed=()
ran=0
only="${1:-}"

# `--index` merges each harness's compile command into .compile instead of running anything.
# xcodebuild never compiles the harnesses, so without this nothing in Tests/ resolves in an editor.
# The source lists below are the only copy, which is why this lives here rather than in its own script.
emit_db=0
DB="${TMPDIR:-/tmp}/bestcast-compile-db.json"
if [ "$only" = "--index" ]; then
    emit_db=1
    only=""
    printf '[' > "$DB"
fi

# run [slow] [-O] [index] <name> <source...> — queue the harness. `slow` dispatches it in the first
# wave; `index` claims editor flags for a harness that is compiled by hand rather than by the suite.
run() {
    local opt=-Onone pri=1 index_only=0
    while :; do
        case "$1" in
            slow)  pri=0; shift;;
            -O)    opt=-O; shift;;
            index) index_only=1; shift;;
            *)     break;;
        esac
    done
    local name=$1
    shift
    if [ -n "$only" ] && [ "$name" != "$only" ]; then return 0; fi
    if [ "$index_only" -eq 1 ] && [ "$emit_db" -eq 0 ]; then return 0; fi
    ran=$((ran + 1))

    # Absolute paths throughout: sourcekit-lsp resolves the command itself and does not apply
    # `directory` to relative arguments, so a relative path there silently yields no index.
    if [ "$emit_db" -eq 1 ]; then
        local sources=()
        for source in "$@" "Tests/$name.swift"; do sources+=("$PWD/$source"); done
        [ "$ran" -gt 1 ] && printf ',' >> "$DB"
        printf '{"directory":"%s","command":"swiftc -swift-version 6 -sdk %s' \
            "$PWD" "$(xcrun --show-sdk-path --sdk macosx)" >> "$DB"
        printf ' %s' "${sources[@]}" >> "$DB"
        # Claim every file under `Tests/`: the harness and any helper compiled beside it. A shipped
        # source stays unclaimed, because it would get this short command instead of the app's full
        # one and `.compile` is last-wins — but the app never compiles anything in `Tests/`.
        local claimed=""
        for source in "${sources[@]}"; do
            case "$source" in *"/Tests/"*) claimed="$claimed${claimed:+,}\"$source\"";; esac
        done
        printf '","files":[%s]}' "$claimed" >> "$DB"
        return 0
    fi

    # xargs splits the queue on whitespace, so no harness source path may contain a space.
    printf '%s %s %s %s\n' "$pri" "$name" "$opt" "$*" >> "$QUEUE"
}

L=Bestcast/Features/Launcher/Model
run slow -O fuzz-test      $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/EntryNaming.swift $L/LauncherOrder.swift \
                           $L/LauncherRankingStore.swift $L/LauncherSuggestions.swift
run file-search-test       $L/SearchRelevance.swift \
                           Bestcast/Features/FileSearch/Model/*.swift
run file-search-session-test Bestcast/Platform/Signposts.swift \
                             $L/SearchRelevance.swift \
                             Bestcast/Features/FileSearch/Model/*.swift \
                             Bestcast/Features/FileSearch/Service/*.swift
run menu-search-test       $L/SearchRelevance.swift \
                           Bestcast/Features/MenuSearch/Model/*.swift \
                           Bestcast/Features/MenuSearch/Service/*.swift
run window-switch-test     $L/SearchRelevance.swift \
                           Bestcast/Features/WindowSwitcher/Model/*.swift
run index file-search-performance Bestcast/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Bestcast/Features/FileSearch/Model/*.swift \
                           Bestcast/Features/FileSearch/Service/FileSearchService.swift
run ranking-test           $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/LauncherRankingStore.swift
run scopes-test            $L/SearchScopes.swift
run app-name-test          Bestcast/Platform/AppDisplayName.swift \
                           Bestcast/Platform/BundleLocalization.swift \
                           $L/SearchRelevance.swift
run favorites-test         $L/FavoriteSlots.swift
run launcher-actions-test  $L/LauncherDeepLink.swift $L/LauncherPins.swift
run apple-shortcut-test    Bestcast/Features/AppleShortcuts/Model/*.swift
run calc-test              Bestcast/Features/Calculator/Model/*.swift
run index calc-performance Bestcast/Features/Calculator/Model/*.swift
run calendar-test          Bestcast/Features/Calendar/Model/*.swift
run clipboard-test         Bestcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Bestcast/Features/Clipboard/Model/PasteQueue.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Bestcast/Features/Clipboard/Model/ColorValue.swift \
                           Bestcast/Features/Clipboard/Model/ColorFormat.swift \
                           Bestcast/Features/Clipboard/Model/ColorSpaces.swift
# `Q` is the URL detector a drag payload builds its link with, rather than a second one.
Q=Bestcast/Features/Quicklinks/Model/QuicklinkDestination.swift
run clipboard-search-test  Bestcast/Features/Clipboard/Model/*.swift $Q
run clipboard-text-test    Bestcast/Features/Clipboard/Model/*.swift $Q \
                           Bestcast/Features/Clipboard/Service/ClipboardTextExtractor.swift \
                           Bestcast/Features/Clipboard/Service/ClipboardTextIndexer.swift \
                           Bestcast/Features/Clipboard/Service/ClipboardTextWorker.swift \
                           Bestcast/Platform/ProcessExit.swift
run pasteboard-test        Bestcast/Platform/PasteboardFiles.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Bestcast/Features/Clipboard/Model/ColorValue.swift \
                           Bestcast/Features/Clipboard/Model/ColorFormat.swift \
                           Bestcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Bestcast/Features/Clipboard/Service/ClipboardManager.swift \
                           Bestcast/Features/Clipboard/Service/Paster.swift
run index clipboard-file-performance \
                           Bestcast/Platform/PasteboardFiles.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Bestcast/Features/Clipboard/Model/ColorValue.swift \
                           Bestcast/Features/Clipboard/Model/ColorFormat.swift \
                           Bestcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Bestcast/Features/Clipboard/Service/ClipboardManager.swift
run emoji-test             Bestcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Bestcast/Features/Emoji/Model/EmojiGridGeometry.swift \
                           Bestcast/Features/Emoji/Model/EmojiData.generated.swift
run emoji-search-test      Bestcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Bestcast/Features/Emoji/Model/EmojiData.generated.swift \
                           Bestcast/Features/Emoji/Service/EmojiIndex.swift \
                           Bestcast/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Bestcast/Features/Emoji/Service/PinnedEmojiStore.swift \
                           Bestcast/Features/Launcher/Model/SearchRelevance.swift \
                           Bestcast/Platform/AppPaths.swift Bestcast/Platform/Memo.swift
run index emoji-search-performance \
                           Bestcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Bestcast/Features/Emoji/Model/EmojiData.generated.swift \
                           Bestcast/Features/Emoji/Service/EmojiIndex.swift \
                           Bestcast/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Bestcast/Features/Launcher/Model/SearchRelevance.swift \
                           Bestcast/Platform/AppPaths.swift Bestcast/Platform/Memo.swift
run palette-selection-test Bestcast/Features/PaletteRowIndex.swift \
                           Bestcast/Features/Emoji/Model/EmojiGridGeometry.swift
run appearance-test        Bestcast/Platform/Appearance.swift \
                           Bestcast/DesignSystem/Theme.swift \
                           Bestcast/DesignSystem/InterfaceMetrics.swift \
                           Bestcast/Features/Settings/AppAppearance.swift
run interface-size-test    Bestcast/Platform/Appearance.swift \
                           Bestcast/DesignSystem/Theme.swift \
                           Bestcast/DesignSystem/InterfaceMetrics.swift \
                           Bestcast/Features/Settings/InterfaceSize.swift \
                           Bestcast/Features/Extensions/Model/ExtensionFormMetrics.swift
run palette-placement-test Bestcast/Platform/Appearance.swift \
                           Bestcast/DesignSystem/Theme.swift \
                           Bestcast/DesignSystem/InterfaceMetrics.swift \
                           Bestcast/Features/Settings/InterfaceSize.swift \
                           Bestcast/Palette/PalettePlacement.swift
run scroll-reveal-test     Bestcast/DesignSystem/Scrolling/SelectionReveal.swift
run redaction-test         Bestcast/DesignSystem/RedactedPlaceholder.swift
run keyboard-focus-test    Bestcast/DesignSystem/Interaction/KeyboardFocus.swift
run ai-instructions-test   Bestcast/Features/AI/Model/AIInstructions.swift \
                           Bestcast/Features/AI/Model/AIPreamble.swift
run hover-arming-test      Bestcast/Palette/HoverArming.swift \
                           Bestcast/Palette/PaletteState.swift \
                           Bestcast/Palette/PaletteMode.swift \
                           Bestcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Bestcast/Features/FileSearch/Model/FileSearchFilter.swift \
                           Bestcast/Features/Clipboard/Model/ColorValue.swift \
                           Bestcast/Features/Clipboard/Model/ColorFormat.swift \
                           Bestcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Bestcast/Features/Quicklinks/Model/Quicklink.swift \
                           Bestcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Bestcast/Features/CustomCommands/Model/CustomCommand.swift
run frontmost-app-test     Bestcast/Platform/FrontmostApplication.swift
run palette-escape-test    Bestcast/Palette/PaletteMode.swift \
                           Bestcast/Palette/PaletteEscapeAction.swift \
                           Bestcast/Palette/CommandEscapeTap.swift \
                           Bestcast/Features/Settings/EscapeKeyBehavior.swift \
                           Bestcast/Features/Quicklinks/Model/Quicklink.swift \
                           Bestcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Bestcast/Features/CustomCommands/Model/CustomCommand.swift
run palette-navigation-test Bestcast/Palette/PaletteState.swift \
                           Bestcast/Palette/PaletteMode.swift \
                           Bestcast/Palette/HoverArming.swift \
                           Bestcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Bestcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Bestcast/Features/FileSearch/Model/FileSearchFilter.swift \
                           Bestcast/Features/Clipboard/Model/ColorValue.swift \
                           Bestcast/Features/Clipboard/Model/ColorFormat.swift \
                           Bestcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Bestcast/Features/Quicklinks/Model/Quicklink.swift \
                           Bestcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Bestcast/Features/CustomCommands/Model/CustomCommand.swift
run palette-filter-test    Bestcast/Palette/PaletteMode.swift \
                           Bestcast/Palette/PaletteFilterAction.swift \
                           Bestcast/Features/Quicklinks/Model/Quicklink.swift \
                           Bestcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Bestcast/Features/CustomCommands/Model/CustomCommand.swift
run action-menu-search-test Bestcast/Palette/ActionMenuSearchQuery.swift \
                            Bestcast/Features/Launcher/Model/SearchRelevance.swift
run palette-shortcut-test  Bestcast/Palette/PaletteShortcut.swift
run ascii-layout-test      Bestcast/Platform/ASCIIKeyboardLayout.swift
run palette-tab-test       Bestcast/Palette/PaletteMode.swift \
                           Bestcast/Palette/PaletteTabAction.swift \
                           Bestcast/Features/Quicklinks/Model/Quicklink.swift \
                           Bestcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Bestcast/Features/CustomCommands/Model/CustomCommand.swift
run fallback-test          Bestcast/Features/Launcher/Model/Fallback.swift \
                           Bestcast/Features/Launcher/Model/CommandID.swift \
                           Bestcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Bestcast/Features/QuickActions/Model/QuickAction.swift \
                           Bestcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Bestcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Bestcast/Features/QuickActions/Model/AICommandOptions.swift \
                           Bestcast/Features/Quicklinks/Model/Quicklink.swift \
                           Bestcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Bestcast/Features/SystemActions/Model/SystemAction.swift \
                           Bestcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Bestcast/Features/Settings/SettingsTab.swift
run command-owner-test     Bestcast/Features/Launcher/Model/CommandID.swift \
                           Bestcast/Features/Settings/SettingsTab.swift \
                           Bestcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Bestcast/Features/QuickActions/Model/QuickAction.swift \
                           Bestcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Bestcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Bestcast/Features/QuickActions/Model/AICommandOptions.swift \
                           Bestcast/Features/Quicklinks/Model/Quicklink.swift \
                           Bestcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Bestcast/Features/SystemActions/Model/SystemAction.swift \
                           Bestcast/Features/WindowManagement/Model/WindowCommand.swift
run dictionary-test        Bestcast/Features/Dictionary/Model/DictionaryEntry.swift \
                           Bestcast/Features/Dictionary/Model/DictionaryMarkup.swift
run hotkey-test            Bestcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Bestcast/Features/HotKeys/Model/DoubleTapDetector.swift \
                           Bestcast/Features/HotKeys/Model/GlobeTapDetector.swift \
                           Bestcast/Features/HotKeys/Model/HotKeyBinding.swift \
                           Bestcast/Features/HotKeys/Model/HotKeySpelling.swift \
                           Bestcast/Features/HotKeys/Model/HyperKey.swift \
                           Bestcast/Features/HotKeys/Model/HyperKeyRewriter.swift \
                           Bestcast/Features/HotKeys/Model/HotKeyRegistrationIssue.swift \
                           Bestcast/Platform/ASCIIKeyboardLayout.swift \
                           Bestcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Bestcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Bestcast/Features/QuickActions/Model/QuickAction.swift \
                           Bestcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Bestcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Bestcast/Features/QuickActions/Model/AICommandOptions.swift \
                           Bestcast/Features/Launcher/Model/CommandID.swift \
                           Bestcast/Features/Quicklinks/Model/Quicklink.swift \
                           Bestcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Bestcast/Features/SystemActions/Model/SystemAction.swift \
                           Bestcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Bestcast/Features/Settings/SettingsTab.swift
run callout-test           Bestcast/Platform/Appearance.swift \
                           Bestcast/DesignSystem/Theme.swift \
                           Bestcast/DesignSystem/InterfaceMetrics.swift \
                           Bestcast/Features/HotKeys/UI/CalloutPlacement.swift
run icon-cache-test        Bestcast/Platform/Appearance.swift \
                           Bestcast/Platform/Images/IconCache.swift
run entry-icon-test        Bestcast/Platform/Appearance.swift \
                           Bestcast/Platform/Images/IconCache.swift \
                           Bestcast/Platform/Images/FileIconStamp.swift
run ext-icon-test          Bestcast/Platform/Appearance.swift \
                           Bestcast/Platform/AppDisplayName.swift \
                           Bestcast/Platform/Images/IconCache.swift \
                           Bestcast/Platform/Compression/Zlib.swift \
                           Bestcast/DesignSystem/Theme.swift \
                           Bestcast/DesignSystem/InterfaceMetrics.swift \
                           Bestcast/Features/Extensions/Model/ExtensionBootConfig.swift \
                           Bestcast/Features/Extensions/Model/ExtensionLaunchType.swift \
                           Bestcast/Features/Extensions/Model/ExtensionManifest.swift \
                           Bestcast/Features/Extensions/Model/ExtensionTrigger.swift \
                           Bestcast/Features/Extensions/Model/ExtensionTriggerSchedule.swift \
                           Bestcast/Features/Extensions/Model/ExtensionRefreshPolicy.swift \
                           Bestcast/Features/Extensions/Model/ExtensionRefreshState.swift \
                           Bestcast/Features/Extensions/Model/RenderNode.swift \
                           Bestcast/Features/Extensions/Service/ExtensionCatalog.swift \
                           Bestcast/Features/Extensions/Service/ExtensionFetcher.swift \
                           Bestcast/Platform/ProcessExit.swift \
                           Bestcast/Features/Extensions/Service/ExtensionNodeShims.swift \
                           Bestcast/Features/Extensions/Service/ExtensionOAuthKeychain.swift \
                           Bestcast/Features/Extensions/Service/ExtensionOAuthSession.swift \
                           Bestcast/Features/Extensions/Service/ExtensionRuntime.swift \
                           Bestcast/Features/Extensions/Service/ExtensionIconCache.swift \
                           Bestcast/Features/Extensions/UI/ExtensionAnimatedImage.swift \
                           Bestcast/Features/Extensions/UI/ExtensionImage.swift \
                           Bestcast/Features/Clipboard/Model/ColorValue.swift \
                           Bestcast/Features/Clipboard/Model/ColorSpaces.swift
run system-action-test     Bestcast/Features/SystemActions/Model/SystemAction.swift
run volume-test            Bestcast/Features/SystemActions/Model/VolumeLevel.swift
run window-command-test    Bestcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Bestcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Bestcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Bestcast/Features/WindowManagement/Model/WindowActionMemory.swift
run space-gesture-test     Bestcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Bestcast/Features/WindowManagement/Model/SpaceGesture.swift
run window-layout-test     Bestcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Bestcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Bestcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayout.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutStore.swift \
                           Bestcast/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Bestcast/Features/WindowManagement/Model/CustomWindowSizeStore.swift
run window-room-test       Bestcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Bestcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Bestcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayout.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Bestcast/Features/WindowManagement/Model/RoomLayoutKind.swift \
                           Bestcast/Features/WindowManagement/Model/RoomLayoutEngine.swift \
                           Bestcast/Features/WindowManagement/Model/RoomGrid.swift \
                           Bestcast/Features/WindowManagement/Model/RoomWindow.swift \
                           Bestcast/Features/WindowManagement/Model/Room.swift \
                           Bestcast/Features/WindowManagement/Model/RoomWindowMatcher.swift \
                           Bestcast/Features/WindowManagement/Model/RoomParking.swift \
                           Bestcast/Features/WindowManagement/Model/RoomPlan.swift \
                           Bestcast/Features/WindowManagement/Model/RoomArrangement.swift \
                           Bestcast/Features/WindowManagement/Model/RoomStore.swift \
                           Bestcast/Features/WindowManagement/Model/RoomMinimumSizeStore.swift \
                           Bestcast/Features/WindowManagement/Model/RoomParkingLedger.swift
run window-file-test       Bestcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Bestcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Bestcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayout.swift \
                           Bestcast/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Bestcast/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Bestcast/Features/WindowManagement/Model/Room.swift \
                           Bestcast/Features/WindowManagement/Model/RoomWindow.swift \
                           Bestcast/Features/WindowManagement/Model/RoomLayoutKind.swift \
                           Bestcast/Features/WindowManagement/Model/RoomGrid.swift \
                           Bestcast/Features/WindowManagement/Model/RoomLayoutEngine.swift \
                           Bestcast/Features/WindowManagement/Model/WindowManagementFileFormat.swift \
                           Bestcast/Features/Settings/Model/SettingsFileJSON.swift \
                           Bestcast/Features/Settings/Model/SettingsFileIdentity.swift
run custom-command-test    Bestcast/Platform/PseudoTerminal.swift \
                           Bestcast/Platform/ProcessExit.swift \
                           Bestcast/Features/CustomCommands/Model/CustomCommand.swift \
                           Bestcast/Features/CustomCommands/Model/RaycastScriptImport.swift \
                           Bestcast/Features/CustomCommands/Service/ShellCommandRunner.swift
run uninstall-test         Bestcast/Features/Uninstall/Model/UninstallTarget.swift \
                           Bestcast/Features/Uninstall/Model/UninstallSearchRoot.swift \
                           Bestcast/Features/Uninstall/Model/UninstallRules.swift \
                           Bestcast/Features/Uninstall/Model/UninstallProtection.swift \
                           Bestcast/Features/Uninstall/Model/UninstallPlan.swift
run quicklink-test         Bestcast/Features/Quicklinks/Model/Quicklink.swift \
                           Bestcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Bestcast/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Bestcast/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Bestcast/Features/Quicklinks/Model/RaycastQuicklinkImport.swift
run slow snippets-test     Bestcast/Platform/NotificationToken.swift \
                           Bestcast/Platform/HealthTicker.swift \
                           Bestcast/Platform/AccessibilityText.swift \
                           Bestcast/Features/Snippets/Model/*.swift \
                           Bestcast/Features/Snippets/Service/*.swift \
                           Bestcast/Features/TextInjection/Service/*.swift
run notes-test             Bestcast/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Bestcast/Features/Notes/Model/*.swift \
                           Bestcast/Features/Notes/Service/*.swift
run notes-editor-test      Bestcast/Platform/Signposts.swift \
                           Bestcast/Platform/Appearance.swift \
                           Bestcast/DesignSystem/Theme.swift \
                           Bestcast/DesignSystem/InterfaceMetrics.swift \
                           Bestcast/Platform/NotificationToken.swift \
                           Bestcast/Features/TextInjection/Service/InjectableTextView.swift \
                           Bestcast/Features/Notes/Model/NoteDocument.swift \
                           Bestcast/Features/Notes/Model/NoteMarkdown.swift \
                           Bestcast/Features/Notes/Model/NoteMarkdownParser.swift \
                           Bestcast/Features/Notes/Model/NoteInlineScanner.swift \
                           Bestcast/Features/Notes/Model/NoteEditPlan.swift \
                           Bestcast/Features/Notes/Model/NoteEditAction.swift \
                           Bestcast/Features/Notes/Model/NoteFormatting.swift \
                           Bestcast/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Bestcast/Features/Notes/Model/NoteRevealPolicy.swift \
                           Bestcast/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Bestcast/Features/Notes/UI/NoteBlockDecoration.swift \
                           Bestcast/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Bestcast/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Bestcast/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Bestcast/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Bestcast/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Bestcast/Features/Notes/UI/NoteTextViewEditing.swift \
                           Bestcast/Features/Notes/UI/NoteTextView.swift \
                           Bestcast/Features/Notes/UI/NoteEditorView.swift
run -O index notes-editor-performance \
                           Bestcast/Platform/Signposts.swift \
                           Bestcast/Platform/Appearance.swift \
                           Bestcast/DesignSystem/Theme.swift \
                           Bestcast/DesignSystem/InterfaceMetrics.swift \
                           Bestcast/Platform/NotificationToken.swift \
                           Bestcast/Features/TextInjection/Service/InjectableTextView.swift \
                           Bestcast/Features/Notes/Model/NoteDocument.swift \
                           Bestcast/Features/Notes/Model/NoteMarkdown.swift \
                           Bestcast/Features/Notes/Model/NoteMarkdownParser.swift \
                           Bestcast/Features/Notes/Model/NoteInlineScanner.swift \
                           Bestcast/Features/Notes/Model/NoteEditPlan.swift \
                           Bestcast/Features/Notes/Model/NoteEditAction.swift \
                           Bestcast/Features/Notes/Model/NoteFormatting.swift \
                           Bestcast/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Bestcast/Features/Notes/Model/NoteRevealPolicy.swift \
                           Bestcast/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Bestcast/Features/Notes/UI/NoteBlockDecoration.swift \
                           Bestcast/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Bestcast/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Bestcast/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Bestcast/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Bestcast/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Bestcast/Features/Notes/UI/NoteTextViewEditing.swift \
                           Bestcast/Features/Notes/UI/NoteTextView.swift \
                           Bestcast/Features/Notes/UI/NoteEditorView.swift
run slow -O raycast-test   Bestcast/Features/Backup/Model/RaycastImportError.swift \
                           Bestcast/Features/Backup/Service/RaycastDecoder.swift \
                           Bestcast/Features/Backup/Service/Scrypt.swift \
                           Bestcast/Platform/Compression/Zlib.swift
run settings-backup-test   Bestcast/Features/Settings/AppSettingsKey.swift \
                           Bestcast/Features/Backup/Model/SettingsBackupCoverage.swift
run settings-file-test     Bestcast/Features/Settings/Model/*.swift \
                           Bestcast/Features/Settings/Service/SettingsFileMonitor.swift \
                           Bestcast/Features/Settings/Service/SettingsFileRepository.swift \
                           Bestcast/Platform/AppPaths.swift
run backup-archive-test    Bestcast/Platform/AppPaths.swift \
                           Bestcast/Features/Backup/Model/BackupArchive.swift \
                           Bestcast/Features/Backup/Model/BackupBundle.swift \
                           Bestcast/Features/Backup/Model/BackupCategory.swift \
                           Bestcast/Features/Backup/Model/BackupClipboardItem.swift \
                           Bestcast/Features/Backup/Model/BackupManifest.swift \
                           Bestcast/Features/Backup/Service/BackupStaging.swift
E=Bestcast/Features/Extensions
W=Bestcast/Features/WindowManagement/Model/WindowCommand.swift
run symbols-test           $E/Service/SymbolCatalog.swift
run ext-cleanup-test       $E/Service/ExtensionCleanup.swift \
                           $E/Service/ExtensionCatalog.swift \
                           Bestcast/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionTrigger.swift \
                           $E/Model/ExtensionTriggerSchedule.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-refresh-test       $E/Model/ExtensionManifest.swift \
                           Bestcast/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-metadata-test      $E/Model/ExtensionCommandMetadata.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift
run ext-store-test         $E/Model/ExtensionRegistry.swift \
                           $E/Model/ExtensionPackageManager.swift \
                           $E/Model/ExtensionStoreResponse.swift
run ext-form-test          $E/Model/ExtensionFormMetrics.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/UI/ExtensionFormKey.swift \
                           $E/Model/ExtensionDateExpression.swift \
                           $E/UI/ExtensionListKey.swift \
                           Tests/ext-list-key-test.swift
run ext-image-size-test   $E/Model/ExtensionImageSize.swift
run ext-accessory-test     $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionStorage.swift
run slow ext-test          -parse-as-library \
                           Tests/ext-menu-bar-test.swift \
                           Tests/ext-fetch-test.swift \
                           $E/Model/ExtensionLaunchError.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionStorage.swift \
                           $E/Service/ExtensionMenuBarManager.swift \
                           $E/Model/ExtensionCommandMetadata.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift \
                           $E/UI/ExtensionMenuBarController.swift \
                           $E/UI/ExtensionMenuBarImage.swift \
                           Bestcast/Platform/Appearance.swift \
                           Bestcast/Platform/AppDisplayName.swift \
                           Bestcast/Platform/Images/IconCache.swift \
                           Bestcast/DesignSystem/Theme.swift \
                           Bestcast/DesignSystem/InterfaceMetrics.swift \
                           $E/Model/ExtensionBootConfig.swift \
                           $E/Model/ExtensionDeepLink.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/Model/ExtensionGridLayout.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionTrigger.swift \
                           $E/Model/ExtensionTriggerSchedule.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift \
                           $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Service/ExtensionFetcher.swift \
                           Bestcast/Platform/ProcessExit.swift \
                           $E/Service/ExtensionIconCache.swift \
                           $E/Service/ExtensionNodeShims.swift \
                           $E/Service/ExtensionOAuthKeychain.swift \
                           $E/Service/ExtensionOAuthSession.swift \
                           $E/Service/ExtensionRuntime.swift \
                           $E/Service/ExtensionNameResolver.swift \
                           $E/Service/ExtensionWebSocketBridge.swift \
                           $E/UI/ExtensionAnimatedImage.swift \
                           $E/UI/ExtensionImage.swift \
                           $E/UI/ExtensionScreen.swift \
                           $L/SearchRelevance.swift \
                           Bestcast/Platform/Compression/Zlib.swift \
                           Bestcast/Features/Clipboard/Model/ColorValue.swift \
                           Bestcast/Features/Clipboard/Model/ColorSpaces.swift
run settings-history-test  Bestcast/Features/Settings/SettingsTab.swift \
                           Bestcast/Features/Settings/SettingsHistory.swift \
                           Bestcast/Features/Settings/SettingsAnchor.swift \
                           Bestcast/Features/Settings/SettingsNavigationState.swift \
                           Bestcast/Features/Settings/SettingsSearchCatalog.swift \
                           $L/SearchRelevance.swift
run updates-test           Bestcast/Features/Updates/Model/*.swift \
                           Bestcast/Features/Updates/Service/BundleSignature.swift
run support-test           Bestcast/Features/Support/Model/*.swift
run ext-ai-test            Bestcast/Features/AI/Model/*.swift $W \
                           Bestcast/Features/AI/Service/AIProvider.swift \
                           $E/Model/RenderNode.swift \
                           $E/Model/ExtensionAIModelRouting.swift \
                           $E/Service/ExtensionAIBridge.swift
run ai-provider-test       Bestcast/Features/Settings/AppSettingsKey.swift \
                           Bestcast/Features/AI/Model/*.swift $W \
                           Bestcast/Features/AI/Settings/AISettingsStore.swift \
                           Bestcast/Features/AI/Settings/PassiveAISettingsStore.swift
run quick-ai-test          Bestcast/Features/Settings/AppSettingsKey.swift \
                           Bestcast/Features/AI/Model/*.swift $W \
                           Bestcast/Features/AI/Settings/AISettingsStore.swift \
                           Bestcast/Features/AI/Settings/PassiveAISettingsStore.swift
run passive-ai-test        Bestcast/Features/AI/Model/PassiveAIHeuristics.swift
run voice-input-test       Bestcast/Features/AI/Model/VoiceDictation.swift
run ai-chat-test           Bestcast/Features/AI/Model/AIRequest.swift \
                           Bestcast/Features/AI/Model/AIConnection.swift \
                           Bestcast/Features/AI/Model/AppleIntelligence.swift \
                           Bestcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Bestcast/Features/AI/Model/AIRetention.swift \
                           Bestcast/Features/AI/Model/AITool.swift \
                           Bestcast/Features/AI/Model/JSONValue.swift \
                           Bestcast/Features/AI/Model/ChatMessage.swift \
                           Bestcast/Features/AI/Model/ChatSession.swift \
                           Bestcast/Features/AI/Model/QuickAIPreset.swift \
                           Bestcast/Features/AI/Model/ChatChoices.swift \
                           Bestcast/Features/AI/Model/ChatReferences.swift \
                           Bestcast/Features/AI/Model/ChatTitle.swift \
                           Bestcast/Features/AI/Model/ChatFind.swift \
                           Bestcast/Features/AI/Model/ChatSearchSnippet.swift \
                           Bestcast/Features/AI/Model/ChatCitations.swift \
                           Bestcast/Features/AI/Model/ChatToolScope.swift \
                           Bestcast/Features/AI/Model/ChatToolAddress.swift \
                           Bestcast/Features/AI/Model/MarkdownBlock.swift \
                           Bestcast/Features/AI/Model/ChatLibraryIndex.swift \
                           Bestcast/Features/AI/Model/ChatLibraryChunkEngine.swift \
                           Bestcast/Features/AI/Model/ChatLibraryPolicy.swift \
                           Bestcast/Features/AI/Model/ModelComparison.swift \
                           Bestcast/Features/AI/Service/AIProvider.swift \
                           Bestcast/Features/AI/Service/ChatHistoryStore.swift \
                           Bestcast/Features/AI/Service/AIToolLoopProvider.swift \
                           Bestcast/Features/AI/Service/ChatLibraryScanner.swift \
                           Bestcast/Features/AI/Service/ChatEmbeddingService.swift \
                           Bestcast/Features/AI/Service/ChatLibraryRunner.swift \
                           Bestcast/Features/AI/Service/ChatLibraryStore.swift \
                           Bestcast/Features/AI/UI/AIChatState.swift \
                           Bestcast/Features/AI/UI/AIChatSurfacesState.swift \
                           Bestcast/Features/AI/UI/ChatLibraryState.swift \
                           Bestcast/Features/AI/UI/ModelComparisonState.swift \
                           Bestcast/Features/AI/UI/ChatFindState.swift
run chat-library-test     Bestcast/Features/AI/Model/AIRequest.swift \
                           Bestcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Bestcast/Features/AI/Model/AITool.swift \
                           Bestcast/Features/AI/Model/JSONValue.swift \
                           Bestcast/Features/AI/Model/ChatMessage.swift \
                           Bestcast/Features/AI/Model/ChatChoices.swift \
                           Bestcast/Features/AI/Model/ChatReferences.swift \
                           Bestcast/Features/AI/Model/ChatCitations.swift \
                           Bestcast/Features/AI/Model/ChatFind.swift \
                           Bestcast/Features/AI/Model/MarkdownBlock.swift \
                           Bestcast/Features/AI/Model/ChatLibraryIndex.swift \
                           Bestcast/Features/AI/Model/ChatLibraryChunkEngine.swift \
                           Bestcast/Features/AI/Model/ChatLibraryPolicy.swift
run model-comparison-test  Bestcast/Features/AI/Model/AIRequest.swift \
                           Bestcast/Features/AI/Model/AIConnection.swift \
                           Bestcast/Features/AI/Model/AppleIntelligence.swift \
                           Bestcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Bestcast/Features/AI/Model/AITool.swift \
                           Bestcast/Features/AI/Model/JSONValue.swift \
                           Bestcast/Features/AI/Model/ChatMessage.swift \
                           Bestcast/Features/AI/Model/ChatSession.swift \
                           Bestcast/Features/AI/Model/ChatChoices.swift \
                           Bestcast/Features/AI/Model/ModelComparison.swift
run chat-markdown-test     Bestcast/Platform/Appearance.swift \
                           Bestcast/DesignSystem/Theme.swift \
                           Bestcast/DesignSystem/InterfaceMetrics.swift \
                           Bestcast/Features/Settings/InterfaceSize.swift \
                           Bestcast/Features/AI/Model/AIRequest.swift \
                           Bestcast/Features/AI/Model/AITool.swift \
                           Bestcast/Features/AI/Model/JSONValue.swift \
                           Bestcast/Features/AI/Model/ChatMessage.swift \
                           Bestcast/Features/AI/Model/ChatChoices.swift \
                           Bestcast/Features/AI/Model/ChatReferences.swift \
                           Bestcast/Features/AI/Model/ChatCitations.swift \
                           Bestcast/Features/AI/Model/ChatFind.swift \
                           Bestcast/Features/AI/Model/MarkdownBlock.swift \
                           Bestcast/Features/AI/UI/ChatTextHighlight.swift \
                           Bestcast/Features/AI/UI/ChatMarkdownRenderer.swift
run mcp-test               Bestcast/Features/Settings/AppSettingsKey.swift \
                           Bestcast/Features/AI/Model/AIConnection.swift \
                           Bestcast/Features/AI/Model/AppleIntelligence.swift \
                           Bestcast/Features/AI/Model/AITool.swift \
                           Bestcast/Features/AI/Model/AIToolServer.swift \
                           Bestcast/Features/AI/Model/JSONValue.swift \
                           Bestcast/Features/AI/Model/BuiltInIntegration.swift \
                           Bestcast/Features/AI/Model/ChatToolAddress.swift \
                           Bestcast/Features/MCP/Model/*.swift \
                           Bestcast/Features/MCP/Settings/MCPSettingsStore.swift
run ai-tools-test          Bestcast/Features/AI/Model/*.swift $W
run ext-tools-test         Bestcast/Features/AI/Model/*.swift $W \
                           $E/Model/ExtensionToolPolicy.swift \
                           $E/Model/ExtensionManifest.swift \
                           Bestcast/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-triggers-test      $E/Model/ExtensionBootConfig.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift \
                           $E/Model/RenderNode.swift \
                           $E/Model/ExtensionDeepLink.swift \
                           $E/Model/ExtensionTrigger.swift \
                           $E/Model/ExtensionTriggerSchedule.swift \
                           $E/Model/ExtensionTriggerPolicy.swift \
                           $E/Service/ExtensionTriggerStore.swift \
                           Bestcast/Features/AI/Model/JSONValue.swift \
                           Bestcast/Platform/AppDisplayName.swift \
                           Bestcast/Platform/Compression/Zlib.swift \
                           Bestcast/Platform/ProcessExit.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Service/ExtensionFetcher.swift \
                           $E/Service/ExtensionNodeShims.swift \
                           $E/Service/ExtensionOAuthKeychain.swift \
                           $E/Service/ExtensionOAuthSession.swift \
                           $E/Service/ExtensionRuntime.swift
run -O text-diff-test     Bestcast/Features/QuickActions/Model/TextDiffEngine.swift
run index text-diff-performance Bestcast/Features/QuickActions/Model/TextDiffEngine.swift
run quick-action-test      Bestcast/Features/Settings/AppSettingsKey.swift \
                           Bestcast/Features/AI/Model/AIConnection.swift \
                           Bestcast/Features/AI/Model/AppleIntelligence.swift \
                           Bestcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Bestcast/Features/AI/Model/InstalledAI.swift \
                           Bestcast/Features/Snippets/Model/Snippet.swift \
                           Bestcast/Features/Snippets/Model/SnippetTemplateEngine.swift \
                           Bestcast/Features/QuickActions/Model/*.swift \
                           Bestcast/Features/QuickActions/Settings/QuickActionSettingsStore.swift
run ai-command-test        Bestcast/Features/Settings/AppSettingsKey.swift \
                           Bestcast/Features/AI/Model/AIConnection.swift \
                           Bestcast/Features/AI/Model/AppleIntelligence.swift \
                           Bestcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Bestcast/Features/AI/Model/InstalledAI.swift \
                           Bestcast/Features/AI/Model/AITemperaturePolicy.swift \
                           Bestcast/Features/Snippets/Model/Snippet.swift \
                           Bestcast/Features/Snippets/Model/SnippetTemplateEngine.swift \
                           Bestcast/Features/QuickActions/Model/*.swift \
                           Bestcast/Features/QuickActions/Settings/QuickActionSettingsStore.swift
run ai-schedule-test       Bestcast/Features/Settings/AppSettingsKey.swift \
                           Bestcast/Features/AI/Model/AIConnection.swift \
                           Bestcast/Features/AI/Model/AppleIntelligence.swift \
                           Bestcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Bestcast/Features/AI/Model/InstalledAI.swift \
                           Bestcast/Features/Snippets/Model/Snippet.swift \
                           Bestcast/Features/Snippets/Model/SnippetTemplateEngine.swift \
                           Bestcast/Features/QuickActions/Model/*.swift \
                           Bestcast/Features/QuickActions/Settings/QuickActionSettingsStore.swift
run apple-intelligence-test Bestcast/Features/Settings/AppSettingsKey.swift \
                           Bestcast/Features/AI/Model/*.swift $W \
                           Bestcast/Features/AI/Service/AIProvider.swift \
                           Bestcast/Features/AI/Service/AppleIntelligenceProvider.swift
run mcp-oauth-test         Bestcast/Platform/ExecutableLocator.swift \
                           Bestcast/Platform/ProcessExit.swift \
                           Bestcast/Platform/KeychainSecretStore.swift \
                           Bestcast/Features/Settings/AppSettingsKey.swift \
                           Bestcast/Features/AI/Model/AIConnection.swift \
                           Bestcast/Features/AI/Model/AppleIntelligence.swift \
                           Bestcast/Features/AI/Model/AITool.swift \
                           Bestcast/Features/AI/Model/AIToolServer.swift \
                           Bestcast/Features/AI/Model/AIStreamDecoder.swift \
                           Bestcast/Features/AI/Model/AIRequest.swift \
                           Bestcast/Features/AI/Model/JSONValue.swift \
                           Bestcast/Features/MCP/Model/*.swift \
                           Bestcast/Features/MCP/Service/*.swift
run slow mcp-stdio-test    Bestcast/Platform/ExecutableLocator.swift \
                           Bestcast/Platform/ProcessExit.swift \
                           Bestcast/Platform/KeychainSecretStore.swift \
                           Bestcast/Features/Settings/AppSettingsKey.swift \
                           Bestcast/Features/AI/Model/AIConnection.swift \
                           Bestcast/Features/AI/Model/AppleIntelligence.swift \
                           Bestcast/Features/AI/Model/AITool.swift \
                           Bestcast/Features/AI/Model/AIToolServer.swift \
                           Bestcast/Features/AI/Model/AIStreamDecoder.swift \
                           Bestcast/Features/AI/Model/AIRequest.swift \
                           Bestcast/Features/AI/Model/JSONValue.swift \
                           Bestcast/Features/MCP/Model/*.swift \
                           Bestcast/Features/MCP/Service/*.swift
run slow codex-turn-test   Bestcast/Platform/AppPaths.swift \
                           Bestcast/Features/AI/Model/*.swift $W \
                           Bestcast/Features/AI/Service/AIProvider.swift \
                           Bestcast/Features/AI/Service/ChatGPTSubscriptionManager.swift \
                           Bestcast/Features/AI/Service/CodexAppServerClient.swift \
                           Bestcast/Features/AI/Service/InstalledAIProbe.swift \
                           Bestcast/Platform/ExecutableLocator.swift \
                           Bestcast/Platform/ProcessExit.swift \
                           Bestcast/Features/AI/Service/CodexTurnRunner.swift
run installed-ai-test     Bestcast/Features/AI/Model/*.swift $W \
                          Bestcast/Features/AI/Service/AIProvider.swift \
                          Bestcast/Platform/AppPaths.swift \
                          Bestcast/Platform/ExecutableLocator.swift \
                          Bestcast/Platform/ProcessExit.swift \
                          Bestcast/Features/AI/Service/InstalledCLIProvider.swift \
                          Bestcast/Features/AI/Service/InstalledAIProbe.swift \
                          Bestcast/Features/AI/Service/InstalledAIManager.swift

if [ "$emit_db" -eq 1 ]; then
    printf ']\n' >> "$DB"
    [ -f .compile ] || echo '[]' > .compile
    node -e '
const fs = require("node:fs");
const [comp, db] = process.argv.slice(1);
const existing = JSON.parse(fs.readFileSync(comp, "utf8"));
const harnesses = JSON.parse(fs.readFileSync(db, "utf8"));
const kept = existing.filter((e) => !(e.files || []).some((f) => f.includes("/Tests/")));
fs.writeFileSync(comp, JSON.stringify([...kept, ...harnesses], null, 1));
console.log(harnesses.length + " harness entries indexed into .compile");
' .compile "$DB"
    exit 0
fi

if [ "$ran" -eq 0 ]; then
    echo "No harness named '$only'." >&2
    exit 2
fi

# `sort -s` is stable, so the slow harnesses lead and everything else keeps its declaration order.
JOBS="${BESTCAST_TEST_JOBS:-$(sysctl -n hw.ncpu)}"
export BESTCAST_TEST_TIMEOUT="${BESTCAST_TEST_TIMEOUT:-300}"
started=$SECONDS

# Numbers each result, and names what is still running whenever the output goes quiet.
report() {
    local finished=0 line asked running file
    while :; do
        asked=$SECONDS
        if IFS= read -r -t 15 line; then
            case "$line" in "dispatch "*) return "${line#dispatch }";; esac
            finished=$((finished + 1))
            printf '[%*d/%d] %s\n' "${#ran}" "$finished" "$ran" "$line"
            continue
        fi
        # Bash 3.2 returns the same status for a timeout and EOF; only EOF comes back at once.
        if [ $((SECONDS - asked)) -lt 10 ]; then return 1; fi
        running=""
        for file in "$BIN"/*.running; do
            [ -e "$file" ] && running="$running $(basename "$file" .running)"
        done
        printf '        \033[2mstill running after %ds:%s\033[0m\n' $((SECONDS - started)) "$running"
    done
}

# Without this the suite reports "all passed" whenever dispatch itself dies and no harness ran.
if ! { sort -s -k1,1n "$QUEUE" | cut -d' ' -f2- | xargs -P "$JOBS" -L1 "$SELF" --exec; echo "dispatch $?"; } | report; then
    echo "harness dispatch failed; no result below can be trusted" >&2
    exit 1
fi
elapsed=$((SECONDS - started))

# A compiler diagnostic is far longer than PIPE_BUF, so the workers log it and it is replayed here.
while read -r _ name _; do
    if [ -f "$BIN/$name.failed" ]; then failed+=("$name"); fi
done < "$QUEUE"

if [ ${#failed[@]} -gt 0 ]; then
    for name in "${failed[@]}"; do
        printf '\n\033[31m--- %s ---\033[0m\n' "$name"
        cat "$BIN/$name.log"
    done
    printf '\n\033[31mFAILED\033[0m  %d of %d harness(es) failed in %ds: %s\n' \
        "${#failed[@]}" "$ran" "$elapsed" "${failed[*]}" >&2
    exit 1
fi
printf '\n\033[32mPASSED\033[0m  All %d harness(es) passed in %ds.\n' "$ran" "$elapsed"
