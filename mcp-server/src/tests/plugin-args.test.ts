/**
 * Keeps each tool's schema and the Godot plugin in agreement.
 *
 * The server rejects arguments a schema doesn't declare, so:
 *   1. every argument the plugin reads must be declared (otherwise a working
 *      plugin feature becomes impossible to call), and
 *   2. every declared argument must be read by the plugin (otherwise the
 *      schema advertises something that is silently ignored).
 * Arguments are compared in wire format (after renames / toWire).
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, it, expect } from 'vitest';
import { allTools } from '../tools/index.js';
import { toWireArgs } from '../validation.js';
import { RUNTIME_ONLY_TOOLS } from '../godot-bridge.js';
import type { PropertySchema, ToolDefinition } from '../types.js';

const addonDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../addons/godot_mcp');
const read = (rel: string) => readFileSync(path.join(addonDir, rel), 'utf8');

const HANDLER_FILES: Record<string, string> = {
  _file_tools: 'tools/file_tools.gd',
  _scene_tools: 'tools/scene_tools.gd',
  _script_tools: 'tools/script_tools.gd',
  _project_tools: 'tools/project_tools.gd',
  _asset_tools: 'tools/asset_tools.gd',
  _visualizer_tools: 'tools/visualizer_tools.gd',
};

const BUILTINS: Record<string, string> = {
  mcp_undo: '_builtin_undo',
  mcp_redo: '_builtin_redo',
  mcp_undo_history: '_builtin_history',
  batch_execute: '_builtin_batch_execute',
};

/** Arguments consumed by the server/bridge rather than the plugin handler. */
const ROUTING_ARGS: Record<string, string[]> = {
  call_method: ['runtime'],           // bridge routes runtime:true to the game
  list_signal_connections: ['source'], // bridge routes source:"runtime" to the game
};

/** Body of `func name(` up to the next top-level func. */
function functionBody(source: string, name: string): string | null {
  const start = source.search(new RegExp(`^(static )?func ${name}\\(`, 'm'));
  if (start < 0) return null;
  const rest = source.slice(start + 1);
  const next = rest.search(/^(static )?func /m);
  return next < 0 ? rest : rest.slice(0, next);
}

/** Argument keys a handler reads, following helpers it passes `args` to. */
function readKeys(source: string, fn: string, seen = new Set<string>()): Set<string> {
  const keys = new Set<string>();
  if (seen.has(fn)) return keys;
  seen.add(fn);
  const body = functionBody(source, fn);
  if (!body) return keys;
  for (const m of body.matchAll(/args\.(?:get|has)\(\s*&?"([a-z_0-9]+)"/g)) keys.add(m[1]);
  for (const m of body.matchAll(/args\[\s*&?"([a-z_0-9]+)"\s*\]/g)) keys.add(m[1]);
  for (const m of body.matchAll(/\b([a-z_0-9]+)\([^()]*\bargs\b[^()]*\)/g)) {
    for (const k of readKeys(source, m[1], seen)) keys.add(k);
  }
  return keys;
}

function pluginKeys(toolName: string): Set<string> | null {
  const executor = read('tool_executor.gd');
  const keys = new Set<string>();
  let found = false;
  if (BUILTINS[toolName]) {
    found = true;
    for (const k of readKeys(executor, BUILTINS[toolName])) keys.add(k);
  }
  const mapped = executor.match(new RegExp(`&"${toolName}": \\[(_[a-z_]+), &"([a-z_0-9]+)"\\]`));
  if (mapped) {
    found = true;
    for (const k of readKeys(read(HANDLER_FILES[mapped[1]]), mapped[2])) keys.add(k);
  }
  const runtime = read('runtime/mcp_runtime.gd');
  if (RUNTIME_ONLY_TOOLS.has(toolName) || toolName === 'call_method' || toolName === 'list_signal_connections') {
    if (functionBody(runtime, `_${toolName}`) !== null) found = true;
    for (const k of readKeys(runtime, `_${toolName}`)) keys.add(k);
  }
  return found ? keys : null;
}

function sampleValue(schema: PropertySchema): unknown {
  switch (schema.type) {
    case 'string': return 'x';
    case 'number': return 1;
    case 'boolean': return true;
    case 'array': return [];
    case 'object': return {};
    default: return 1;
  }
}

function wireKeys(tool: ToolDefinition): Set<string> {
  const sample: Record<string, unknown> = {};
  for (const [k, schema] of Object.entries(tool.inputSchema.properties)) sample[k] = sampleValue(schema);
  return new Set(Object.keys(toWireArgs(tool, sample)));
}

describe('tool schemas match what the Godot plugin reads', () => {
  for (const tool of allTools) {
    it(tool.name, () => {
      const plugin = pluginKeys(tool.name);
      expect(plugin, `no plugin handler found for ${tool.name}`).not.toBeNull();
      const wire = wireKeys(tool);
      const routing = new Set(ROUTING_ARGS[tool.name] ?? []);
      // Alias spellings are accepted by the server and normalized to the
      // canonical name; the plugin may still read them for older servers.
      const aliases = new Set(Object.keys(tool.aliases ?? {}));
      const pluginOnly = [...plugin!].filter((k) => !k.startsWith('__') && !wire.has(k) && !aliases.has(k));
      const schemaOnly = [...wire].filter((k) => !plugin!.has(k) && !routing.has(k));
      expect(pluginOnly, `${tool.name}: plugin reads arguments the schema doesn't declare (server would reject them)`).toEqual([]);
      expect(schemaOnly, `${tool.name}: schema declares arguments the plugin never reads`).toEqual([]);
    });
  }
});
