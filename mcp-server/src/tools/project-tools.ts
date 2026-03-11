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
    description: 'Get errors and warnings from the Godot editor log with file paths, line numbers, and severity. Returns the most recent errors first.',
    inputSchema: {
      type: 'object',
      properties: {
        max_errors: {
          type: 'number',
          description: 'Maximum number of errors to return (default: 50)'
        },
        include_warnings: {
          type: 'boolean',
          description: 'Include warnings in addition to errors (default: true)'
        }
      }
    }
  },
  {
    name: 'clear_console_log',
    description: 'Mark the current position in the Godot editor log. Subsequent get_console_log and get_errors calls will only return output after this point.',
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
    description: 'Dump the scene tree of the scene currently open in the Godot editor (node names, types, and attached scripts).',
    inputSchema: {
      type: 'object',
      properties: {}
    }
  },
  {
    name: 'list_settings',
    description: 'Browse Godot project settings by category. Call without a category to see all available categories. Call with a category to see all settings in that category with their current values, types, and valid options.',
    inputSchema: {
      type: 'object',
      properties: {
        category: {
          type: 'string',
          description: 'Settings category prefix (e.g., "display", "physics", "rendering", "application", "audio"). Omit to list all available categories.'
        }
      }
    }
  },
  {
    name: 'update_project_settings',
    description: 'Update one or more Godot project settings. Pass a dictionary of setting paths to their new values. Use list_settings first to discover available setting paths, current values, and valid options for a category.',
    inputSchema: {
      type: 'object',
      properties: {
        settings: {
          type: 'object',
          description: 'Dictionary of setting paths to new values (e.g., {"display/window/size/viewport_width": 1920, "display/window/size/viewport_height": 1080})'
        }
      },
      required: ['settings']
    }
  },
  {
    name: 'configure_input_map',
    description: 'Add, remove, or replace input actions and their key/button bindings. Use get_input_map to see current actions before modifying.',
    inputSchema: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          description: 'Input action name (e.g., "move_left", "jump", "attack")'
        },
        operation: {
          type: 'string',
          description: '"add" to create action and/or append events, "remove" to delete the action entirely, "set" to replace all events on an action (creates it if needed)'
        },
        deadzone: {
          type: 'number',
          description: 'Action deadzone (default: 0.5)'
        },
        events: {
          type: 'array',
          description: 'Input events to bind. Each object needs a "type" field: {"type":"key","key":"Space"} for keyboard, {"type":"mouse_button","button_index":1} for mouse (1=left,2=right,3=middle), {"type":"joypad_button","button_index":0} for gamepad, {"type":"joypad_motion","axis":0,"axis_value":1.0} for gamepad axis.',
          items: { type: 'object', description: 'An input event descriptor with a "type" field and type-specific properties' }
        }
      },
      required: ['action', 'operation']
    }
  },
  {
    name: 'setup_autoload',
    description: 'Register, unregister, or list autoload singletons. Autoloads are scripts/scenes loaded automatically at project start.',
    inputSchema: {
      type: 'object',
      properties: {
        name: {
          type: 'string',
          description: 'Autoload name (e.g., "GameManager", "AudioManager")'
        },
        operation: {
          type: 'string',
          description: '"add" to register, "remove" to unregister, "list" to show all autoloads'
        },
        path: {
          type: 'string',
          description: 'res:// path to the script or scene file (required for "add")'
        }
      },
      required: ['operation']
    }
  }
];
