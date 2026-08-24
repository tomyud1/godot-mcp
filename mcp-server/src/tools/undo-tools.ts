/**
 * Undo / redo / history tools for Godot MCP Server.
 *
 * Backed by a disk snapshot ring buffer in the plugin (see
 * addons/godot_mcp/utils/snapshot_store.gd). Every mutating MCP tool call
 * automatically captures a snapshot of the affected files BEFORE running.
 * `mcp_undo` restores the most recent snapshot(s); `mcp_redo` re-applies
 * what was just undone.
 *
 * IMPORTANT: this is the AI-only undo lever. The user's native Ctrl+Z in
 * the Godot editor does NOT reach AI-applied changes (we never wired into
 * EditorUndoRedoManager because every mutating tool here loads-mutates-saves
 * the .tscn on disk rather than touching the editor's live tree). If the
 * user wants to revert an AI change, they must ask the AI to call mcp_undo.
 */

import type { ToolDefinition } from '../types.js';

export const undoTools: ToolDefinition[] = [
  {
    name: 'mcp_undo',
    description:
      "Roll back the most recent MCP mutation(s). Use this proactively — not just when the user asks — any time you want to recover from a mistake, clean up after a partial failure, or try a different approach. " +
      "Specifically: call this if a tool call produced an error or unexpected result and you want a clean slate before retrying; if a multi-step sequence failed midway and you need to undo the steps that did succeed; or if get_errors shows new problems immediately after a mutation. " +
      "Also use when the user says \"undo\", \"revert\", \"go back\", \"restore\", \"that was wrong\", \"put it back\", or similar. " +
      "Prefer this over manually re-applying old values — it's exact (no guessing the prior state), atomic, and keeps the history clean. " +
      "Only covers mutations made by MCP tools; does not cover changes the user made manually in the editor. " +
      "Pass count to undo more than one entry in order; pass preview=true to see what would be undone without performing it (or call mcp_undo_history for a richer listing). " +
      "After undo, scenes/scripts open in the editor are automatically reloaded.",
    inputSchema: {
      type: 'object',
      properties: {
        count: {
          type: 'number',
          description: 'Number of entries to undo from the top of the stack. Defaults to 1. Stops early if the stack runs out.',
        },
        preview: {
          type: 'boolean',
          description: 'If true, return what *would* be undone without performing the undo. Use to verify before committing.',
        },
      },
    },
  },
  {
    name: 'mcp_redo',
    description:
      "Re-apply the most recently undone MCP mutation(s). Use this proactively whenever you've over-undone — for example, you walked back several steps to inspect intermediate state, or you undid in error and want to recover the change without re-deriving its arguments. " +
      "Also use when the user says \"redo\", \"put it back\", \"never mind, do it again\", or similar. " +
      "Prefer this over re-issuing the original tool call — it restores the exact post-mutation state with no guessing. " +
      "After mcp_undo, undone entries land on a redo stack that mcp_redo replays in order. The redo stack is cleared whenever a NEW mutation is performed (standard undo semantics), so redo only works until the next mutation. " +
      "Pass count to redo multiple entries; pass preview=true to inspect without applying.",
    inputSchema: {
      type: 'object',
      properties: {
        count: {
          type: 'number',
          description: 'Number of entries to redo. Defaults to 1.',
        },
        preview: {
          type: 'boolean',
          description: 'If true, return what *would* be redone without performing it.',
        },
      },
    },
  },
  {
    name: 'mcp_undo_history',
    description:
      "List the undo and redo stacks: tool name, args summary, files affected, and age in seconds for each entry. Use to decide how far to undo (then call mcp_undo with the chosen count) or to confirm a specific change is still on the stack. " +
      "Returns {undo: [...newest-first], redo: [...newest-first], cap: {entries, max_entries, bytes, max_bytes}}.",
    inputSchema: {
      type: 'object',
      properties: {
        limit: {
          type: 'number',
          description: 'Max entries to return per stack. Defaults to 20.',
        },
      },
    },
  },
];
