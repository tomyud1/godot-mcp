/**
 * File operation tools for Godot MCP Server
 * MVP tools: list_dir, read_file, search_project, create_script
 */

import type { ToolDefinition } from '../types.js';

export const fileTools: ToolDefinition[] = [
  {
    name: 'list_dir',
    description: 'List files and folders under a Godot project path (e.g., res://). Returns arrays of files and folders in the specified directory.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Folder to list, like res:// (default) or res://scenes'
        },
        include_hidden: {
          type: 'boolean',
          description: 'Include hidden files and folders (names starting with "."). Default: false.'
        }
      },
      required: []
    },
    renamedArgs: { root: 'path' }
  },
  {
    name: 'read_file',
    description: 'Read a text file from the Godot project, optionally a specific line range. Useful for reading GDScript files, scene files, or any text-based content.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'res:// path to the file (e.g., res://scripts/player.gd)'
        },
        start_line: {
          type: 'number',
          description: '1-based inclusive start line (optional)'
        },
        end_line: {
          type: 'number',
          description: 'Inclusive end line; 0 or missing means to end of file (optional)'
        },
        max_bytes: {
          type: 'number',
          description: 'Maximum bytes to return before truncating (default: 200000)'
        }
      },
      required: ['path']
    }
  },
  {
    name: 'search_project',
    description: 'Search the Godot project for a substring and return file hits with line numbers. Useful for finding usages of functions, variables, or any text pattern.',
    inputSchema: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Case-insensitive substring to find'
        },
        glob: {
          type: 'string',
          description: 'Optional glob filter like **/*.gd to search only GDScript files'
        },
        max_results: {
          type: 'number',
          description: 'Maximum matches to return (default: 200)'
        },
        case_sensitive: {
          type: 'boolean',
          description: 'Match case exactly (default: false)'
        }
      },
      required: ['query']
    }
  },
  {
    name: 'create_script',
    description: 'Create a NEW GDScript file (.gd) that does not exist yet. STRICTLY for .gd files — non-.gd extensions (.json, .gdignore, .md, etc.) are rejected with a pointer at write_file. A missing extension is auto-completed to .gd. Use edit_script for changes to an existing file. Use classdb_query to verify unfamiliar Godot class methods. After creating a script, consider run_scene and get_errors to verify it parses and behaves.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Script file path (res://scripts/player.gd) - must not exist yet'
        },
        content: {
          type: 'string',
          description: 'Full GDScript content to write to the file'
        }
      },
      required: ['path', 'content']
    }
  }
];
