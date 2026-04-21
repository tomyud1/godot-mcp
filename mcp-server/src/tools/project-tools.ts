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
    description: 'Return the full InputMap: built-in actions (ui_*, spatial_editor/*) plus all project-defined actions from project.godot. Each action maps to an object with "events" (array of key/mouse/gamepad bindings) and optionally "deadzone". Use this before configure_input_map to see current bindings and deadzones.',
    inputSchema: {
      type: 'object',
      properties: {
        include_deadzones: {
          type: 'boolean',
          description: 'Include the per-action "deadzone" field in each action object (default: true). When true, each action is {"deadzone": 0.5, "events": [...]}. When false, each action is {"events": [...]}.'
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
    description: 'Get errors and warnings from both the Godot Output panel and the Debugger > Errors tab. Returns file paths, line numbers, severity, stack traces, and which source each error came from. If errors mention a missing method or property, use classdb_query to verify the correct API before fixing.',
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
    description: 'Browse Godot project settings by category. Returns values from the editor\'s in-memory state — this matches project.godot after a normal Godot save, but direct edits to project.godot on disk are not reflected until the editor restarts (rescan_filesystem does not help). Call without a category to see all available categories. Call with a category to see all settings with their current values, types, and valid options.',
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
    description: 'Update one or more Godot project settings. Pass a dictionary of setting paths to their new values. Use list_settings first to discover available setting paths, current values, and valid options for a category. For input action bindings, prefer configure_input_map — if you do pass input/* keys here, partial updates are merged safely (existing events are preserved).',
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
    name: 'run_scene',
    description: 'Launch a scene in the Godot editor. By default the call BLOCKS until the editor flips to playing state (so the next get_errors / take_screenshot / send_input call sees a real game). The response includes started, runtime_connected, wait_for_started_ms, wait_for_runtime_ms, scene_path, and runtime_root. Use runtime_root (e.g. "/root/Main") as the prefix for query_runtime_node node_path arguments \u2014 it is computed from the actual root node name in the .tscn, NOT from the file name. Set wait_for_runtime=true to additionally wait for the in-game MCPRuntime helper to connect (required before take_screenshot / send_input will work). Recommended testing loop: run_scene({wait_for_runtime:true}) \u2192 query_runtime_node / send_input / take_screenshot \u2192 get_errors \u2192 stop_scene.',
    inputSchema: {
      type: 'object',
      properties: {
        scene: {
          type: 'string',
          description: 'Scene to run: omit for main scene, "current" for the currently open scene, or a res:// path for a specific scene'
        },
        block_until_started: {
          type: 'boolean',
          description: 'Wait until the editor reports playing=true before returning (default: true). Up to startup_timeout_ms.'
        },
        wait_for_runtime: {
          type: 'boolean',
          description: 'Wait until the MCPRuntime in-game helper connects back (required for take_screenshot/send_input). Default: false.'
        },
        startup_timeout_ms: {
          type: 'number',
          description: 'Max time in ms to wait for the above signals. Default: 10000. Bump to 15000\u201320000 on slower machines or autoload-heavy projects.'
        }
      }
    }
  },
  {
    name: 'stop_scene',
    description: 'Stop the currently running scene in the Godot editor. Always stop the scene before editing code to avoid errors repeating every frame.',
    inputSchema: {
      type: 'object',
      properties: {}
    }
  },
  {
    name: 'is_playing',
    description: 'Compatibility shim: returns {playing, scene}. For richer info (uptime, runtime helper connectivity, last-launched target) prefer get_runtime_status.',
    inputSchema: {
      type: 'object',
      properties: {}
    }
  },
  {
    name: 'get_runtime_status',
    description: 'Combined editor + runtime status snapshot. Returns playing, playing_scene, last_launched ("current"|"main"|res-path), uptime_ms since the most recent run_scene, and runtime_helper_connected (true once the in-game MCPRuntime autoload is talking to the MCP server).',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'wait',
    description: 'Sleep server-side. Useful between input events to let the game process them. Capped at 30000ms / 30s. Pass either ms or seconds (ms wins if both given).',
    inputSchema: {
      type: 'object',
      properties: {
        ms: { type: 'number', description: 'Milliseconds to wait (1..30000).' },
        seconds: { type: 'number', description: 'Seconds to wait (0.001..30). Convenient when the agent is thinking in seconds.' }
      }
    }
  },
  {
    name: 'take_screenshot',
    description: 'Capture the current viewport of the running game and save it as a PNG. REQUIRES the game to be running with the MCPRuntime autoload connected (run_scene with wait_for_runtime=true first). Returns resource_path, absolute_path, width, height, and (optionally) base64_png. Default save location is res://addons/godot_mcp/cache/screenshots/.',
    inputSchema: {
      type: 'object',
      properties: {
        save_to: { type: 'string', description: 'Optional res:// or user:// destination path. Defaults to res://addons/godot_mcp/cache/screenshots/screenshot_<ms>.png' },
        return_base64: { type: 'boolean', description: 'Also include the PNG bytes inline as base64 (default: false). Useful when the agent has no filesystem access.' }
      }
    }
  },
  {
    name: 'send_input',
    description: 'Synthesize an InputEvent and dispatch it to the running game via Input.parse_input_event. REQUIRES the game to be running with the MCPRuntime autoload connected. Use this to drive automated tests: click buttons, press keys, fire input actions. For multi-step interactions, alternate send_input \u2192 wait \u2192 query_runtime_node / take_screenshot.',
    inputSchema: {
      type: 'object',
      properties: {
        event: {
          type: 'object',
          description: 'InputEvent descriptor:\n  Key: {type:"key", key:"Space", pressed:true, shift?:bool, ctrl?:bool, alt?:bool} or {type:"key", keycode:32, pressed:true}\n  Mouse button: {type:"mouse_button", button_index:1, pressed:true, position:{x,y}, double_click?:bool} (1=left, 2=right, 3=middle)\n  Mouse motion: {type:"mouse_motion", position:{x,y}, relative?:{x,y}}\n  Action (named input from the InputMap): {type:"action", action:"jump", pressed:true, strength?:1.0}'
        }
      },
      required: ['event']
    }
  },
  {
    name: 'query_runtime_node',
    description: 'Query a live node in the running scene tree. REQUIRES the game to be running with the MCPRuntime autoload connected. Returns class, path, valid, groups, and a map of property values. By default returns position, global_position, rotation, scale, visible, modulate \u2014 pass `properties:["..."]` to override. Set include_children=true to also list direct child nodes.',
    inputSchema: {
      type: 'object',
      properties: {
        node_path: { type: 'string', description: 'Absolute path (e.g. /root/Main/Player) or relative to current_scene.' },
        properties: { type: 'array', items: { type: 'string' }, description: 'Property names to read. Default: position, global_position, rotation, scale, visible, modulate.' },
        include_children: { type: 'boolean', description: 'List direct children {name, class}. Default: false.' },
        include_groups: { type: 'boolean', description: 'Include the node\'s group memberships. Default: true.' }
      },
      required: ['node_path']
    }
  },
  {
    name: 'get_runtime_log',
    description: 'Return entries from the MCPRuntime in-game ring buffer. The buffer holds the last ~500 lines pushed via MCPRuntime.push_runtime_log(level, text) from your scripts plus internal connection events. For full engine stdout (script prints, errors, warnings) use get_console_log \u2014 the editor already captures the running game\'s stdout. Returns entries with ts_ms, level, and text plus started_at_ms (when the helper started) and now_ms.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'number', description: 'Maximum entries to return (default: 200, max 500)' },
        since_ms: { type: 'number', description: 'Only return entries with ts_ms >= since_ms. Use 0 (default) for all.' }
      }
    }
  },
  {
    name: 'classdb_query',
    description: 'Query Godot\'s ClassDB for class information: properties, methods, signals, and inheritance. Use this to verify that a class, method, or property actually exists in the running Godot engine before writing code. Prevents using wrong method names, outdated Godot 3 API, or incorrect signatures.',
    inputSchema: {
      type: 'object',
      properties: {
        class_name: {
          type: 'string',
          description: 'Godot class name to query (e.g., "CharacterBody2D", "Sprite2D", "Control")'
        },
        query: {
          type: 'string',
          description: 'What to return: "all" (default), "properties", "methods", or "signals"'
        },
        include_virtual: {
          type: 'boolean',
          description: 'Include well-known virtual methods like _ready, _process, _input (default: true). Set to false to see only public non-virtual methods.'
        }
      },
      required: ['class_name']
    }
  },
  {
    name: 'rescan_filesystem',
    description: 'Trigger a full filesystem rescan in the Godot editor. Use after creating, deleting, or modifying files externally (e.g. from the terminal or another tool). The scan is asynchronous and returns immediately.',
    inputSchema: {
      type: 'object',
      properties: {}
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
