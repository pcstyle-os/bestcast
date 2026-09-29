// `@bestcast/api`: every member is one `bestcast` host call, and Swift decides whether it runs.

import { hostCall } from "../host.js";

const PERMISSION = /^\[bestcast-permission:([^\]]+)\] ?/;

export class BestcastPermissionError extends Error {
  constructor(message, capability) {
    super(message);
    this.name = "BestcastPermissionError";
    this.capability = capability;
  }
}

/// Swift can only reject with a message, so a refusal carries its capability as a prefix.
async function call(method, args = []) {
  try {
    return await hostCall("bestcast", method, args);
  } catch (error) {
    const match = PERMISSION.exec(String(error?.message ?? ""));
    if (!match) throw error;
    throw new BestcastPermissionError(error.message.slice(match[0].length), match[1]);
  }
}

const toDate = (value) => (value ? new Date(value) : value);

function withDates(item, keys) {
  if (!item || typeof item !== "object") return item;
  const copy = { ...item };
  for (const key of keys) if (key in copy) copy[key] = toDate(copy[key]);
  return copy;
}

const iso = (value) => (value instanceof Date ? value.toISOString() : value);

export const bestcastApi = {
  version: "1.0.0",
  BestcastPermissionError,

  capabilities: () => call("capabilities"),
  requestCapability: (name) => call("requestCapability", [String(name)]),

  clipboardHistory: {
    search: async (query = "", options = {}) =>
      (await call("clipboardHistory.search", [String(query), options])).map((item) =>
        withDates(item, ["copiedAt"])),
    read: (id) => call("clipboardHistory.read", [String(id)]),
  },

  snippets: {
    list: () => call("snippets.list"),
    search: (query = "") => call("snippets.search", [String(query)]),
    create: (snippet) => call("snippets.create", [snippet ?? {}]),
    expand: (idOrKeyword, args = {}) => call("snippets.expand", [String(idOrKeyword), args]),
  },

  notes: {
    read: () => call("notes.read"),
    append: (text) => call("notes.append", [String(text)]),
  },

  quicklinks: {
    list: () => call("quicklinks.list"),
    open: (id, query) => call("quicklinks.open", query === undefined ? [String(id)] : [String(id), String(query)]),
    create: (quicklink) => call("quicklinks.create", [quicklink ?? {}]),
  },

  windows: {
    list: () => call("windows.list"),
    setBounds: (id, bounds) => call("windows.setBounds", [String(id), bounds ?? {}]),
    applyLayout: (name) => call("windows.applyLayout", [String(name)]),
    runCommand: (command) => call("windows.runCommand", [String(command)]),
  },

  calendar: {
    events: async ({ from, to } = {}) =>
      (await call("calendar.events", [{ from: iso(from), to: iso(to) }])).map((event) =>
        withDates(event, ["start", "end"])),
  },

  calculator: {
    evaluate: (expression) => call("calculator.evaluate", [String(expression)]),
  },

  ai: {
    openQuickAI: (prompt) => call("ai.openQuickAI", prompt === undefined ? [] : [String(prompt)]),
    openChat: (options = {}) => call("ai.openChat", [options]),
    tools: {
      list: () => call("ai.tools.list"),
      call: (name, input = {}) =>
        call("ai.tools.call", [String(name), typeof input === "string" ? input : JSON.stringify(input)]),
    },
  },
};

bestcastApi.__esModule = true;
bestcastApi.default = bestcastApi;
