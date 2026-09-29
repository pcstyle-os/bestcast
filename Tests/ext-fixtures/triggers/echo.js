"use strict";
exports.default = async function (props) {
  return props.launchContext?.bestcastTrigger?.type ?? props.arguments.text;
};
