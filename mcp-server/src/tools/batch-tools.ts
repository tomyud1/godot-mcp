/**
 * Batch execution tool for Godot MCP Server.
 *
 * Runs a list of sub-commands as a single MCP call. All snapshots from the
 * sub-commands are collapsed into ONE undo entry, so a single `mcp_undo`
 * reverts the entire batch. In atomic mode (default) any sub-command failure
 * rolls back every earlier successful step before returning.
 */

import type { ToolDefinition } from '../types.js';

export const batchTools: ToolDefinition[] = [
  {
    name: 'batch_execute',
    description:
      "Run an ordered list of MCP tool calls as a single composite operation. " +
      "Use this whenever you would otherwise issue multiple consecutive mutations on the same scene/script/project — e.g. \"create a node, set 5 properties, attach a script, connect 2 signals\" becomes one call instead of 9. " +
      "Cuts round-trip latency, response tokens, and per-call error handling. The whole batch lands as ONE undo entry, so a single `mcp_undo` reverts everything.\n\n" +
      "Modes:\n" +
      "  • atomic=true (default): on any failure, every earlier successful step is rolled back from snapshots before returning. The batch either fully applies or appears never to have happened.\n" +
      "  • atomic=false, stop_on_error=true (default): stop at first failure; successful steps are committed as a partial entry that mcp_undo can revert.\n" +
      "  • atomic=false, stop_on_error=false: run every command regardless; commit whatever succeeded.\n\n" +
      "Each command is `{name: <tool>, args: <object>}`. Sub-commands run in order and reuse the normal tool dispatch path (same validation, same error shape).\n\n" +
      "Disallowed inside a batch: `batch_execute` (no nesting), `mcp_undo` / `mcp_redo` / `mcp_undo_history` (would corrupt the in-progress entry), `wait` (coroutine), `run_scene` / `stop_scene` (process lifecycle isn't snapshotable). Read-only tools (read_scene, get_node_properties, etc.) are fine to include.\n\n" +
      "Response: `{ok, atomic, stop_on_error, succeeded, total, results: [{ok, name, result}], failed_at?, failed_command?, error?, failures?, rolled_back?, rollback_errors?, undo_entry_id?}`. `results` length is `succeeded + failures.length` (early-broken batches stop after the first failure, so `results.length` can be less than `total`). The top-level `failed_at` / `failed_command` / `error` always describe the FIRST failure; `failures: [{index, name, error}]` lists EVERY failure (only relevant when atomic=false, stop_on_error=false, where multiple sub-commands can fail).",
    inputSchema: {
      type: 'object',
      properties: {
        commands: {
          type: 'array',
          items: {
            type: 'object',
            description:
              'A sub-command: {name: <tool>, args: <object>}. The `tool` key is also accepted as an alias for `name`.',
          },
          description:
            'Ordered list of sub-commands to run. Each entry is {name: <tool-name>, args: <object>}. Sub-commands run sequentially; earlier results are NOT piped into later args (build the args before sending). Must be non-empty.',
        },
        atomic: {
          type: 'boolean',
          description:
            'Default true. When true, any sub-command failure rolls back every earlier successful step from snapshots and discards the entry. When false, successful steps stay in place and the partial entry is committed (undoable via mcp_undo).',
        },
        stop_on_error: {
          type: 'boolean',
          description:
            'Default true. Only meaningful when atomic=false. When true the batch stops at the first failure; when false it continues through errors, executing every command. Ignored when atomic=true (which always stops on first failure to roll back).',
        },
      },
      required: ['commands'],
    },
  },
];
