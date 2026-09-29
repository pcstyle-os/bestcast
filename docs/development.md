# Development

The local loop: set up, build, run, regenerate. Shipping a build is [release.md](release.md);
verifying a change is [testing.md](testing.md).

## Requirements

- macOS 26 or later (Liquid Glass).
- Xcode 26 — it provides the SwiftUI macro plugin and the SDK.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), and for linting:
  `brew install swiftlint`.
- Node, for the generators and for the two stub servers `run-tests.sh` drives. It is the only
  scripting runtime here — building the app still needs none of it.

## First-time setup

Create the `Bestcast Self-Signed` code-signing identity once — builds sign with it, which is what keeps
macOS from forgetting the Accessibility grant on every rebuild. Follow **[signing.md](signing.md) §1**,
a few `openssl`/`security` commands.

That is the whole required setup. Editor configuration is personal and the repo does not prescribe it;
the section below is a note for anyone who wants it, not a step.

## Build & run

```sh
open Bestcast.xcodeproj    # then ⌘R
```

Or from the command line:

```sh
xcodebuild -project Bestcast.xcodeproj -scheme Bestcast -configuration Debug build
```

`xcodebuild` uses whatever `xcode-select` points at; if that's the Command Line Tools rather than
Xcode, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the SwiftUI
`@State`/`@FocusState` macros need Xcode's macOS platform).

`Bestcast.xcodeproj` is committed and generated from `project.yml` via XcodeGen — after changing
project settings in `project.yml`, run `xcodegen generate` and commit the result. There is no
`Package.swift`, and `Bundle.module` must never be used.

The app target builds and embeds `ClipboardTextHelper` under `Contents/Helpers`, signing it on copy.
Build the app scheme to include it; copying only the main executable omits OCR support. The helper's
executable name stays fixed even when release builds override the app's product name for a channel.

### The dev channel

Debug builds are a separate channel: **`Bestcast Dev.app`**, bundle id `com.bestcast.app.dev`. Every
persisted thing is keyed by bundle id — `~/Library/Preferences/<id>.plist` (settings and hotkey
bindings), `~/Library/Application Support/<id>/` (the onboarding marker, Notes, snippets, quicklinks,
clipboard history, calculator history, launch ranking and frequent emoji; Notes and snippets unless
a folder is chosen),
`~/Library/Caches/<id>/` (exchange rates, the update check, staged downloads), the opt-in
`~/.config/bestcast-dev/settings.json` (`bestcast` on stable), the `SMAppService`
login item, and the Accessibility / Input Monitoring (TCC) grants — so a local build can neither read
nor clobber an installed app's state, and both run side by side.

**What earns a place in Caches is refetchable, and nothing else.** Anything the user would notice the
loss of goes in Application Support: `~/Library/Caches` is excluded from Time Machine and the system
reclaims it under disk pressure without saying so.

Consequences worth knowing:

- The dev build asks for Accessibility on its own the first time, and starts with **no** hotkeys bound
  and onboarding unseen. Grant and bind once; it persists across rebuilds, because the fixed build path
  and the `Bestcast Self-Signed` identity keep the TCC grant alive.
- Don't bind the same global hotkey in both — whichever registered first wins.
- The Hyper Key's Caps Lock remap is `hidutil` state, which is **system-wide, not per-bundle**: quitting
  one build clears the remap for the other, which then needs a rebind or a relaunch to restore it.

### Without Xcode: the CI build

`.github/workflows/build.yml` runs the whole definition of done on `macos-26` for every push and
uploads `Bestcast-Dev-<sha>.zip` (with a `BUILD_INFO.txt` naming the commit) as the run's artifact:
a Release-optimised build on the dev channel's name and bundle id, ad-hoc signed. On a Mac with only
the Command Line Tools this is the only compile check — the harnesses still run locally, except the
eight whose shipped sources use SwiftUI macros (`@Entry`), whose plugin ships with Xcode alone.

Re-sign it with `Bestcast Self-Signed` before installing, or macOS ties the Accessibility grant to
the ad-hoc signature and forgets it with the next build:

```sh
gh run download <run-id> -R pcstyle-os/bestcast -D build/ci
ditto -x -k build/ci/*/Bestcast-Dev-*.zip build/ci
APP="build/ci/Bestcast Dev.app"
codesign --force --options runtime --timestamp=none --sign "Bestcast Self-Signed" \
  "$APP/Contents/Helpers/ClipboardTextHelper"
codesign --force --options runtime --timestamp=none --sign "Bestcast Self-Signed" \
  --entitlements Bestcast/Bestcast.entitlements "$APP"
ditto "$APP" ~/Applications/"Bestcast Dev.app"
```

Keep the install path fixed; the grant follows the path, the bundle id and the certificate.

## Editor

Xcode works out of the box and needs nothing here. Everything below is optional, and which editor you
use is your business — the repo prescribes none of it.

VS Code gets code intelligence from SourceKit-LSP, which needs a `buildServer.json` because there is no
`Package.swift`. Build once, then hand the log to the sync script — that writes both `buildServer.json`
and the flag database:

```sh
brew install xcode-build-server
xcodebuild -project Bestcast.xcodeproj -scheme Bestcast -configuration Debug \
    -derivedDataPath build/DerivedData build 2>&1 | tee /tmp/bestcast-build.log
./Scripts/sync-lsp.sh /tmp/bestcast-build.log
```

Both files are git-ignored because they embed absolute paths, and `sourcekit-lsp` looks for
`buildServer.json` at the workspace root by name, so it cannot live in a subfolder. After this the
**Build Bestcast.app (debug)** task (⌘⇧B) and **F5** re-run the script on every build, so new and
renamed files keep resolving.

**Do not run `xcode-build-server config`.** It writes `kind: xcode`, and in that mode the server ignores
`.compile` entirely — it serves flags from a cache it scrapes out of `.xcactivitylog` instead. That
cache is only refreshed when `LogStoreManifest.plist` advances, and when the manifest stops updating
(it does) the editor silently pins itself to the source list from some older build: every reference to a
file added since reads *cannot find type X in scope*, in every file, until you restart the server. It
also mixes Release entries in with Debug and lets them win. `Scripts/sync-lsp.sh` keeps the mode
`manual`, where `.compile` is the single source of truth.

### Symbols in `Tests/`

`xcodebuild` never compiles the harnesses — they are not in the Xcode project — so nothing emits a
compile command for them, and without one an open harness reports every shipped type it uses as *cannot
find in scope*. Measured on `fuzz-test.swift`: 60 errors with no entry, 0 with one.

```sh
./Scripts/run-tests.sh --index    # merge the harness compile commands into .compile
```

It reads the source lists from `run-tests.sh` itself, so they cannot drift from what the suite actually
compiles. `Scripts/sync-lsp.sh` runs it too. Three things it has to get right, all of which fail
silently otherwise: every path is absolute, because `sourcekit-lsp` resolves the command itself and does
not apply `directory` to relative arguments; the command carries an explicit `-sdk`; and each entry
claims **only files under `Tests/`** — its harness plus any helper compiled beside it. The command
still lists every shipped source it compiles, so symbols resolve inside the harness, but claiming a
shipped source too would hand it this three-file command instead of the app's, and `.compile` is
last-wins.

A benchmark that stays out of the suite still needs flags, so `run-tests.sh` registers it as
`run index <name> <source...>`: `--index` emits its compile command and the runner never queues it.

Fixtures sit beside the harnesses in `Tests/ai-fixtures/` and `Tests/ext-fixtures/`; `ext-devkit-test`
reads its own subfolder, `Tests/ext-fixtures/devkit/` (a tools-only manifest, a linked extension, a
script folder).

Re-run it after adding a harness, then **Swift: Restart LSP Server** from the Command Palette — an
already-running server does not re-read `.compile`.

## Linting

```sh
./Scripts/lint.sh          # lint the whole project
./Scripts/lint.sh --fix    # auto-correct the mechanical subset first
```

[SwiftLint](https://github.com/realm/SwiftLint) is the only code-quality tool here. `.swiftlint.yml` at
the repo root excludes the generated files and the two off-limits files in `DesignSystem/Scrolling/`.
The comment policy in [standards.md](standards.md#comments) is deliberately not among its rules.

## Formatting

```sh
./Scripts/format.sh            # format Bestcast/ and Tests/ in place
./Scripts/format.sh --check    # report what would change, write nothing (exit 1 if any)
```

`swift-format` from the Xcode toolchain — the same binary sourcekit-lsp formats with, so ⌘S in VS Code
and this script cannot disagree. `.swift-format` at the repo root tunes it to this tree; without it the
stock config defaults to 2-space indent and rewrites all 200 files.

Every `*.generated.swift` file is excluded: formatting one is hand-editing it, and the next
`node Scripts/gen-emoji.js` would revert it. swift-format also refuses any file that does not parse, so
a failure from either command is a syntax error rather than a tooling problem — and it is why ⌘S looks
like it does nothing while a file is mid-edit with unbalanced braces.

**Think twice before leaning on this.** A formatter was rejected here on measured evidence, and that
stands: running it over the tree touched 68 files, and 67 of those changed more than whitespace.

The config sticks to rules that catch defects and stays quiet about style, because **there is no
formatter**, on measured evidence. Formatting is
Xcode's re-indent (⌃I), as it always has been. Two consequences worth knowing:

- `empty_count` is **disabled**, and `isEmpty`-style rewrites are unsafe here generally:
  `LauncherRankingRecord` and `PaletteRowIndex` have a `count` that is a hit count, not a collection
  count. A rule that rewrites `count > 0` to `!isEmpty` on them does not compile.
- `force_try` is an error; `force_cast` only warns, because the AX and AppKit bridges have four
  legitimate ones.

Errors block, warnings do not. No CI runs this script; CodeRabbit runs SwiftLint on each PR but not
the settings-search check, so run it locally before you open one.

## Generated data

Three Swift files are emitted by scripts and must never be hand-edited. Each downloads its source, so
run them online, then commit the result:

```sh
node Scripts/gen-emoji.js            # -> Bestcast/Features/Emoji/Model/EmojiData.generated.swift
node Scripts/gen-currencies.js       # -> Bestcast/Features/Calculator/Model/CurrencyData.generated.swift
node Scripts/gen-countries.js        # -> Bestcast/Features/Calculator/Model/CountryZoneData.generated.swift
```

`gen-countries.js` joins IANA's `zone.tab` with CLDR's `en` territory names on the ISO 3166 code. Re-run
it when IANA adds or moves a country's zone; see [calculator.md](features/calculator.md#time-zones).

`gen-currencies.js` joins three sources on the ISO code: the **fiat rate feed**'s own quote list — the
same feed `CurrencyRateStore` fetches rates from, so the table and the rate source cannot drift apart
— **Unicode CLDR**'s `en` currency data, which supplies display names, signs and the singular/plural
noun, and **CLDR's supplemental currency data**, which says which codes are still spent anywhere. That
last one is not optional: the feed carries no retirement metadata and quotes codes their countries
abandoned years ago. Both CLDR files are read from the pinned `cldr-json` checkout rather than the
host's `Intl`, whose output shifts with the local ICU version and would make the file unreproducible.

Only unambiguous data is emitted. Anything two currencies claim — `dollars`, `pounds`, `krona` — is
left out and decided by hand in `CalcCurrency.contested`. The crypto tickers aren't generated at all:
they have no external source of truth, so `CalcCurrency.crypto` is hand-written, and that same list is
the set of symbols the fetch asks for. Re-run the script when a currency is added or retired; nothing
breaks in the meantime, since an unquoted code just reports "no exchange rate".
