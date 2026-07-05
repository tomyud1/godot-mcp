/**
 * Script and file management tools for Godot MCP Server
 * Tools for editing scripts, managing files, and validating code
 */

import type { ToolDefinition } from '../types.js';

export const scriptTools: ToolDefinition[] = [
  {
    name: 'edit_script',
    description: 'Replace a script file and return parse validation. For small edits prefer patch_file_lines.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Existing res:// script path' },
        content: { type: 'string', description: 'Complete replacement contents' }
      },
      required: ['path', 'content']
    }
  },
  {
    name: 'patch_file_lines',
    description: 'Apply exact line insert, replace, or delete edits and return numbered context.',
    inputSchema: { type: 'object', properties: {
      path: { type: 'string' },
      edits: { type: 'array', items: { type: 'object', properties: {
        start_line: { type: 'number' }, end_line: { type: 'number' }, content: { type: 'string' },
        mode: { type: 'string', enum: ['replace', 'insert', 'delete'] }
      }, required: ['start_line', 'end_line', 'content'] } },
      context_lines: { type: 'number' }
    }, required: ['path', 'edits'] }
  },
  {
    name: 'spaces_to_tabs',
    description: 'Convert leading indentation spaces to tabs in a text file.',
    inputSchema: { type: 'object', properties: {
      path: { type: 'string' }, spaces_per_tab: { type: 'number' }
    }, required: ['path'] }
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
    description: 'Permanently delete a file from the project. REQUIRES confirm=true as an explicit safety gate \u2014 omitting confirm returns an error. Creates a .bak backup alongside the original by default (disable with create_backup=false). REFUSES if the file is currently open in the editor (any scene tab or script editor tab); close the tab first, or pass force=true to bypass the check (not recommended \u2014 deleting the active scene out from under the editor can crash Godot). Use ONLY when deletion is explicitly requested; NEVER as a way to "edit" or "reset" a file (use edit_script instead). Does not delete directories.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Path to the file to delete (e.g. res://scenes/old.tscn)'
        },
        confirm: {
          type: 'boolean',
          description: 'REQUIRED. Must be explicitly set to true \u2014 safety gate to prevent accidental deletes. Calls without confirm=true fail with an error.'
        },
        create_backup: {
          type: 'boolean',
          description: 'If true (default), saves a .bak copy next to the original before deletion so the file can be recovered. Set false to delete without backup.'
        },
        force: {
          type: 'boolean',
          description: 'If true, bypass the "file is open in editor" guard. Use ONLY if you know the file is not the active scene. The guard exists because deleting the active scene tab from under the editor can crash Godot.'
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
  },
  {
    name: 'rename_file_with_references',
    description: 'Rename a file and repair text references in project resources.',
    inputSchema: { type: 'object', properties: { path: { type: 'string' }, new_path: { type: 'string' } }, required: ['path', 'new_path'] }
  },
  {
    name: 'move_file_with_references',
    description: 'Move a file and repair text references in project resources.',
    inputSchema: { type: 'object', properties: { path: { type: 'string' }, new_path: { type: 'string' } }, required: ['path', 'new_path'] }
  }
];
