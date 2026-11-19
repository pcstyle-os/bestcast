# Keystroke overlay

Shows what you press, for screen recordings and demos. Turn it on in Settings › General › Keystroke
Overlay or with **Toggle Keystroke Overlay**; **Move Keystroke Overlay** lets you drag it anywhere.

## Invariants

- **The switch is consent to read every keystroke**, so it is off by default and travels in neither a
  backup nor settings.json. Size and filter do, as `general.keystrokeOverlaySize` and
  `general.keystrokeOverlayShows`; the dragged position stays on this Mac. A deeplink can turn it off
  but never on.
- **The tap is listen-only and exists only while the overlay is on.** It is appended at the session
  tap's tail, after Hyper has rewritten a key, so a Hyper chord reads as ✦.
- **Secure Input hides keys from it**, as from every tap: a password field never reaches the overlay.
- **What the overlay shows is `KeystrokeFeed`'s call, pure for `keystroke-overlay-test`.**

## What it shows

Plain typing runs into one pill, its last 24 characters, until a pause over a second. A combo is its
keycaps — `KeyShortcut.keycaps`, so the Hyper chord collapses to ✦ — and a repeat within that second
counts up (⌘K ×3). At most four pills show; each leaves two seconds after its last press. **Shortcuts
only** keeps presses holding ⌘, ⌃, ⌥ or ✦, and function keys.

A Hyper layer swallows its keys before the tap sees them, so `AppCore` records a fired layer key itself
as ✦, leader and key.

## Size and place

Small, Medium and Large scale the pills. The overlay defaults to the main display's bottom centre,
above the Dock. Move mode makes the panel take the mouse and outlines it; a drag moves it and the
release saves its bottom centre as `keystrokeOverlayAnchor`. A saved point no display shows any more
falls back to the default, and one near an edge is pulled inside the visible frame.

## Pieces

`KeystrokeTap` turns key-downs into `KeystrokePress`es; `KeystrokeOverlayController` feeds them to
`KeystrokeFeed`, prunes on the earliest expiry, and owns the `.statusBar`-level, click-through panel.
macOS refusing the tap switches the setting back off and asks for Accessibility.
