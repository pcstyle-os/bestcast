"use strict";

// Two rows for "ab"; the third has no title and must be dropped by the host's decoder.
module.exports.default = async ({ query }) => {
  if (query !== "ab") return [];
  return [
    { id: "t-1", title: "ABC-1 Fix login", subtitle: "Open", icon: "ticket",
      actions: [{ type: "copy", content: "ABC-1" }, { type: "open", target: "https://example.com/ABC-1" }] },
    { id: "t-2", title: "ABC-2\nLine two", actions: [{ type: "open", target: "file-scheme:nope" }] },
    { id: "t-3" },
  ];
};

module.exports.answer = ({ query }) => `${query.length} points`;

module.exports.share = ({ kind, item }) => `Shared ${kind} ${item.name}`;
