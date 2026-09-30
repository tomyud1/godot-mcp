#!/usr/bin/env node
/**
 * Verify that the TypeScript tool registry, the Godot plugin's handler table,
 * and the guides all agree.
 *
 * The README asks contributors to "update both the TypeScript tool definitions
 * and the Godot plugin handlers" — but nothing enforced it, and it had quietly
 * drifted: the tool-index guide advertised four commands that exist only as
 * visualizer-internal handlers and were never callable as MCP tools.
 *
 * The invariant checked here:
 *
 *   every TS tool that has no editor-side GDScript handler must be listed in
 *   RUNTIME_ONLY_TOOLS (i.e. deliberately routed to the in-game autoload)
 *
 * Run after `npm run build`, which produces dist/.
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..', '..');
const addonDir = resolve(repoRoot, 'addons', 'godot_mcp');

const { allTools, advertisedTools } = await import(resolve(__dirname, '..', 'dist', 'tools', 'index.js'));
const { RUNTIME_ONLY_TOOLS } = await import(resolve(__dirname, '..', 'dist', 'godot-bridge.js'));
const { GUIDES } = await import(resolve(__dirname, '..', 'dist', 'resources.js'));

const errors = [];
const tsTools = new Set(allTools.map((t) => t.name));
const runtimeOnly = new Set(RUNTIME_ONLY_TOOLS);

// --- 1. TS registry vs GDScript handler table ------------------------------

const executorSrc = readFileSync(resolve(addonDir, 'tool_executor.gd'), 'utf8');
// Handler entries look like:  &"tool_name": [_some_tools, &"method"],
// (the coroutine set is `"name": true,` and must not be picked up here)
const handlerKeys = new Set(
  [...executorSrc.matchAll(/&"([a-z_0-9]+)":\s*\[/g)].map((m) => m[1])
);

const unhandled = [...tsTools].filter((t) => !handlerKeys.has(t)).sort();
const notDeclaredRuntime = unhandled.filter((t) => !runtimeOnly.has(t)).sort();

if (notDeclaredRuntime.length > 0) {
  errors.push(
    `TS tools with no GDScript handler and not in RUNTIME_ONLY_TOOLS (would fail at runtime):\n  ` +
      notDeclaredRuntime.join('\n  ')
  );
}
if (unhandled.length !== runtimeOnly.size) {
  errors.push(
    `RUNTIME_ONLY_TOOLS has ${runtimeOnly.size} entries but ${unhandled.length} tools are unhandled. ` +
      `RUNTIME_ONLY_TOOLS=[${[...runtimeOnly].sort().join(', ')}] vs unhandled=[${unhandled.join(', ')}]`
  );
}

// --- 2. Guides must not advertise tools that cannot be called -------------

const nonToolNames = new Set([
  // assert_runtime assertion kinds
  'node_exists', 'node_visible', 'node_inside_viewport', 'rect_contains_point',
  'text_matches', 'property_equals', 'group_count', 'no_errors',
  // parameter names, response fields, arg values
  'action', 'children', 'groups', 'height', 'node_type', 'nodes', 'note',
  'runtime_connected', 'scale', 'script', 'synchronized', 'width',
  'save_path', 'property', 'value', 'path', 'code', 'slug', 'group',
  'query', 'text', 'contains', 'equals', 'max', 'visible', 'point', 'x', 'y',
  'node_paths', 'checks', 'return', 'save_to', 'viewport_index', 'force_draw',
]);

const phantom = [];
for (const guide of GUIDES) {
  for (const m of guide.text.matchAll(/`([a-z_0-9]+)`/g)) {
    const name = m[1];
    if (tsTools.has(name) || nonToolNames.has(name)) continue;
    phantom.push(`  guide "${guide.slug}" references "${name}", which is not a registered tool`);
  }
}
if (phantom.length > 0) errors.push(`Guides advertise non-existent tools:\n${phantom.join('\n')}`);

// --- 3. Structural sanity --------------------------------------------------

const advertisedNames = advertisedTools.map((t) => t.name);
if (new Set(advertisedNames).size !== advertisedNames.length) {
  errors.push('Duplicate tool names in the advertised list');
}
for (const tool of allTools.filter((t) => t.hidden)) {
  if (!/DEPRECATED ALIAS of (\w+)/.test(tool.description)) {
    errors.push(`Hidden tool "${tool.name}" must say which canonical tool to use instead`);
  }
}

// --- Report ----------------------------------------------------------------

console.log(`tools: ${allTools.length} dispatchable, ${advertisedTools.length} advertised`);
console.log(`godot handlers: ${handlerKeys.size}`);
console.log(`runtime-routed: ${runtimeOnly.size} (${[...runtimeOnly].sort().join(', ')})`);

if (errors.length > 0) {
  console.error('\nFAIL — tool surface is out of sync:\n');
  for (const e of errors) console.error(`  ${e}\n`);
  process.exit(1);
}
console.log('\nOK — TS registry, Godot handlers and guides agree.');
