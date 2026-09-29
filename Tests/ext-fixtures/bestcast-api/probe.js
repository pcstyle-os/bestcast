"use strict";
const { showHUD } = require("@raycast/api");
const bestcast = require("@bestcast/api");

module.exports.default = async function () {
  const sum = await bestcast.calculator.evaluate("2+2");
  const [entry] = await bestcast.clipboardHistory.search("x");
  let refusal = "none";
  try {
    await bestcast.notes.read();
  } catch (error) {
    refusal = error instanceof bestcast.BestcastPermissionError
      ? `${error.capability}: ${error.message}`
      : `plain: ${error.message}`;
  }
  const copied = entry.copiedAt instanceof Date ? entry.copiedAt.getUTCFullYear() : "no date";
  await showHUD(`${sum.result}|${entry.preview}|${copied}|${refusal}`);
};
