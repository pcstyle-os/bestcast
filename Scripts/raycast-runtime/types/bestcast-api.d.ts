// Types for `@bestcast/api`, Bestcast's native API for extensions. Each namespace needs its
// capability declared in package.json under "bestcast": { "capabilities": [...] }.

declare module "@bestcast/api" {
  export type CapabilityName =
    | "clipboardHistory.read"
    | "snippets.read"
    | "snippets.write"
    | "notes.read"
    | "notes.write"
    | "quicklinks.read"
    | "quicklinks.write"
    | "windows.read"
    | "windows.write"
    | "calendar.read"
    | "calculator"
    | "ai.handoff"
    | "ai.tools";

  export type CapabilityState = "granted" | "ask" | "denied" | "undeclared";

  /** Thrown when a capability is undeclared, denied, revoked or its feature is switched off. */
  export class BestcastPermissionError extends Error {
    readonly capability: CapabilityName;
  }

  export const version: string;

  export function capabilities(): Promise<{ name: CapabilityName; state: CapabilityState }[]>;
  /** Asks now rather than on first use; resolves true once granted. */
  export function requestCapability(name: CapabilityName): Promise<true>;

  export interface ClipboardEntry {
    id: string;
    kind: "text" | "image" | "file";
    text?: string;
    preview: string;
    copiedAt: Date;
    /** The bundle identifier of the app the copy came from. */
    sourceApp?: string;
  }

  export const clipboardHistory: {
    search(query: string, options?: { limit?: number; kind?: ClipboardEntry["kind"] }): Promise<ClipboardEntry[]>;
    read(id: string): Promise<{ text?: string; file?: string }>;
  };

  export interface Snippet {
    id: string;
    name: string;
    text: string;
    keyword?: string;
    enabled: boolean;
  }

  export const snippets: {
    list(): Promise<Snippet[]>;
    search(query: string): Promise<Snippet[]>;
    /** Asks the user on every call unless they chose Always Allow. */
    create(snippet: { name: string; text: string; keyword?: string }): Promise<{ id: string }>;
    expand(idOrKeyword: string, args?: Record<string, string>): Promise<string>;
  };

  export const notes: {
    read(): Promise<{ title: string; text: string }>;
    append(text: string): Promise<void>;
  };

  export interface Quicklink {
    id: string;
    name: string;
    link: string;
    arguments: string[];
    application?: string;
  }

  export const quicklinks: {
    list(): Promise<Quicklink[]>;
    open(id: string, query?: string): Promise<void>;
    create(quicklink: { name: string; link: string; application?: string }): Promise<{ id: string }>;
  };

  export interface Bounds {
    x: number;
    y: number;
    width: number;
    height: number;
  }

  export interface Window {
    id: string;
    app: string;
    bundleId: string;
    title: string;
    /** Global coordinates, origin at the top left of the main display. */
    bounds: Bounds;
    focused: boolean;
    /** One desktop per display: Spaces have no public API. */
    desktopId: string;
  }

  export const windows: {
    list(): Promise<Window[]>;
    setBounds(id: string, bounds: Partial<Bounds>): Promise<void>;
    applyLayout(name: string): Promise<void>;
    /** A window command such as "left-half" or "maximize", run on the front window. */
    runCommand(command: string): Promise<void>;
  };

  export const calendar: {
    events(range: { from: Date | string; to: Date | string }): Promise<
      { title: string; start: Date; end: Date; calendar: string; allDay: boolean; location?: string }[]
    >;
  };

  export const calculator: {
    evaluate(expression: string): Promise<{ result: string; raw?: string } | null>;
  };

  export const ai: {
    /** Opens Quick AI with the prompt staged, never sent. */
    openQuickAI(prompt?: string): Promise<void>;
    openChat(options?: { prompt?: string; mention?: string }): Promise<void>;
    tools: {
      list(): Promise<{ name: string; description: string; writes: boolean }[]>;
      /** A tool that writes asks the user on every call, as it does in AI Chat. */
      call(name: string, input?: Record<string, unknown> | string): Promise<string>;
    };
  };
}
