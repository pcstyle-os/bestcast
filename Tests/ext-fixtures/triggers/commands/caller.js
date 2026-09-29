"use strict";
const { launchCommand, LaunchType } = require("@raycast/api");
const { callExport, listExports } = require("@bestcast/api/compose");
exports.default = async function () {
  const echoed = await launchCommand({
    name: "echo", type: LaunchType.Background, arguments: { text: "hi" }, awaitResult: true,
  });
  const fired = await launchCommand({ name: "echo", type: LaunchType.Background });
  const shouted = await callExport("triggers-fixture", "shout", { payload: { text: "yo" } });
  const exports = await listExports();
  return { echoed, fired: fired === undefined, shouted, exports };
};
