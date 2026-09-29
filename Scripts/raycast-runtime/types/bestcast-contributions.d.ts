// The contract for `package.json` → `bestcast.contributes` exports. Each export is a plain function
// in a CommonJS bundle, run one-shot on the tool-session lane: no React, no UI, and whatever it
// returns is decoded, capped and drawn by Bestcast itself.

/** What ↵ or ⌘K does on a contributed row. The host performs it; the export never touches the UI. */
export type ContributionAction =
  | { type: "copy"; content: string; title?: string }
  | { type: "paste"; content: string; title?: string }
  /** An http(s) or mailto URL, or an absolute file path. Any other scheme is dropped. */
  | { type: "open"; target: string; title?: string }
  /** One of this extension's own commands, handed string arguments. */
  | { type: "launch"; command: string; arguments?: Record<string, string>; title?: string };

/** `contributes.search[]` export input. `query` has the provider's `prefix` already removed. */
export interface SearchInput {
  query: string;
}

/** One root-search row. Titles are one line, capped at 120 characters; `icon` is an SF Symbol name. */
export interface SearchItem {
  id?: string;
  title: string;
  subtitle?: string;
  icon?: string;
  accessory?: string;
  /** The first action is ↵; the rest are listed under ⌘K. Defaults to copying the title. */
  actions?: ContributionAction[];
}

/** `mode: "answer"`: one line, as a string or with its own actions. Defaults to copying it. */
export type SearchAnswer = string | { title: string; subtitle?: string; actions?: ContributionAction[] };

/** `mode: "rows"` returns items, cut to `maxResults` (at most 5); `mode: "answer"` a `SearchAnswer`. */
export type SearchExport = (
  input: SearchInput,
) => SearchItem[] | { items: SearchItem[] } | SearchAnswer | Promise<SearchItem[] | { items: SearchItem[] } | SearchAnswer>;

export type RowActionKind = "file" | "clipboard.text" | "clipboard.image" | "app" | "snippet" | "quicklink";

/** `contributes.actions[]` export input: the row ⌘K was opened on. */
export interface RowActionInput {
  kind: RowActionKind;
  item: { path?: string; text?: string; bundleId?: string; name?: string; id?: string };
}

/** A returned string is shown as a HUD. */
export type RowActionExport = (input: RowActionInput) => string | void | Promise<string | void>;

/** `contributes.placeholders[]` export input: the `key="value"` pairs of `{ext:<ext>/<name> …}`. */
export interface PlaceholderInput {
  arguments: Record<string, string>;
}

/** The text the placeholder expands to; anything else, or a failure, expands to nothing. */
export type PlaceholderExport = (input: PlaceholderInput) => string | Promise<string>;
