// `@bestcast/api/compose`: call a function another extension exports, and get its value back.
// Swift decides who may call what: an export must be public, and the user approves each caller once.

import { hostCall } from "../host.js";

export function callExport(extension, name, input) {
  return hostCall("bestcastCompose", "callExport", [
    String(extension),
    String(name),
    input === undefined ? null : input,
  ]);
}

export function listExports() {
  return hostCall("bestcastCompose", "listExports", []);
}

export const composeModule = { callExport, listExports };
composeModule.default = composeModule;
