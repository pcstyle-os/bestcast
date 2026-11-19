# Screen capture

Two launcher commands that read the screen: **Capture Text from Screen** copies the text, or the QR or
bar code, inside a region you drag, and **Pick Color** copies the hex of the pixel you click. Both live in
Settings › Commands and take aliases, hotkeys and Hyper layers like any other `CommandID`.

## Invariants

- **The region picker is the system's own** — `screencapture -i`, with its crosshair, Space to pick a
  window, Escape to cancel and every display. Bestcast draws no capture overlay of its own.
- **Escape is not a failure.** `screencapture` writes no file then, and nothing is reported.
- **Screen Recording is checked before capturing, never requested.** Without it macOS hands back only
  the wallpaper, so the capture would silently read nothing; a dialog says why and opens System Settings.
- **What a capture copies is `ScreenCaptureReading`'s call, pure for `screen-capture-test`.**

## Capture Text

`ScreenRegionReader.read` runs `screencapture -i -x -o` into a temporary file, awaited off the main
actor and deleted once read. Recognition never runs in the app process, which does not link Vision:
`ClipboardTextWorker` hands the file to the bundled `ClipboardTextHelper`, first in its `codes` mode
(`DetectBarcodesRequest`, payloads NUL-separated) and, only when that finds none, in its `image` mode,
the same strip OCR clipboard search uses. A code wins: a region drawn around a QR code was drawn for
its payload, not the caption beside it. Text is copied one recognised line per line, in reading
order, with blank lines dropped. The pill reports what was copied — "Copied 4 lines", "Copied link
from code" — "No text found", which copies nothing, or "Couldn’t read the text" when the helper fails.

## Pick Color

`NSColorSampler` shows the system loupe, which needs no permission. The sample is converted to sRGB
and copied as `#RRGGBB`, each channel clamped first, since a wide-gamut sample can fall outside 0…1.
