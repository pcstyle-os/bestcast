"use strict";
const { showHUD, WindowManagement } = require("@raycast/api");

module.exports.default = async function () {
  const active = await WindowManagement.getActiveWindow();
  await WindowManagement.setWindowBounds({ id: active.id, bounds: { size: { width: 640 } } });
  const desktops = await WindowManagement.getDesktops();
  await showHUD(`${active.id}|${active.application.name}|${desktops.length}`);
};
