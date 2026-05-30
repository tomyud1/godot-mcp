/**
 * LSP-powered tools for Godot MCP Server.
 *
 * These tools are handled locally by the TypeScript server via a direct
 * TCP connection to Godot's built-in Language Server Protocol server,
 * rather than through the WebSocket bridge to the Godot plugin.
 */

import type { ToolDefinition } from '../types.js';

export const lspTools: ToolDefinition[] = [
  {
    name: 'validate_script',
    description: 'Validate a GDScript file for syntax errors using Godot\'s Language Server Protocol (LSP). Returns structured diagnostics with precise line/column numbers, error codes, and severity levels. Requires Godot editor with Language Server enabled (Editor Settings → Network → Language Server → Enable).',
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
    name: 'goto_definition',
    description: 'Find the definition of a symbol at a given position in a GDScript file. Returns the file, line, and column where the symbol is defined. Useful for understanding where classes, functions, variables, etc. are declared.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Path to the GDScript file (e.g., res://scripts/player.gd)'
        },
        line: {
          type: 'number',
          description: '0-based line number of the symbol'
        },
        character: {
          type: 'number',
          description: '0-based character offset within the line'
        }
      },
      required: ['path', 'line', 'character']
    }
  },
  {
    name: 'find_references',
    description: 'Find all references to a symbol at a given position throughout the project. Returns a list of locations (file, line, character) where the symbol is used. Requires Godot editor with Language Server enabled.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Path to the GDScript file (e.g., res://scripts/player.gd)'
        },
        line: {
          type: 'number',
          description: '0-based line number of the symbol'
        },
        character: {
          type: 'number',
          description: '0-based character offset within the line'
        },
        include_declaration: {
          type: 'boolean',
          description: 'Whether to include the declaration itself in results (default: true)'
        }
      },
      required: ['path', 'line', 'character']
    }
  },
  {
    name: 'get_symbol_info',
    description: 'Get hover information (type, documentation, signature) for a symbol at a given position in a GDScript file. Useful for understanding variable types, function parameters, and class documentation.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Path to the GDScript file (e.g., res://scripts/player.gd)'
        },
        line: {
          type: 'number',
          description: '0-based line number of the symbol'
        },
        character: {
          type: 'number',
          description: '0-based character offset within the line'
        }
      },
      required: ['path', 'line', 'character']
    }
  },
  {
    name: 'list_document_symbols',
    description: 'List all symbols (classes, functions, variables, signals, etc.) in a GDScript file with their hierarchy. Returns a tree of symbols with names, kinds, and line numbers. Useful for getting an overview of a file\'s structure.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Path to the GDScript file (e.g., res://scripts/player.gd)'
        }
      },
      required: ['path']
    }
  },
];
