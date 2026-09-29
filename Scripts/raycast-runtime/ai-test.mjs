import assert from "node:assert/strict";
import { createHarness, bootConfig } from "./test.mjs";

async function run(source, stubs, accessible = true) {
  const harness = createHarness({ stubs });
  harness.boot(bootConfig());
  harness.start("ai", `const { AI, environment } = require("@raycast/api");
    module.exports.default = async () => { ${source} };`, "/ai.js", "/", "no-view", {
    environment: { canAccessAI: accessible },
  });
  try {
    for (let i = 0; i < 100 && !harness.state.finished && !harness.state.failures.length; i++) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.deepEqual(harness.state.failures, []);
    assert.equal(harness.state.finished, true);
  } finally { harness.stop("ai"); }
}

let chunks = ["hello ", "world", null];
await run(`
  if (!environment.canAccess(AI) || environment.canAccess({})) throw Error("capability");
  if (AI.Model["OpenAI_GPT-4o"] !== "openai-gpt-4o") throw Error("enum");
  const reply = AI.ask("test", { model: AI.Model["OpenAI_GPT-4o"], creativity: AI.Creativity.High });
  const parts = [];
  reply.on("data", part => parts.push(part));
  if (await reply !== "hello world" || parts.join("|") !== "hello |world") throw Error("stream");
`, {
  "ai.start": ([id, prompt, options]) => {
    assert.equal(prompt, "test");
    assert.deepEqual(options, { model: "openai-gpt-4o", creativity: "high" });
  },
  "ai.receive": () => chunks.shift(), "ai.cancel": () => {},
});
await run(`
  if (environment.canAccess(AI)) throw Error("capability");
  try { await AI.ask("test"); throw Error("should reject"); }
  catch (error) { if (!error.message.includes("Choose a default AI model")) throw error; }
`, { "ai.start": () => { throw Error("Choose a default AI model in Settings."); }, "ai.cancel": () => {} }, false);
let cancelled = false;
await run(`
  const controller = new AbortController();
  const reply = AI.ask("test", { signal: controller.signal });
  reply.on("data", () => controller.abort());
  try { await reply; throw Error("should abort"); }
  catch (error) { if (error.name !== "AbortError") throw error; }
`, { "ai.start": () => {}, "ai.receive": () => "chunk", "ai.cancel": () => { cancelled = true; } });
assert.equal(cancelled, true);
await run(`
  const controller = new AbortController(); controller.abort();
  try { await AI.ask("test", { signal: controller.signal }); throw Error("should abort"); }
  catch (error) { if (error.name !== "AbortError") throw error; }
`, { "ai.start": () => { throw Error("must not start"); } });
console.log("AI.ask streaming, final result, enums, capability, missing route and abort passed");
