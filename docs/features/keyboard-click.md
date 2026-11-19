# Click by keyboard

Three launcher commands that drive the front window without the mouse: **Click by Keyboard** puts a
yellow letter hint on everything clickable and clicks the one whose letters you type, **Click by Name**
clicks the first control whose name matches what you type, and **Scroll by Keyboard** scrolls the
window with H J K L, D and U. All three live in Settings › Commands and take aliases, hotkeys and Hyper
layers; pressing the same hotkey again closes the overlay.

## Invariants

- **Only the focused window of the app in front is read**, never Bestcast's own: the sweep follows
  `FrontmostApplication`, so a palette that just closed hands over to the app it covered.
- **The sweep is bounded**: 0.2 s per element, 600 ms and 6,000 elements per window, off the main
  actor. A slow app shows fewer hints rather than a late overlay.
- **A click is a real click at the target's centre**, posted at the HID tap, and the pointer goes back
  where it was. Rows, cells and web content take a click where `AXPress` would do nothing.
- **Labels are prefix-free**, so typing a full label always clicks and never waits for more.
- **Which targets get labels, their order and their letters is Model code**, pure for
  `keyboard-click-test`.

## Reading the window

`AXClickTargetSweep` walks the focused window depth first, one batched attribute read per element.
Buttons, links, checkboxes, radio buttons, pop-ups, fields, sliders, disclosure triangles and rows are
targets by role; a group, image or cell is one only when it offers `AXPress`. A subtree outside the
window is skipped. A target with no title or description takes the first static text inside it, so a
mail row is named by its sender.

`ClickTargetLayout` clips every frame to the window, drops slivers under 6 pt, merges elements that
share a frame (a row and its only cell), and orders what is left in reading order: tops within 8 pt
read as one line, left to right. At most 400 targets are kept.

## Hints

`ClickHints.labels` gives each target the shortest label from `asdfghjklqweruio` that keeps the set
prefix-free: up to 16 targets take one letter each, home row first, and only as many letters become prefixes
as the count needs. Typing a letter dims it in every tag that still matches and hides the rest; a
letter no label continues is ignored, Delete takes one back and Escape closes.

## Click by Name

Typing filters targets by name, case and accents folded: names that start with the text first, then a
word that does, then any match, each in reading order. Every match is tinted in Find's yellow and the
first is outlined; ↵ clicks it. The field and its match count sit at the window's bottom edge, where a
toolbar never is.

## Scroll by Keyboard

J and K scroll 80 pt down and up, H and L left and right, D and U half the window. Each key posts one
pixel-unit scroll-wheel event at the window's centre.

## The overlay

`KeyboardClickPanel` covers exactly the target window, ignores the mouse and takes key without
activating Bestcast, so keys reach it while the app stays in front. Losing key — a click anywhere
else — ends the session. Hint tags reuse `Theme.Colors.findCurrent` and `findCurrentInk`.
