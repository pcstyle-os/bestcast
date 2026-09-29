// Types for Bestcast's event triggers and composition. Nothing imports this at runtime; an
// extension author references it for editor help. See docs/features/extensions.md#automations.

export type BestcastTriggerType =
  | "clipboard.changed"
  | "app.activated"
  | "app.deactivated"
  | "schedule"
  | "system.wake"
  | "system.sleep"
  | "network.changed"
  | "selection.hotkey"
  | "deeplink";

export interface ClipboardPayload {
  kind: "text" | "image" | "file";
  /** Present only after the user also allowed this trigger to read copied text. */
  text?: string;
}

export interface AppPayload {
  bundleId: string;
  name: string;
}

export interface SchedulePayload {
  /** ISO 8601. */
  scheduledAt: string;
}

export interface SelectionPayload {
  selection: string;
}

export interface DeeplinkPayload {
  query: Record<string, string>;
}

/** `network.changed` reports reachability only: no interface, address or network name. */
export interface NetworkPayload {
  reachable: boolean;
}

export type BestcastTriggerPayload =
  | ClipboardPayload
  | AppPayload
  | SchedulePayload
  | SelectionPayload
  | DeeplinkPayload
  | NetworkPayload
  | Record<string, never>;

export interface BestcastTriggerEvent<Payload = BestcastTriggerPayload> {
  trigger: string;
  type: BestcastTriggerType;
  payload: Payload;
  /** The value the step before returned, on each `then` step. */
  previous?: unknown;
}

/** An export named by a trigger: `export default async function (event) { … }`. */
export type BestcastTriggerHandler<Payload = BestcastTriggerPayload> = (
  event: BestcastTriggerEvent<Payload>,
) => unknown | Promise<unknown>;

/** A command a trigger targets reads the event from `props.launchContext.bestcastTrigger`. */
export interface BestcastTriggerLaunchContext {
  bestcastTrigger: BestcastTriggerEvent;
}

/** `launchCommand` accepts this extra option; with it, a no-view command in the same extension
 * runs to completion and the promise resolves with what its default export returned. */
export interface BestcastLaunchOptions {
  awaitResult?: boolean;
}

export interface BestcastExportInfo {
  extension: string;
  name: string;
  description: string;
}

declare module "@bestcast/api/compose" {
  /** Another extension's export must be public, and the user approves each caller once. */
  export function callExport<Result = unknown>(
    extension: string,
    name: string,
    input?: unknown,
  ): Promise<Result>;
  /** Your own exports, plus every other extension's public ones. */
  export function listExports(): Promise<BestcastExportInfo[]>;
}

/** The `bestcast` object in package.json. */
export interface BestcastManifest {
  triggers?: Array<{
    name: string;
    title?: string;
    on: BestcastTriggerType;
    filter?: { kind?: "text" | "image" | "file"; match?: string };
    export?: string;
    command?: string;
    then?: Array<{ export: string }>;
    throttle?: string;
    schedule?: { every: string; weekdays?: number[] } | { at: string; weekdays?: number[] };
    bundleIds?: string[];
    replacesSelection?: boolean;
  }>;
  exports?: Array<{ name: string; export: string; public?: boolean; description?: string }>;
}
