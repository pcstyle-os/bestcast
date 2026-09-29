import { hostCall } from "../host.js";
import { nestedEnums } from "./enums.generated.js";

let nextRequest = 1;

function ask(prompt, options = {}) {
  const id = String(nextRequest++);
  const listeners = new Set();
  const { signal } = options;
  let rejectAbort;
  let started = false;
  const aborted = new Promise((_, reject) => { rejectAbort = reject; });
  const abort = () => {
    const error = new Error("The AI request was aborted.");
    error.name = "AbortError";
    rejectAbort(error);
    if (started) hostCall("ai", "cancel", [id]).catch(() => {});
  };
  const completion = (async () => {
    if (signal?.aborted) { abort(); return aborted; }
    signal?.addEventListener("abort", abort, { once: true });
    started = true;
    await hostCall("ai", "start", [id, String(prompt), {
      model: options.model, creativity: options.creativity,
    }]);
    let text = "";
    while (!signal?.aborted) {
      const chunk = await hostCall("ai", "receive", [id]);
      if (signal?.aborted) break;
      if (chunk == null) return text;
      text += chunk;
      for (const listener of listeners) listener(chunk);
    }
    return aborted;
  })();
  const result = Promise.race([completion, aborted]).finally(() => {
    signal?.removeEventListener("abort", abort);
    if (started) hostCall("ai", "cancel", [id]).catch(() => {});
    listeners.clear();
  });
  result.on = (event, listener) => {
    if (event === "data") listeners.add(listener);
  };
  return result;
}

export const AI = {
  ask,
  Model: nestedEnums.AI.Model,
  Creativity: Object.freeze({ None: "none", Low: "low", Medium: "medium", High: "high", Maximum: "maximum" }),
};
