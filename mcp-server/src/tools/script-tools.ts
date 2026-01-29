/**
 * Script and file management tools for Godot MCP Server
 * Tools for editing scripts, managing files, and validating code
 */

import type { ToolDefinition } from '../types.js';

export const scriptTools: ToolDefinition[] = [
  {
    name: 'apply_diff_preview',
    description: 'Apply a SMALL, SURGICAL code edit (1-10 lines) to GDScript files. Auto-applies changes. For large changes, call multiple times. ONLY for .gd files - NEVER for .tscn scene files.',
    inputSchema: {
      type: 'object',
      properties: {
        edit: {
          type: 'object',
          description: 'Edit spec: {type: "snippet_replace", file: "res://path.gd", old_snippet: "old code", new_snippet: "new code", context_before: "line above", context_after: "line below"}. Keep old_snippet SMALL (1-10 lines).'
        }
      },
      required: ['edit']
    }
  },
  {
    name: 'validate_script',
    description: 'Validate a GDScript file for syntax errors using Godot\'s built-in parser. Call after creating or modifying scripts to ensure they are error-free.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Path to the GDScript file to validate (e.g., res://scripts/player.gd)'
        }
      },
      required: ['path']
    }
  },
  {
    name: 'create_folder',
    description: 'Create a directory (with parent directories if needed).',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Directory path (res://path/to/folder)'
        }
      },
      required: ['path']
    }
  },
  {
    name: 'delete_file',
    description: 'Delete a file permanently. ONLY use when explicitly requested. NEVER use to "edit" a file.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'File to delete'
        },
        confirm: {
          type: 'boolean',
          description: 'Must be true to proceed'
        },
        create_backup: {
          type: 'boolean',
          description: 'Create backup before deleting (default: true)'
        }
      },
      required: ['path', 'confirm']
    }
  },
  {
    name: 'rename_file',
    description: 'Rename or move a file, optionally updating references in other files.',
    inputSchema: {
      type: 'object',
      properties: {
        old_path: {
          type: 'string',
          description: 'Current file path'
        },
        new_path: {
          type: 'string',
          description: 'New file path'
        },
        update_references: {
          type: 'boolean',
          description: 'Update references in other files (default: true)'
        }
      },
      required: ['old_path', 'new_path']
    }
  },
  {
    name: 'list_scripts',
    description: 'List all GDScript files in the project with basic metadata.',
    inputSchema: {
      type: 'object',
      properties: {}
    }
  }
];

export function getMockScriptToolResponse(toolName: string, args: Record<string, unknown>): unknown {
  const mockNote = { _mock: true, _note: 'Connect Godot for real results.' };

  switch (toolName) {
    case 'apply_diff_preview':
      return { ok: true, message: 'Mock: Diff would be applied', ...mockNote };
    case 'validate_script':
      return { ok: true, path: args.path, valid: true, errors: [], ...mockNote };
    case 'create_folder':
      return { ok: true, path: args.path, message: 'Mock: Folder would be created', ...mockNote };
    case 'delete_file':
      return { ok: true, path: args.path, message: 'Mock: File would be deleted', ...mockNote };
    case 'rename_file':
      return { ok: true, old_path: args.old_path, new_path: args.new_path, message: 'Mock: File would be renamed', ...mockNote };
    case 'list_scripts':
      return { ok: true, scripts: ['res://scripts/player.gd', 'res://scripts/enemy.gd'], count: 2, ...mockNote };
    default:
      return { error: `Unknown script tool: ${toolName}`, ...mockNote };
  }
}
