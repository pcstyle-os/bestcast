// `@bestcast/api` and the Raycast APIs it backs, against the built runtime.
//
//   node fixtures-bestcast.mjs

import assert from "node:assert/strict";
import { createHarness, bootConfig } from "./test.mjs";

async function run(source, stubs) {
  const calls = [];
  const wrapped = Object.fromEntries(
    Object.entries(stubs).map(([name, stub]) => [name, (args) => { calls.push([name, args]); return stub(args); }]),
  );
  const harness = createHarness({ stubs: wrapped });
  harness.boot(bootConfig());
  harness.start("b", `const raycast = require("@raycast/api"); const bestcast = require("@bestcast/api");
    module.exports.default = async () => { ${source} };`, "/b.js", "/", "no-view", {});
  try {
    for (let i = 0; i < 100 && !harness.state.finished && !harness.state.failures.length; i++) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.deepEqual(harness.state.failures, []);
    assert.equal(harness.state.finished, true);
  } finally { harness.stop("b"); }
  return calls;
}

const window = {
  id: "42", active: true, desktopId: "D", positionable: true, resizable: true, fullScreenSettable: true,
  bounds: { position: { x: 1, y: 2 }, size: { width: 3, height: 4 } },
  application: { name: "Finder", bundleId: "com.apple.finder", path: "" },
};

let calls = await run(`
  const active = await raycast.WindowManagement.getActiveWindow();
  if (active.id !== "42" || active.bounds.size.width !== 3) throw Error("active window");
  if (raycast.WindowManagement.DesktopType.User !== "User") throw Error("enum");
  await raycast.WindowManagement.setWindowBounds({ id: "42", bounds: { position: { x: 10 } } });
`, {
  "bestcast.windows.active": () => window,
  "bestcast.windows.setWindowBounds": () => undefined,
});
assert.deepEqual(calls.map(([name]) => name), ["bestcast.windows.active", "bestcast.windows.setWindowBounds"]);
assert.deepEqual(calls[1][1], [{ id: "42", bounds: { position: { x: 10 } } }]);

calls = await run(`
  if (bestcast.version !== "1.0.0" || bestcast.default !== bestcast) throw Error("module");
  const sum = await bestcast.calculator.evaluate("2+2");
  if (sum.result !== "4") throw Error("calculator");
  const [entry] = await bestcast.clipboardHistory.search("x", { limit: 1 });
  if (!(entry.copiedAt instanceof Date) || entry.copiedAt.getUTCFullYear() !== 2026) throw Error("date");
  await bestcast.calendar.events({ from: new Date("2026-01-01T00:00:00Z"), to: "2026-01-02T00:00:00Z" });
  await bestcast.ai.tools.call("notes_read", { a: 1 });
  try { await bestcast.notes.read(); throw Error("should refuse"); }
  catch (error) {
    if (!(error instanceof bestcast.BestcastPermissionError)) throw error;
    if (error.capability !== "notes.read" || error.message !== "undeclared capability notes.read") throw error;
  }
  try { await bestcast.windows.list(); throw Error("should fail"); }
  catch (error) { if (error instanceof bestcast.BestcastPermissionError || error.message !== "boom") throw error; }
`, {
  "bestcast.calculator.evaluate": () => ({ result: "4", raw: 4 }),
  "bestcast.clipboardHistory.search": () =>
    [{ id: "a", kind: "text", preview: "x", copiedAt: "2026-02-03T04:05:06Z" }],
  "bestcast.calendar.events": () => [],
  "bestcast.ai.tools.call": () => "ok",
  "bestcast.notes.read": () => { throw Error("[bestcast-permission:notes.read] undeclared capability notes.read"); },
  "bestcast.windows.list": () => { throw Error("boom"); },
});
assert.deepEqual(calls.find(([name]) => name === "bestcast.calculator.evaluate")[1], ["2+2"]);
assert.deepEqual(calls.find(([name]) => name === "bestcast.clipboardHistory.search")[1], ["x", { limit: 1 }]);
assert.deepEqual(calls.find(([name]) => name === "bestcast.calendar.events")[1],
  [{ from: "2026-01-01T00:00:00.000Z", to: "2026-01-02T00:00:00Z" }]);
assert.deepEqual(calls.find(([name]) => name === "bestcast.ai.tools.call")[1], ["notes_read", '{"a":1}']);

console.log("WindowManagement, @bestcast/api calls, dates and BestcastPermissionError passed");
