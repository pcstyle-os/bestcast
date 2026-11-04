// The `require` an extension bundle sees. Bundles are single-file CJS with `react`,
// `react/jsx-runtime`, `@raycast/api` and the Node builtins left external — exactly the set below.
// `ray build` 2.10+ also leaves shared dependencies such as `@raycast/utils` external, emitting them
// as CJS packages in a `node_modules` beside the bundles; those resolve the way Node would.

import { nodeModules } from "./node-shims.js";

const { fs, path } = nodeModules;
const registry = new Map();

export function defineModule(name, exports) {
  registry.set(name, exports);
}

for (const name of Object.keys(nodeModules)) defineModule(name, nodeModules[name]);

function requireFrom(name, dirname, cache) {
  const key = String(name);
  if (registry.has(key)) return registry.get(key);
  const file = resolveFile(key, dirname);
  if (file) {
    if (!cache.has(file)) {
      const source = fs.readFileSync(file, "utf8");
      if (file.endsWith(".json")) cache.set(file, { exports: JSON.parse(source) });
      else load(source, file, path.dirname(file), cache);
    }
    return cache.get(file).exports;
  }
  // Deep imports into a provided package (`react-dom/client`) resolve to the package itself rather
  // than exploding, which is enough for the handful of bundles that reference them defensively.
  const root = packageName(key);
  if (registry.has(root)) return registry.get(root);
  throw new Error(
    `Cannot find module '${key}'. Bestcast provides React, @raycast/api, a subset of Node builtins and the extension's own node_modules — see docs/features/extensions.md.`,
  );
}

function packageName(key) {
  return key.startsWith("@") ? key.split("/").slice(0, 2).join("/") : key.split("/")[0];
}

function resolveFile(key, dirname) {
  if (key.startsWith("./") || key.startsWith("../") || key.startsWith("/")) {
    return existingFile(path.resolve(dirname, key));
  }
  const name = packageName(key);
  for (let dir = dirname; ; dir = path.dirname(dir)) {
    const root = path.join(dir, "node_modules", name);
    if (fs.existsSync(path.join(root, "package.json"))) return packageEntry(root, "." + key.slice(name.length));
    if (dir === path.dirname(dir)) return undefined;
  }
}

function packageEntry(root, subpath) {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const { exports } = manifest;
  if (exports === undefined) {
    return existingFile(path.resolve(root, subpath === "." ? (manifest.main ?? "index.js") : subpath));
  }
  const bySubpath =
    typeof exports === "object" && Object.keys(exports).some((entry) => entry.startsWith("."))
      ? exports
      : { ".": exports };
  const target = exportTarget(bySubpath[subpath]);
  return target ? existingFile(path.resolve(root, target)) : undefined;
}

function exportTarget(value) {
  if (typeof value === "string") return value;
  if (value && typeof value === "object") return exportTarget(value.require ?? value.node ?? value.default);
  return undefined;
}

function existingFile(file) {
  return [file, `${file}.js`, `${file}.json`, path.join(file, "index.js")].find(
    (candidate) => fs.statSync(candidate, { throwIfNoEntry: false })?.isFile(),
  );
}

function load(code, filename, dirname, cache) {
  const module = { exports: {}, id: filename, filename, loaded: false, children: [], paths: [] };
  cache.set(filename, module);
  const factory = globalThis.__bestcastCompile(code, filename);
  factory(module.exports, (name) => requireFrom(name, dirname, cache), module, filename, dirname);
  module.loaded = true;
  return module.exports;
}

/// Evaluate one CJS bundle. `filename`/`dirname` matter: extensions resolve bundled assets relative
/// to `__dirname`, and `environment.assetsPath` points at the same directory.
export function evaluateCommonJS(code, filename, dirname) {
  return load(code, filename, dirname, new Map());
}
