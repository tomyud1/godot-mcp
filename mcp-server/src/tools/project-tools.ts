/**
 * Project configuration and debug tools for Godot MCP Server
 * Tools for inspecting project settings, debugging, and editor interaction
 */

import type { ToolDefinition } from '../types.js';

export const projectTools: ToolDefinition[] = [
  {
    name: 'get_project_settings',
    description: 'Concise project settings summary: main_scene, window size/stretch, physics tick rate, and render basics.',
    inputSchema: {
      type: 'object',
      properties: {
        include_render: {
          type: 'boolean',
          description: 'Include render settings'
        },
        include_physics: {
          type: 'boolean',
          description: 'Include physics settings'
        }
      }
    }
  },
  {
    name: 'get_input_map',
    description: 'Return the InputMap: action names mapped to events (keys, mouse, gamepad).',
    inputSchema: {
      type: 'object',
      properties: {
        include_deadzones: {
          type: 'boolean',
          description: 'Include axis values/deadzones for joypad motion'
        }
      }
    }
  },
  {
    name: 'get_collision_layers',
    description: 'Return named 2D/3D physics collision layers from ProjectSettings.',
    inputSchema: {
      type: 'object',
      properties: {}
    }
  },
  {
    name: 'get_node_properties',
    description: 'Get available properties for a Godot node type. Use this to discover what properties exist on a node type (e.g., anchors_preset for Control, position for Node2D).',
    inputSchema: {
      type: 'object',
      properties: {
        node_type: {
          type: 'string',
          description: 'Node class name (e.g., "Sprite2D", "Control", "Label", "Button")'
        }
      },
      required: ['node_type']
    }
  },
  {
    name: 'get_console_log',
    description: 'Return the latest lines from the Godot editor output log.',
    inputSchema: {
      type: 'object',
      properties: {
        max_lines: {
          type: 'number',
          description: 'Maximum number of lines to include (default: 50)'
        }
      }
    }
  },
  {
    name: 'get_errors',
    description: 'Get ONLY errors from the Godot console with file paths and line numbers. More reliable than get_console_log for finding errors.',
    inputSchema: {
      type: 'object',
      properties: {
        max_errors: {
          type: 'number',
          description: 'Maximum number of errors to return (default: 50)'
        }
      }
    }
  },
  {
    name: 'clear_console_log',
    description: 'Clear the persisted Godot editor output log.',
    inputSchema: {
      type: 'object',
      properties: {}
    }
  },
  {
    name: 'open_in_godot',
    description: 'Open a file in the Godot editor at a specific line (side-effect only).',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'res:// path to open'
        },
        line: {
          type: 'number',
          description: '1-based line number'
        }
      },
      required: ['path']
    }
  },
  {
    name: 'scene_tree_dump',
    description: 'Dump the current running scene tree (names and structure).',
    inputSchema: {
      type: 'object',
      properties: {}
    }
  }
];

export function getMockProjectToolResponse(toolName: string, args: Record<string, unknown>): unknown {
  const mockNote = { _mock: true, _note: 'Connect Godot for real results.' };

  switch (toolName) {
    case 'get_project_settings':
      return { ok: true, settings: { main_scene: 'res://scenes/main.tscn', window: { width: 1152, height: 648 } }, ...mockNote };
    case 'get_input_map':
      return { ok: true, actions: { ui_accept: ['Enter', 'Space'], ui_cancel: ['Escape'], move_left: ['A', 'Left'] }, ...mockNote };
    case 'get_collision_layers':
      return { ok: true, layers_2d: { 1: 'Player', 2: 'Enemies', 3: 'World' }, ...mockNote };
    case 'get_node_properties':
      return { ok: true, node_type: args.node_type, properties: ['position', 'rotation', 'scale', 'visible', 'modulate'], ...mockNote };
    case 'get_console_log':
      return { ok: true, lines: ['[Godot] Project loaded', '[Godot] Scene ready'], ...mockNote };
    case 'get_errors':
      return { ok: true, errors: [], count: 0, ...mockNote };
    case 'clear_console_log':
      return { ok: true, message: 'Mock: Console would be cleared', ...mockNote };
    case 'open_in_godot':
      return { ok: true, message: `Mock: Would open ${args.path} at line ${args.line || 1}`, ...mockNote };
    case 'scene_tree_dump':
      return { ok: true, tree: 'Root (Node2D)\n  Player (CharacterBody2D)\n    Sprite2D\n    CollisionShape2D', ...mockNote };
    default:
      return { error: `Unknown project tool: ${toolName}`, ...mockNote };
  }
}
