# Quick Actions

Act on whatever text is selected, in whatever app is frontmost. Four are shipped: Fix Grammar,
Rewrite, Translate and Summarize, each with its own bindable shortcut **and its own launcher command**,
both listed in **Settings → Quick Actions**. Three go through the AI provider layer; Translate goes to
Apple's own translator. The result either replaces the selection or arrives in a floating panel, per
action.

An **AI Command** is the reader's own action, Raycast-style: a name, a glyph, a prompt, an output and
a creativity, run through the same provider. The prompt may use placeholders, so it can be filled
with the selection, the clipboard, the frontmost browser tab, the frontmost app, the date and time,
and up to three typed arguments. It takes a shortcut and a launcher row like any other. A library of
ready-made commands lives behind **Add from Library…** and the **Browse AI Commands** launcher
command. The commands import and export as Raycast-shaped JSON. In code an AI Command is still a
`CustomQuickAction`. The type kept its name because its identity, store, hotkey and launcher plumbing
did not change.

Quick Actions is the provider layer's second consumer. It shares the provider connections and
selectable Markdown renderer with AI Chat.

## Invariants

- **Off out of the box, and off means the shortcuts do nothing.** `AppSettings.quickActionsEnabled`
  is the flag and `QuickActionCoordinator` is the only place that reads it: no selection is read, no
  provider is built, no panel opens. The four commands leave the launcher's Quick Actions slice
  through `AppIndex.setCommandsVisible`, and the custom ones leave it through
  `AppIndex.setCustomQuickActions`, the way Notes and AI Chat drop theirs. Carbon bindings stay
  registered, so re-enabling restores every shortcut without touching the hotkey layer. The flag
  grants keystroke delivery into other apps, so like `snippetsEnabled` it is excluded from settings
  backups — an import must never arm it.
- **One funnel, whichever way an action started.** A shortcut and a launcher row both land on
  `QuickActionCoordinator.run(_:)`, which reads `paletteCoordinator.targetApp` **before** hiding the
  palette — once the palette is gone, the frontmost app is Tinycast, and the action would read its
  own window. Hiding there rather than at each caller is what keeps the two paths identical.
- **Enabling is consent, and it is the only place Accessibility is requested.** The toggle confirms
  through `DialogController` first and then calls `Permissions.ensureAccessibility()`, the pattern
  `SnippetCoordinator.setSnippetsEnabled` established. Everything else — a shortcut press, a
  delivery — uses `isAccessibilityTrusted()` and degrades to a HUD.
- **Tinycast is never an event target.** `QuickActionRunner.selection(in:using:)` refuses our own
  bundle identifier, and `TextInjector.targetAcceptsInjection` refuses it again before every event post,
  along with anything raised while Secure Event Input is up. A shortcut pressed with Settings
  frontmost, or in a password field, does nothing and says so.
- **One run at a time.** Two overlapping runs would race for one selection, and the second would
  replace text the first had already changed. `QuickActionCoordinator` holds a single task and
  refuses a second while it lives; a generation token stops a task that finishes after being
  replaced — by a retranslate, say — from clearing the newer handle.
- **`Model/` stays Foundation-only.** `quick-action-test` compiles that folder standalone, which is
  what keeps `FoundationModels`, `Translation` and `NaturalLanguage` in `Service/` and `UI/`.
- **Quick Actions route themselves.** `quickActionModel` is a second routing decision, defaulting to
  Apple Intelligence and falling back to chat's model. A shortcut pressed all day should not bill an
  API every time, and that is not a choice chat's default can make on its behalf.
- **An action may override that route, and only by choice.** `quickActionModelOverrides` is keyed by
  `QuickAction.id`, so the built-in four and custom actions share one lookup,
  `QuickActionSettingsStore.model(for:)`. An absent entry follows `quickActionModel`, so nothing
  changes until the reader picks a model in the action's sheet. Translate never takes one.
- **A dead override is dropped, never rerouted.** Repair walks every override beside the shared
  route: a vanished catalog model moves to its command's first model, like the shared route, but a
  removed connection or an unavailable command deletes the entry instead of borrowing chat's model.
  The action then follows the route its pane names, not one the reader never chose for it.
- **Installed providers are ordinary routes.** The model picker reads the same live Codex, Claude, Grok,
  OpenCode and Cursor catalogs as AI Settings. Execution still goes through `AIProviderFactory`, so Quick Actions
  inherit the same installed login, tool restrictions and process cleanup without owning CLI logic.
- **The model picker is the AI picker.** Both panes render `AIModelOption.groupedCatalog`, with the
  same provider sections, model labels and provider-supported reasoning levels. An installed-model
  selection stores its effort in `quickActionModel`, independently of chat's effort. The sheets use the
  same `AIModelSelectionRows`, with **Same as Quick Actions** as the `nil` choice.
- **The reader's own text gets permissive guardrails.** `AppCore.quickActionProvider()` asks for
  `SystemLanguageModel.Guardrails.permissiveContentTransformations`. The default filter is tuned for
  a model writing fresh prose and refuses to transform text somebody already wrote, which is the
  whole feature.
- **Built-in instructions treat the selection as untrusted input.** `QuickActionPrompt` tells the
  model that the text is material to work on and never instructions to follow, and that only the
  transformed text may come back — no preamble, no fences. Custom instructions replace these rules
  too. The output is pasted into somebody's document.
- **A custom prompt cannot drop that boundary.** An override on a shipped action may replace
  `boundary`, because the sheet shows the whole prompt. A custom action *is* the prompt, so `boundary`
  is prepended and no control removes it. A placeholder prompt gets `AICommandTemplate.boundary`
  instead. It says the same thing about selected text, clipboard contents and web pages, and nothing
  the reader types removes it. When the answer goes to AI Chat, where no system prompt of ours
  applies, the turn carries `materialNote` as long as it quotes any of that material.
- **An AI Command reads only what its prompt names.** `AICommandTemplate.facts(for:)` decides what
  is gathered. A prompt without `{selection}` never reads the selection, never borrows a ⌘C and runs
  with nothing selected. A prompt without `{browser-tab}` never sends an Apple Event. The one
  exception is a prompt with no placeholders at all. It predates AI Commands, so it transforms the
  selection exactly as it always did.
- **The browser is asked, never scraped.** `{browser-tab}` asks the frontmost Safari, Chrome, Arc
  or Brave for its front tab's title and URL through `NSAppleScript`. It runs off-main,
  and only after the reader runs a command that names the placeholder. A refused Automation grant
  (`-1743`/`-1744`) opens a Tinycast dialog that names the browser and offers System Settings →
  Privacy & Security → Automation. It never falls back to a guess. Any other frontmost app is
  refused with a HUD. Only the title and URL are read, never the page's content.
- **A command that types checks for a target before it asks the model.** A Replace or Paste command
  refuses at once if the displaced app is Tinycast, is gone, or no app is frontmost. It also refuses
  when Accessibility is missing. None of those runs spends a call whose answer could not land.
  `TextInjector` still refuses our own bundle and Secure Event Input before every event post.
- **Each model action owns its instructions and its route.** The pencil on Fix Grammar, Rewrite and
  Summarize opens a sheet prefilled with the exact built-in prompt and the action's model. Saving
  replaces both for only that action; Use Default restores the prompt. Translate has no editor because no model handles translation. The same
  pencil on a custom action opens its editor, which owns the name and glyph too.
- **A custom action never travels in a backup.** Neither the record, its shortcut nor its route, for
  the reason `quickActionInstructions` already doesn't: an import must never change what a shortcut
  does to somebody's documents. Its JSON sits outside `UserDefaults`, so no settings key can sweep it
  up, and `quickActionModelOverrides` is excluded like `quickActionModel`. **Import…** in the pane is
  the one way in from a file. It is a gesture made in the pane, and it adds records without binding
  a shortcut or choosing a route.
- **Nothing runs by itself while AI is off.** An unattended run needs `aiEnabled`,
  `quickActionsEnabled` and **Settings → AI → Scheduled Commands**, all three, checked again before
  each run and before its reply lands. Turning any one off stops the loop, and a reply that finishes
  after that is dropped. `aiScheduledCommands` arms commands that send what they read to a model with
  nobody watching, so it is a capability grant: excluded from backups, with no `settings.json` key.
  Import never carries a schedule or a trigger either, since `AICommandArchive` has no field for one.
- **Only a command that needs nobody may run by itself.** `AICommandSchedulePolicy.backgroundBlocker`
  refuses a prompt that transforms the selection, names `{selection}` or `{browser-tab}`, or has an
  argument without a default, and `normalized` makes saving such a command throw. A hand-edited file
  with a broken schedule or pattern loses only its automation, never the command.

## The actions

`QuickAction` is `.builtIn(BuiltInQuickAction)` or `.custom(CustomQuickAction)`. Coordinator, panel,
runner and prompt all take that one type, and neither half has a code path of its own.

A fifth *shipped* action is one `BuiltInQuickAction` case, its prompt in `QuickActionPrompt`, and one
`CommandID` case for its launcher row. `CommandID.init(_ action:)` is exhaustive, so it cannot compile
without one.

The custom case carries the record rather than an id, so a run uses the prompt as it was when it
started.

| Action | Engine | Default result | Diff |
| --- | --- | --- | --- |
| Fix Grammar | provider | replaces directly | yes |
| Rewrite | provider | panel | yes |
| Translate | Apple Translation | panel | no |
| Summarize | provider | panel, always | no |
| an AI Command | provider | its own output, **Show in Panel** when new | no |

An AI Command shows its answer in the panel unless the reader picks another output in its editor or
in the pane's per-row popup. Tinycast cannot know whether an arbitrary prompt transforms the text or
answers a question about it, and only the first is safe to write over what was selected. There is no
diff, for the same reason.

Custom instructions stay on this Mac and are excluded from settings backups, like chat's system
prompt, because importing them would change results without the reader seeing them first.

## AI Commands

`CustomQuickAction` is `id`, `name`, `iconSymbol`, `instructions` (the prompt), `output`,
`creativity`, `createdAt`. `CustomQuickActionStore` keeps them as JSON in Application Support, ordered
by `createdAt`, under an injected directory so the harness gets a throwaway one. Name and instructions
must be non-empty. Nothing else is rejected, including a name a shipped action already uses. A file
written before AI Commands has `previewsResult` instead of `output`, and decoding maps it to Panel or
Replace, so an existing action keeps doing what it did.

**Output and creativity ride the record.** `QuickActionSettings` keys on `BuiltInQuickAction`, which
cannot hold a UUID, and a parallel dictionary would outlive what it described. On the record, a delete
takes the choice with it.

### Placeholders

The prompt goes through `SnippetTemplateEngine`, the parser Snippets and Quicklinks use. Modifiers,
quoting and unknown-token handling are therefore identical, and `AICommandTemplate` is the thin layer
that decides what to gather and how the request is framed.

| Placeholder | Filled with | Read when |
| --- | --- | --- |
| `{selection}` | the frontmost app's selection, through the two tiers below | the prompt names it |
| `{clipboard}` | the current plain-text clipboard | the prompt names it; empty or over the selection cap refuses |
| `{browser-tab}` | the front tab's title and URL, one per line | the prompt names it and a supported browser is frontmost |
| `{frontmost-app}` | the displaced app's name | always cheap, read from the target the run captured |
| `{date}` · `{time}` · `{datetime}` · `{day}` | the run's clock, in the reader's locale | always |
| `{argument name="…" default="…" options="…"}` | a launcher field, see below | up to three per prompt |

**A prompt with no placeholders is a selection transform.** It is sent through `QuickActionPrompt`
exactly as a custom action always was, with the selection as the message. This is the path the
built-in rules and the model's token budget were tuned for, and it keeps the reader's existing actions
unchanged.

`{frontmost-app}` and `{browser-tab}` exist only in `ExpansionContext` for AI Commands. A snippet or
quicklink passes nil, so either token is left as written, the same way an unknown token is.

### Arguments

`AICommandTemplate.arguments(in:)` lists the first three `{argument}`s in written order, with their
defaults and options. `QuickActionArgumentsAccessory` draws them as inline fields beside the launcher's
query. It uses the same `InlineArgumentFields` as quicklinks and custom commands, and the values are
keyed by argument name. An argument with a `default=` is optional and may be left blank.

A shortcut has no fields. `run(id:arguments:)` checks `missingArguments`, and when one is still owed it
opens the palette on that command with its fields showing, through `paletteCoordinator.showArguments`,
instead of running with a blank. `LauncherScreen` pins the command's row while its fields are open,
even if the command is hidden from search, because the shortcut that opened it still needs an answer.

### Outputs

| Output | What happens to the answer |
| --- | --- |
| Replace Selection | typed over the selection through `TextInjector.replaceSelection` |
| Paste | inserted at the insertion point; there is no selection to replace |
| Copy | put on the clipboard, and a HUD says so |
| Show in Panel | streamed into the Quick Action panel |
| Open in Quick AI | the filled prompt is sent to a fresh Quick AI chat, as if it had been typed there |

Replace, Paste and Copy use a boundary that asks for the result alone, with no preamble or fences,
because the text lands in somebody's document or clipboard. The panel's boundary asks for a direct
answer and renders it as Markdown. Replace and Paste that cannot land fall back to the clipboard,
like any Quick Action.

The panel's footer for an AI Command is **Continue in Chat** (⌘J), **Copy** (⌘C) and **Replace** or
**Paste** (↵). The last one says Paste when nothing was selected. Continue in Chat saves the exchange,
the filled prompt and the reply, as a new chat in AI Chat history. It uses the command's route, or
chat's default model when the command follows the shared one, and then opens it in the AI Chat
window. The button is only offered while AI Chat is on.

**Open in Quick AI** needs `aiEnabled`. It hands the turn to `QuickAICoordinator.ask`, so it runs on
chat's route with chat's tools, and neither the command's model nor its creativity applies there.
It is still the reader's own gesture: the prompt only leaves the Mac because they ran the command.

### Creativity

Low, Medium and High map to `AIRequest.temperature` of 0.2, 0.6 and 1.0. The value is a hint.
`AITemperaturePolicy` sends it to Anthropic, Gemini, OpenRouter and non-reasoning OpenAI-compatible
models, clamped to 0…1. Apple Intelligence takes it through `GenerationOptions`. OpenAI's reasoning
models (`o*`, `gpt-5*`) and current Claude models (Opus 4.7+, Sonnet 5+, Fable) reject the field, and installed CLI routes have no such knob, so there it is
dropped without a word rather than failing the run. Built-in actions send no temperature.

### Running by itself

An AI Command can run with nobody there. The editor's **Run by itself** block stores an
`AICommandAutomation` on the record:
- a schedule (`AICommandSchedule`): daily or weekdays at a time, every 1 to 24 hours, or at login;
- a clipboard pattern, a regex that starts a run for each newly copied text it matches, read as
  `{clipboard}`;
- whether a banner follows the reply.

`AIInboxCoordinator` owns the runs. Its loop asks `AICommandSchedulePolicy.plan` what is due, runs
it, then sleeps until the next slot or `maxWait` (15 minutes), whichever is sooner. A wake from sleep
and every edit to the commands cut that sleep short. A slot missed while the Mac slept or Tinycast was
quit runs **once** on return, never once per missed slot. **At login** means once per launch of
Tinycast, which is at login when it is a login item. Scheduled and clipboard runs share one queue and
go one at a time, each on the command's own
route through `AppCore.quickActionProvider`, with `QuickActionRunner.run`. The output choice does not
apply: every reply, and every failure, lands in the **AI Inbox**.

`AICommandRunLedger` (`ai-command-runs.json`) remembers each command's last scheduled run and its
clipboard runs in the last day. A new or changed schedule is baselined to now, so saving one never
fires a catch-up for a slot that passed before it existed. A run is marked before it starts, so a
failing command waits for its next slot rather than retrying every wake.

The clipboard trigger hangs off `ClipboardStore.onTextCaptured`, beside Passive AI's indexer, so it
sees only what clipboard history kept. A copy it hid (a concealed or transient type) never reaches a
model, and the trigger needs clipboard history on. Each command waits `clipboardCooldown` (60 s)
between runs and stops after `clipboardDailyCap` (30) a day. Text over 10,000 characters is ignored,
and so is a copy of a reply that already sits in the inbox, which stops a command feeding itself.
A scheduled run that names `{clipboard}` reads the pasteboard directly and gets nothing when it
carries a concealed type.

The **AI Inbox** (`CommandID.aiInbox`, palette mode `.aiInbox`) lists replies newest first, bucketed
by day and searchable by command, reply and failure text. ↵ copies a reply, ⌘J continues it in AI
Chat on the command's route, ⌃X deletes one and ⌃⇧X deletes all after a Tinycast dialog.
`AIInboxStore` keeps the newest 200 in `ai-inbox.json`, outside settings backups like chat history.

A banner is `AIInboxNotifier` on `UNUserNotificationCenter`. Permission is asked only when the reader
switches **Show a notification** on in the editor; a refusal switches it back off with a HUD. Clicking
a banner opens the inbox.

### Library, import and export

`AICommandLibrary` is the built-in library: 28 prompts in four categories, Writing, Summaries, Code and
Other. **Add from Library…** in the pane opens `AICommandLibraryPanel`, where one click turns an entry
into an ordinary AI Command through `makeCommand`. From then on it is the reader's to edit or delete.
An entry reads as **Added** when a command with its name or its exact prompt already exists, so an
edited copy is not offered twice.

**Browse AI Commands** (`CommandID.browseAICommands`) is the launcher's way into the library. It
closes the palette, opens Settings → Quick Actions scrolled to AI Commands and, while Quick Actions
are on, opens the library panel through the coordinator's observed `libraryRequested`, which the pane
clears. With Quick Actions off it only opens the pane, where the switch is.

**Import…** and **Export…** read and write `AICommandArchive`. It uses Raycast's shape, a JSON array of
`{title, prompt, icon, creativity, output}`, so an export from either app imports into the other.
- A hand-written `name` is accepted for `title`.
- A single object is accepted as well as an array.
- Raycast's five creativity steps fold into three.
- `model` is ignored, because Raycast's model names mean nothing here.
- An icon that is not a known SF Symbol is dropped, which is how Raycast's own icon names are handled.
- A record matching an existing command by name (case-insensitive) and prompt counts as a duplicate
  and is skipped, so importing the same file twice adds nothing.
- The batch is written in one commit, so a failed write leaves nothing half-imported.

Only the reader's own commands are exported. The four built-ins are not theirs to move.

**`AppEntry.Kind.quickAction` is one section for both halves**, ungated in
`VisibilityStore.allowsHotKey` because `quickActionsEnabled` is the master switch. The four keep their
`CommandID`s, so no shortcut or preference key moved. A custom action binds
`HotKeyAction.quickAction(id:)` under `hotkey.quickAction.<uuid>`, indexed in `boundQuickActionIDs` so
`HotKeyManager.start` can prune a binding whose action was deleted while Tinycast was off.

**The pane draws its own `AliasField`.** The four are named in `SettingsTab.ownedCommands`, so
Settings → Commands no longer draws theirs. Without it, `deleteCustomQuickAction` would be clearing an
alias no surface could set.

**Nothing is saved until it is on disk.** `commit` persists before it moves `actions`, and a write
that cannot land throws `.storageUnavailable` where the reader sees it. An absent file is a fresh
install; one that exists but will not decode sets `isAvailable` false and makes every mutation refuse.
`QuicklinkStore`'s rule: authored data is reported on, never written over.

**Deleting unwinds only once the record is gone.** Confirm, remove, *then* drop the binding, the
route override, the favorite, the alias, the visibility key and the ranking. `WindowLayoutCoordinator`'s order: a failed
delete must never leave a kept record stripped of its shortcut.

Only Fix Grammar applies unseen: it changes what was wrong, where a rewrite changes the voice.
Summarize can never be told to replace text unseen — it answers a question *about* the text, so
replacing the text with the answer has to be a choice made in the panel. Every other default is a
**Replace / Preview** popup in the pane — a popup rather than a second checkbox, because the trailing
checkbox column means "show in the launcher" in every pane the app has. `QuickActionSettings` stores
only what the reader actually changed, so a new action arrives with its own default rather than
whatever a missing key would have meant.

## Translation

`TextTranslator` uses Apple's translator rather than the language model: it runs on device, costs
nothing on every route, and a 3B model is markedly worse at it. `NLLanguageRecognizer` supplies the
source language, because `TranslationSession(installedSource:target:)` needs a concrete one and
`LanguageAvailability` reports only a status.

`TranslationError` is annotated `macOS 26.4` while the deployment floor is `26.0`, so failures are
caught as plain `Error` and reported by what was asked rather than by matching its cases.

**The picker offers Apple's own list, never the reader's preferred languages.** `supportedLanguages`
is 47 entries on macOS 26 and is the framework's to change; building the menu from
`Locale.preferredLanguages` instead would put a language the translator cannot reach in front of
someone, where it could only fail at press time. Notably **Bengali is not among the 47**. The list
loads asynchronously, so the coordinator holds it as observed state rather than a computed property.
Names come from `minimalIdentifier` — the maximal form carries the script, and `es` would read
"Spanish (Latin, Spain)" in a menu that should say "Spanish".

A pair that is supported but not downloaded **opens the panel**, whatever the action's usual result,
so a shortcut never silently does nothing. **The download happens in System Settings.**
`prepareTranslation` never showed its sheet over this non-activating panel, so the prompt says where
to go — Language & Region → Translation Languages… — and its one button opens that pane and closes
the panel. System Settings has no anchor for the sheet itself, so the last click stays the reader's.

## The panel

`QuickActionPanel` is Tinycast's **fourth borderless surface**, beside the dialog, the notes panel
and the join preview. It takes the same recipe — `panelScrim`, then `GlassEffectView`, then the
clip — and sits at `.floating` like the join preview, so a failure report still lands on top of it.
Its footer speaks the same button language as a dialog's — `ModalActionButtonStyle`, with Replace
as the `.primary` role — so every borderless surface answers in one voice rather than dropping Aqua
controls onto vibrancy.

It could not have been built on `HUDPresenter`: `HUDPanel` sets `ignoresMouseEvents` and returns
`false` from `canBecomeKey`, so it is click-through and hosts no buttons. Nor on `DialogAccessory`,
which is a closed two-case enum measured once at present time — a growing stream would clip.

Non-activating, so the target app keeps its selection while the panel holds key. Keys go through
`sendEvent`: `↵` replaces (or pastes), `⌘C` copies, `⌘J` continues an AI Command in AI Chat, and `esc`
dismisses. Click-away dismisses like every other borderless surface. The panel is anchored by its
**top-left** and re-measured as the reply arrives —
centring on every measure would walk it up the screen. Summarize and every AI Command use chat's
`ChatMarkdownText` and `MarkdownBlock.parse`, keeping the whole result selectable across paragraphs
and headings.

The body is a `ScrollView` with its height **set** rather than capped: a scroll view has no ideal
height, so `NSHostingView.fittingSize` measures it as nothing and the body collapses to a slot. The
content's ideal height is measured with `fixedSize` + `onGeometryChange`, the way the Support and
Updates windows size themselves.

The scroll view owns the **whole** panel and the bars are overlays on top, so a result dissolves
beneath them rather than stopping at a line. The mask is clear for each bar's height, ramps over
`quickActionScrollFade`, and the content is inset by bar + ramp — so the first line starts fully
opaque and only dissolves once it has scrolled up into the gradient. It is skipped entirely when the
result already fits, since dimming text that needs no scrolling reads as a defect.

Three things here were settled by rendering them, not by reasoning:
`scrollEdgeEffectStyle` draws nothing in this panel — it renders a material where a scroll view meets
a safe area, and over `panelScrim` + `GlassEffectView` that composites to nothing. `safeAreaBar`
makes it visible but lays its bars *over* the content instead of insetting it, so text runs through
the buttons and escapes the corner clip. And a ramp starting at the panel edge rather than below the
bar leaves text about 60% visible behind the title.

`TextDiffEngine` shows what changed when the output is the input, edited. Its traceback is
quadratic, so past `maxTokens` a side it degrades to whole-text rather than asking for gigabytes.
It keeps one rolling `UInt16` score row and one insert-or-delete bit per token pair — equality is
re-checked during traceback — so the cap costs about 2 MB where a full score matrix cost 32 MB.

## Reading the selection

Two tiers, in order. `AccessibilityText.read` asks for `kAXSelectedTextAttribute`, then the
text-marker range browsers use instead. `AXManualAccessibility` is set on the application element
first, because Chromium builds its accessibility tree only once something asks and Chrome, Electron
apps and VS Code otherwise answer every attribute with nothing.

When Accessibility yields nothing, `TextInjector.copySelection` borrows a ⌘C: snapshot the
pasteboard, synthesise the chord, wait for `changeCount` to **move**, read, restore. It lives on
`TextInjector` because the pasteboard has one owner — the same lease, queue and `ClipboardManager`
coordination a paste needs, and a second owner would race it.

**The `changeCount` guard is load-bearing.** With nothing selected, ⌘C is a no-op; returning the
pasteboard's existing contents there would transform whatever the reader last copied and paste it
over their selection. Movement is the only proof a copy happened — never comparing content, which
false-positives when the same text was already on the clipboard.

Copying is the fallback and never the first try: it synthesises a keystroke into somebody else's app.
When both tiers come back empty, only an Accessibility result of `.empty` justifies "nothing is
selected"; otherwise the app told us nothing either way and says so.

## Delivery

`TextInjector` — shared with Snippets and Quicklinks, and owned by `AppCore` — does the replacement.
`replaceSelection(with:in:)` takes the interactive path: no keyword to match, no generation to
cancel, because a shortcut is an explicit gesture rather than an expansion the app decided to
attempt. Its serial delivery queue is what stops two features fighting over the pasteboard lease.

The Accessibility tier replaces the live selection atomically, under the five-rule delivery contract
in [snippets.md](snippets.md#text-delivery-and-pasteboard-safety) — Quick Actions simply enter it with
no keyword, so rule 2 never applies. The event tiers behind it type or paste over the selection, which
every app treats as replacing it — but that is the target app's behaviour rather than something
Tinycast asserts, so it is the part worth checking by hand.

**A replacement that never lands says so, and keeps the reply.** Every tier can decline, and a shortcut
that quietly did nothing is indistinguishable from a shortcut that is not bound. `DeliveryCompletion`
now settles either way, so a delivery that returned early reports failure exactly once; Quick Actions
put the generated text on the clipboard and raise a HUD rather than dropping it. Snippets pass no
failure handler, so automatic expansion stays silent as before.

### Manual sweep

- Select text in Safari, Chrome, Brave, Slack, Mail, Notes, VS Code and Terminal, press Fix Grammar,
  and confirm the selection is **replaced** rather than appended to.
- In a Chromium target, run one on a **short** selection whose result stays under 100 characters on
  one line: the whole result lands, not its first four characters.
- Replace mode, with a slow route selected: the message pill says `Fixing Grammar…` with a blue
  spinner while the model works, and the result message takes its place.
- Run one from the launcher (⌘Space → "Fix Grammar") with text selected behind it: the palette
  closes and the selection in the displaced app is what gets acted on, not Tinycast's own field.
- Uncheck an action's launcher checkbox: the row leaves ⌘Space, and its shortcut still works.
- Add a custom action, bind a shortcut, run it from the shortcut and from ⌘Space, then rename it and
  confirm the shortcut, the Replace choice and the checkbox all survived.
- Delete a custom action with a shortcut bound: the dialog asks first, the row leaves both Settings
  and ⌘Space, and the chord is free for something else to take.
- Type "quick actions" in ⌘Space: the section lists the shipped four beside the custom ones.
- Give Fix Grammar and a custom action an alias in the pane, then type each alias in ⌘Space.
- Press a shortcut with Tinycast's own Settings window frontmost: refused, with a HUD.
- Press one in a password field: refused.
- Summarize a long selection: the panel streams, grows without the title drifting, and scrolls past
  `quickActionPanelBody`.
- Replace Rewrite's instructions, confirm only Rewrite follows them after relaunch, then use the
  modal's default and confirm the shipped behaviour returns.
- Give Summarize its own model and effort: the row names them, only Summarize uses them, and they
  survive a relaunch. Turn that provider off in AI Settings and Summarize follows the shared model.
- Save a custom action with its own model, delete it, and confirm no route is left in
  `quickActionModelOverrides`.
- Translate into a language that has not been downloaded: the panel names the language, and its
  button closes the panel and opens Language & Region.
- Revoke Accessibility while enabled: a HUD explains instead of failing silently.
- Add **Translate to Language** and **Summarize Web Page** from the library. In ⌘Space type
  "Translate", fill in the language field and run it over a selection. Then bind a shortcut to it
  and press it: the palette opens on the command with its field focused.
- Run Summarize Web Page with Safari frontmost the first time: macOS asks about Automation. Deny it
  and run again: Tinycast's own dialog names Safari and opens the Automation pane. Run it with
  Finder frontmost: refused with a HUD.
- Give a command the Paste output and run it from ⌘Space with nothing selected in a text field:
  the answer is inserted. Run a `{clipboard}` command with an empty clipboard: refused.
- Run a Show in Panel command, press ⌘J: AI Chat opens on a new chat holding the prompt and reply.
- Export, delete one command, then import the file twice: the first import restores it, and the
  second reports that everything is already there. Import a Raycast export: titles, prompts and
  creativity arrive.
- Run **Browse AI Commands** from ⌘Space: Settings opens on AI Commands with the library showing.
- Give a `{date}` command **Every hour**, save it, and confirm nothing runs at once. Set the Mac's
  clock (or wait) past the hour: one reply lands in **AI Inbox** (⌘Space → "AI Inbox").
- Give a command **Daily** a minute from now, sleep the Mac across it and wake it: exactly one reply
  arrives on wake, not one per slot slept through.
- Try to schedule a `{selection}` command: saving refuses, and the editor names the reason.
- Give a `{clipboard}` command the pattern `^https://`, then copy a URL: a reply lands. Copy the
  same URL again within a minute: nothing. Copy the reply out of the inbox: nothing.
- Copy a password from a password manager that marks it concealed: nothing runs.
- Switch **Show a notification** on: macOS asks once. Deny it: the switch goes back off with a HUD.
  Allow it: the next reply shows a banner, and clicking it opens the inbox.
- In the inbox: ↵ copies, ⌘J opens the reply as a chat in AI Chat, ⌃X deletes one, ⌃⇧X asks first
  and then clears everything. VoiceOver reads each row's command, summary, cause and time.
- Turn Scheduled Commands off in Settings → AI, or AI off: no further runs, and a run already in
  flight leaves nothing in the inbox. AI off also hides **AI Inbox** from ⌘Space.
- Harnesses: `quick-action-test` (action metadata, prompt boundaries, output choices, routes and
  their repair, diffs), `ai-command-test` (placeholders, arguments, rendering and its boundary, the
  library, the archive, browser-tab parsing and temperature policy), `ai-schedule-test` (slots,
  catch-up, the ledger, clipboard caps, eligibility, the inbox store) and
  `text-diff-test` (exact chunks, Unicode, ties, token boundaries and fast paths).
