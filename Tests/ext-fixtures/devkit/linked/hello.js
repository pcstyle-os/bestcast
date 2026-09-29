"use strict";
const { environment, showHUD } = require("@raycast/api");
module.exports.default = async function () {
  console.log("hello from", environment.commandName);
  console.warn("careful");
  console.error("wrapped", new Error("kaboom"));
  await showHUD(environment.isDevelopment ? "dev" : "not dev");
};
