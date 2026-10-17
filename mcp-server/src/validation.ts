/**
 * Argument validation for every tool call.
 *
 * Each tool's inputSchema is the contract: calls are checked against it in one
 * place before anything reaches Godot. Unknown arguments, missing required
 * ones and wrong types are rejected with a "did you mean" hint, so a typo like
 * run_scene({scene_path}) fails loudly instead of being silently ignored.
 *
 * This module also owns the translation between public argument names and the
 * names the Godot plugin reads ("wire" names). Renamed arguments keep their
 * old name on the wire, so any plugin version works with any server version.
 */

import { Ajv } from 'ajv';
import type { ErrorObject, ValidateFunction } from 'ajv';
import type { PropertySchema, ToolDefinition } from './types.js';

// verbose: errors carry the offending value, used in messages.
const ajv = new Ajv({ allErrors: true, strict: false, verbose: true });
const compiled = new Map<string, ValidateFunction>();

export type PreparedCall =
  | { ok: true; args: Record<string, unknown>; deprecation?: string; notes: string[] }
  | { ok: false; errors: string[]; usage: string };

/** Tools that only make sense as direct calls (never inside batch_execute). */
const SERVER_ONLY_TOOLS = new Set(['get_godot_status', 'get_guide']);

/**
 * Validate a tool call and convert it to wire format.
 * `lookup` resolves tool names (used for batch_execute sub-commands).
 */
export function prepareToolCall(
  tool: ToolDefinition,
  rawArgs: Record<string, unknown>,
  lookup?: (name: string) => ToolDefinition | undefined,
): PreparedCall {
  const usage = formatUsage(tool);
  const notes: string[] = [];
  let args: Record<string, unknown> = { ...(rawArgs ?? {}) };

  if (tool.fromLegacy) {
    const converted = tool.fromLegacy(args);
    if (typeof converted === 'string') return { ok: false, errors: [converted], usage };
    args = converted;
  }

  const errors: string[] = [];
  const alternatives = { ...(tool.aliases ?? {}), ...(tool.renamedArgs ?? {}) };
  for (const [oldName, newName] of Object.entries(alternatives)) {
    if (!(oldName in args)) continue;
    if (newName in args) {
      errors.push(`'${oldName}' was renamed to '${newName}'; pass only '${newName}'`);
      continue;
    }
    args[newName] = args[oldName];
    delete args[oldName];
  }
  if (errors.length) return { ok: false, errors, usage };

  dropNullOptionals(args, tool);
  coerceStringifiedValues(args, tool.inputSchema.properties);

  const validate = getValidator(tool);
  if (!validate(args)) {
    return { ok: false, errors: formatErrors(validate.errors ?? [], tool), usage };
  }

  // batch_execute: every sub-command is validated and converted the same way.
  if (tool.name === 'batch_execute' && lookup) {
    const result = prepareBatchCommands(args.commands as unknown[], lookup);
    if (!result.ok) return { ok: false, errors: result.errors, usage };
    args.commands = result.commands;
    notes.push(...result.notes);
  }

  const wire = toWireArgs(tool, args);
  return {
    ok: true,
    args: wire,
    deprecation: tool.deprecated ? deprecationNotice(tool) : undefined,
    notes,
  };
}

/** Map validated public args to what the plugin reads. */
export function toWireArgs(tool: ToolDefinition, args: Record<string, unknown>): Record<string, unknown> {
  let wire: Record<string, unknown> = { ...args };
  for (const [oldName, newName] of Object.entries(tool.renamedArgs ?? {})) {
    if (newName in wire) {
      wire[oldName] = wire[newName];
      delete wire[newName];
    }
  }
  if (tool.toWire) wire = tool.toWire(wire);
  return wire;
}

export function deprecationNotice(tool: ToolDefinition): string {
  return `${tool.name} is deprecated and may be removed in a future release. Use ${tool.deprecated!.replacement}`;
}

/** One-line signature listing the tool's arguments, required ones first. */
export function formatUsage(tool: ToolDefinition): string {
  const props = tool.inputSchema.properties;
  const required = new Set(tool.inputSchema.required ?? []);
  const names = Object.keys(props).sort((a, b) => Number(required.has(b)) - Number(required.has(a)));
  const parts = names.map((n) => `${n}${required.has(n) ? '' : '?'}: ${describeType(props[n])}`);
  return `${tool.name}({ ${parts.join(', ')} })`;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

function getValidator(tool: ToolDefinition): ValidateFunction {
  const cached = compiled.get(tool.name);
  if (cached) return cached;
  // The advertised schema stays permissive for clients; validation adds
  // additionalProperties:false so unknown top-level arguments are caught.
  const v = ajv.compile({ ...tool.inputSchema, additionalProperties: false });
  compiled.set(tool.name, v);
  return v;
}

/**
 * Models often pass null for optional arguments they mean to leave out. Treat
 * that as omitted for typed, optional arguments. Untyped ones (like
 * set_node_properties values) keep null, where it means "clear".
 */
function dropNullOptionals(args: Record<string, unknown>, tool: ToolDefinition): void {
  const required = new Set(tool.inputSchema.required ?? []);
  for (const [key, value] of Object.entries(args)) {
    const schema = tool.inputSchema.properties[key];
    if (value === null && schema && (schema.type || schema.oneOf) && !required.has(key)) delete args[key];
  }
}

/**
 * Some MCP clients send object/array arguments as JSON strings, and numbers or
 * booleans as strings. The plugin has always tolerated that; do the same here
 * so validation sees real values.
 */
function coerceStringifiedValues(args: Record<string, unknown>, props: Record<string, PropertySchema>): void {
  for (const [key, schema] of Object.entries(props)) {
    const value = args[key];
    if (typeof value !== 'string') continue;
    const types = schemaTypes(schema);
    const trimmed = value.trim();
    if ((types.has('object') || types.has('array')) && /^[[{]/.test(trimmed)) {
      try {
        const parsed = JSON.parse(trimmed);
        if ((Array.isArray(parsed) && types.has('array')) || (isPlainObject(parsed) && types.has('object'))) {
          args[key] = parsed;
          continue;
        }
      } catch {
        // leave as-is; validation reports the type error
      }
    }
    if (types.has('number') && !types.has('string') && trimmed !== '' && Number.isFinite(Number(trimmed))) {
      args[key] = Number(trimmed);
    } else if (types.has('boolean') && !types.has('string') && (trimmed === 'true' || trimmed === 'false')) {
      args[key] = trimmed === 'true';
    }
  }
}

function prepareBatchCommands(
  commands: unknown[],
  lookup: (name: string) => ToolDefinition | undefined,
): { ok: true; commands: unknown[]; notes: string[] } | { ok: false; errors: string[] } {
  const errors: string[] = [];
  const notes: string[] = [];
  const out: unknown[] = [];
  commands.forEach((cmd, i) => {
    const at = `commands[${i}]`;
    if (!isPlainObject(cmd)) {
      errors.push(`${at}: must be an object {name, args}`);
      return;
    }
    for (const key of Object.keys(cmd)) {
      if (!['name', 'tool', 'args'].includes(key)) {
        errors.push(`${at}: unknown key '${key}'${didYouMean(key, ['name', 'args'])} (expected {name, args})`);
      }
    }
    const name = typeof cmd.name === 'string' ? cmd.name : typeof cmd.tool === 'string' ? cmd.tool : '';
    if (!name) {
      errors.push(`${at}: missing 'name'`);
      return;
    }
    if (SERVER_ONLY_TOOLS.has(name)) {
      errors.push(`${at}: '${name}' can't run inside batch_execute; call it directly`);
      return;
    }
    const sub = lookup(name);
    if (!sub) {
      errors.push(`${at}: unknown tool '${name}'`);
      return;
    }
    let subArgs: unknown = cmd.args ?? {};
    if (typeof subArgs === 'string') {
      try { subArgs = JSON.parse(subArgs); } catch { /* reported below */ }
    }
    if (!isPlainObject(subArgs)) {
      errors.push(`${at}.args: must be an object`);
      return;
    }
    const prepared = prepareToolCall(sub, subArgs, lookup);
    if (!prepared.ok) {
      for (const e of prepared.errors) errors.push(`${at} (${name}): ${e}`);
      return;
    }
    if (prepared.deprecation) notes.push(`${at}: ${prepared.deprecation}`);
    out.push({ name, args: prepared.args });
  });
  return errors.length ? { ok: false, errors } : { ok: true, commands: out, notes };
}

function formatErrors(errs: ErrorObject[], tool: ToolDefinition): string[] {
  const known = Object.keys(tool.inputSchema.properties);
  const out: string[] = [];
  const seen = new Set<string>();
  const push = (s: string) => {
    if (!seen.has(s)) {
      seen.add(s);
      out.push(s);
    }
  };
  // oneOf failures produce one error per branch; report the field once.
  const oneOfPaths = new Set(errs.filter((e) => e.keyword === 'oneOf').map((e) => e.instancePath));

  for (const e of errs) {
    const field = e.instancePath ? fieldName(e.instancePath) : '';
    if (oneOfPaths.has(e.instancePath) && e.keyword !== 'oneOf') continue;
    switch (e.keyword) {
      case 'additionalProperties': {
        const extra = String((e.params as { additionalProperty: string }).additionalProperty);
        if (!field) {
          push(`unknown argument '${extra}'${didYouMean(extra, known)}`);
        } else {
          push(`'${field}' has an unknown key '${extra}'`);
        }
        break;
      }
      case 'required': {
        const missing = String((e.params as { missingProperty: string }).missingProperty);
        push(field ? `'${field}' is missing '${missing}'` : `missing required argument '${missing}'`);
        break;
      }
      case 'type': {
        const expected = String((e.params as { type: string | string[] }).type);
        push(`'${field || 'arguments'}' must be ${article(expected)} (got ${jsonType(valueAt(e))})`);
        break;
      }
      case 'enum': {
        const allowed = (e.params as { allowedValues: unknown[] }).allowedValues;
        push(`'${field}' must be one of: ${allowed.map((a) => JSON.stringify(a)).join(', ')}`);
        break;
      }
      case 'oneOf': {
        const schema = e.parentSchema as PropertySchema | undefined;
        const options = (schema?.oneOf ?? []).map(describeType).join(' or ');
        push(`'${field}' must be ${options || 'one of the allowed shapes'}`);
        break;
      }
      default:
        push(`'${field || 'arguments'}' ${e.message ?? 'is invalid'}`);
    }
  }
  return out;

  function valueAt(err: ErrorObject): unknown {
    return (err as ErrorObject & { data?: unknown }).data;
  }
}

/** "/commands/0/args" -> "commands[0].args" */
function fieldName(instancePath: string): string {
  return instancePath
    .split('/')
    .filter(Boolean)
    .map((seg, i) => (/^\d+$/.test(seg) ? `[${seg}]` : i === 0 ? seg : `.${seg}`))
    .join('');
}

/**
 * " (did you mean 'x'?)" for the closest known name. Matches on shared
 * underscore-separated words first (scene_path -> scene), then edit distance
 * (pathh -> path).
 */
export function didYouMean(name: string, candidates: string[]): string {
  const lower = name.toLowerCase();
  const words = new Set(lower.split('_').filter((w) => w.length > 1));
  let best = '';
  let bestScore = 0;
  for (const c of candidates) {
    const cl = c.toLowerCase();
    const cWords = cl.split('_').filter((w) => w.length > 1);
    const shared = cWords.filter((w) => words.has(w)).length;
    const dist = editDistance(lower, cl);
    let score = 0;
    if (dist <= Math.max(1, Math.floor(lower.length / 3))) score = 3 - dist * 0.1;
    if (shared > 0) score = Math.max(score, 1 + shared / Math.max(words.size, cWords.length));
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  return best ? ` (did you mean '${best}'?)` : '';
}

function editDistance(a: string, b: string): number {
  const prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    let diag = prev[0];
    prev[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const tmp = prev[j];
      prev[j] = Math.min(prev[j] + 1, prev[j - 1] + 1, diag + (a[i - 1] === b[j - 1] ? 0 : 1));
      diag = tmp;
    }
  }
  return prev[b.length];
}

function schemaTypes(schema: PropertySchema): Set<string> {
  const out = new Set<string>();
  if (schema.type) out.add(schema.type);
  for (const branch of schema.oneOf ?? []) if (branch.type) out.add(branch.type);
  return out;
}

function describeType(schema: PropertySchema): string {
  if (schema.enum) return schema.enum.map((v) => JSON.stringify(v)).join(' | ');
  if (schema.oneOf) return schema.oneOf.map(describeType).join(' | ');
  if (schema.type === 'array') return `${schema.items ? describeType(schema.items) : 'any'}[]`;
  return schema.type ?? 'any';
}

function article(type: string): string {
  return /^[aeiou]/.test(type) ? `an ${type}` : `a ${type}`;
}

function jsonType(v: unknown): string {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'an array';
  if (typeof v === 'object') return 'an object';
  if (typeof v === 'string') return `a string ${JSON.stringify(v.length > 40 ? v.slice(0, 40) + '…' : v)}`;
  return `${typeof v} ${JSON.stringify(v)}`;
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}
