"use strict";
exports.default = async function (event) {
  return String(event.payload.text ?? "").toUpperCase();
};
