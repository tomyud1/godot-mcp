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
        root: {
          type: 'string',
          description: 'Starting path like res://addons/ai_assistant or res://'
        }
      },
      required: ['root']
    }
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
        }
      },
      required: ['query']
    }
  },
  {
    name: 'create_script',
    description: 'Create a NEW GDScript file (.gd) that does not exist yet. Use this for creating new scripts, NOT for editing existing files (use apply_diff_preview for edits).',
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

/**
 * Get mock responses for file tools (Phase 1 - before Godot connection)
 */
export function getMockFileToolResponse(toolName: string, args: Record<string, unknown>): unknown {
  switch (toolName) {
    case 'list_dir':
      return {
        path: args.root || 'res://',
        files: ['project.godot', 'icon.svg', 'default_env.tres'],
        folders: ['scenes', 'scripts', 'assets', 'addons'],
        _mock: true,
        _note: 'This is mock data. Connect Godot for real results.'
      };

    case 'read_file':
      return {
        path: args.path,
        content: `# Mock file content for ${args.path}\n# Connect Godot to read actual file contents\nextends Node\n\nfunc _ready():\n    print("Hello from mock!")`,
        line_count: 5,
        _mock: true
      };

    case 'search_project':
      return {
        query: args.query,
        matches: [
          { file: 'res://scripts/player.gd', line: 10, content: `    # Mock match for "${args.query}"` },
          { file: 'res://scripts/enemy.gd', line: 25, content: `    # Another mock match for "${args.query}"` }
        ],
        total_matches: 2,
        _mock: true
      };

    case 'create_script':
      return {
        success: true,
        path: args.path,
        message: `Mock: Would create script at ${args.path}. Connect Godot to actually create the file.`,
        _mock: true
      };

    default:
      return {
        error: `Unknown file tool: ${toolName}`,
        _mock: true
      };
  }
}
