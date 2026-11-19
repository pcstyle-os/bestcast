# Input sources per app

Switches the keyboard input source as apps come to the front: English in Ghostty and Zed, Polish in
Messages and Discord. Set in Settings → General → Input Sources, separately from the launcher's own
"Keyboard input source", which only lasts while the palette is open.

## Invariants

- **The decision is `AppInputSourcePolicy`'s, pure and Foundation-only** for `input-source-test`. The
  controller only feeds it activations and the current source, and selects what it returns.
- **A rule beats memory.** An app with its own source always gets it, however it was left, and is never
  written into the memory.
- **Bestcast's own windows are skipped.** Activating Settings neither records nor switches, so the app
  behind it stays the one the next activation is measured against.
- **Nothing observes activations while the feature is idle**: no rules and "Keep current".

## How it decides

Two settings, `appInputSourceRules` (an app → source list) and `appInputSourceFallback` for every other
app: **Keep current** leaves the source alone, **Remember last used** gives each app back the source it
was last left in. The memory is recorded at the moment another app activates — the source still
selected then is the one the departing app was using, including one picked by hand inside it — and
lives under its own `UserDefaults` key, `appInputSourceMemory`, because it is state, not a preference.

`AppInputSourceController` listens to `NSWorkspace.didActivateApplicationNotification` and selects
through `InputSourceSwitcher.select(sourceID:)`, which looks the ID up among the enabled keyboard
sources and quietly does nothing for one removed since. A source switched away from by another app or
by macOS' own per-document setting is not fought: the policy only acts on an activation.

Both settings are in `settings.json` as `general.inputSourcePerApp` — a list of
`{"app": bundle ID, "source": input source ID}` — and `general.inputSourceOtherApps`, `"keep"` or
`"remember"`. Neither travels in a backup: they name sources installed on this Mac, the same reason
`autoSwitchInputSource` stays out.
