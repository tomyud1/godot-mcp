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
    description: 'Return the latest lines from the Godot editor Output panel (editor-side messages plus prints from the running game). NOTE: this does NOT include the Debugger > Errors tab — runtime push_error / script errors during play often surface only there. After run_scene, always call get_errors (not just this) to check for errors. When this tool finds error-prefixed lines it returns errors_detected=true and a hint pointing to get_errors. The tool also reads the Output panel\'s Info/Warning/Error filter buttons; if Info is OFF and prints appear missing, the response includes output_panel_filters and a hint asking the user to toggle Info back on (the panel filters its RichTextLabel, so missing-print symptoms are usually a UI toggle, not a tool bug). Pass debug:true to also include editor_log_rtl_path, editor_log_candidates (every EditorLog widget found, with sample tails), and output_panel_filters even when nothing looks suspicious.',
    inputSchema: {
      type: 'object',
      properties: {
        max_lines: {
          type: 'number',
          description: 'Maximum number of lines to include (default: 50)'
        },
        debug: {
          type: 'boolean',
          description: 'When true, include editor_log_rtl_path and editor_log_candidates (each EditorLog widget found, with text length and a 200-char tail sample). Use this to diagnose cases where running-game prints do not appear in the default Output panel scrape.'
        }
      }
    }
  },
  {
    name: 'get_errors',
    description: 'Get errors and warnings from both the Godot Output panel and the Debugger > Errors tab. Returns file paths, line numbers, severity, stack traces, and which source each error came from. Debugger rows can appear a few frames after run_scene returns; pass wait_ms:300 when checking immediately after launch. If errors mention a missing method or property, use classdb_query to verify the correct API before fixing.',
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
        },
        wait_ms: {
          type: 'number',
          description: 'Optional short wait before reading Output/Debugger errors, capped at 1000ms. Use ~300ms immediately after run_scene to avoid false "0 errors" results while the Debugger > Errors tab catches up.'
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
    description: 'Dump the scene tree of the scene currently open in the Godot editor (node names, types, and attached scripts) as an indented text block. Reflects unsaved edits (uses the live editor tree, not the .tscn on disk).\n\nAll args are optional; with no args the entire tree is returned (existing behavior).\n\nOpt-in scoping / pagination (use these on large scenes to keep responses small):\n  • subtree_root — start at a node path relative to the scene root (e.g. "UI/HUD"). Empty or "." means the scene root. Depth resets to 0 at this node.\n  • max_depth — stop traversal at depth N from the (subtree_)root. 0 = only the root itself. Omit or pass a negative value for unlimited.\n  • offset / limit — paginate by flat DFS preorder index. offset skips the first N nodes; limit caps how many are emitted.\n\nResponse fields:\n  • tree — the indented text (only nodes inside the window are rendered).\n  • scene_path — the editor scene file.\n  • total_node_count — total nodes inside the (subtree_root + max_depth) scope. Always returned.\n  • truncated — true ONLY when offset/limit clipped output. max_depth is intentional scoping, not truncation.\n  • next_offset — set to offset + emitted when truncated; call again with this offset to continue.\n  • subtree_root — echoed when you passed one.',
    inputSchema: {
      type: 'object',
      properties: {
        subtree_root: {
          type: 'string',
          description: 'Scene-relative node path to start the dump at (e.g. "UI/HUD"). Empty or "." = scene root. Errors if the node is not found.'
        },
        max_depth: {
          type: 'number',
          description: 'Stop traversal at depth N from the (subtree_)root. 0 = only that root node. Omit or pass a negative value for unlimited depth.'
        },
        offset: {
          type: 'number',
          description: 'Skip the first N nodes in DFS preorder (used for pagination). Default 0.'
        },
        limit: {
          type: 'number',
          description: 'Maximum number of nodes to render after offset. Omit for unlimited.'
        }
      }
    }
  },
  {
    name: 'get_editor_selection',
    description: 'Return the node path(s) the user has currently selected in the Godot editor (Scene dock). **Call this FIRST whenever the user refers to a node without naming a path** — phrases like "this node", "fix this", "change the color here", "delete that", "make this red", "the selected one", "what I have selected", etc. Returns an empty `selection` array if nothing is selected; that\'s informational, not an error. Selection is editor UI state (not stored in the .tscn) and is scoped to the currently edited scene tab — instances from a non-active tab will not appear.\n\nResponse shape: `{ok, scene_path, selection: [{path, name, type}], count, reason, message?}`. `reason` is a stable machine-readable enum — `"ok"` (something is selected), `"none_selected"` (scene open but no nodes selected), or `"no_scene_open"` (no scene tab open at all) — so the agent can branch without string-matching the human-readable `message`. Paths are scene-relative ("." = scene root, "UI/HUD/Label" for nested) and match the format produced by `find_nodes` and `scene_tree_dump`, so they can be passed directly to `modify_node_property`, `set_node_properties`, `attach_script`, `remove_node`, etc. See the `selection-workflow` guide for end-to-end patterns.',
    inputSchema: {
      type: 'object',
      properties: {}
    }
  },
  {
    name: 'set_editor_selection',
    description: 'Replace or extend the editor\'s Scene-dock selection. Two main uses: (1) after `add_node`, focus the user\'s gizmo on the freshly-created node so they can see/manipulate it immediately, and (2) draw the user\'s attention to a node the AI just modified or discovered ("here is the offending node — selected for you in the Scene dock"). Pre-validates every path against the live edited scene tree before mutating — if any path is unresolved, no selection change happens and `not_found` is returned.\n\nArgs: `node_paths` (string OR array of strings; scene-relative, "." = scene root, "UI/HUD/Label" for nested), `mode` ("replace" default = clear existing then select; "add" = append to existing). Returns `{ok, scene_path, selected:[{path,name,type}], not_found:[], mode, count}`.\n\nUse `get_editor_selection` afterwards (or `scene_tree_dump`) to verify.',
    inputSchema: {
      type: 'object',
      properties: {
        node_paths: {
          oneOf: [
            { type: 'string' },
            { type: 'array', items: { type: 'string' } }
          ],
          description: 'Scene-relative path(s) to select. "." = scene root, "UI/HUD/Label" for nested. Accepts a single string OR an array of strings; both forms behave identically.'
        },
        mode: {
          type: 'string',
          description: '"replace" (default) clears the existing selection first; "add" appends to it.'
        }
      },
      required: ['node_paths']
    }
  },
  {
    name: 'close_editor_tabs',
    description: 'Close open editor tabs (scenes and/or scripts). Files on disk are NOT touched — this only changes the editor UI state. Default behavior with no args closes EVERY open tab (both scenes and scripts).\n\nPrimary use case: test automation — reset the editor to a known state between test runs without restarting Godot. Also useful before calling delete_file / delete_folder, which refuse by default when the target is open in an editor tab.\n\nFilter by kind ("scene", "script", "any") and/or by specific paths. Paths can be given with or without "res://".\n\nSCENES: built on EditorInterface.close_scene() (Godot 4.5+). Unsaved changes are DISCARDED silently (matches Godot\'s native close-tab behavior); save first via the editor or save_resource_to_file if you need to preserve pending edits.\n\nSCRIPTS: Godot does not currently expose a public API to close script tabs from script. Requested script paths are returned in `scripts_closed_not_supported` with the reason rather than silently skipped. Workarounds: close manually via the X on the tab, or use `force=true` on the next file mutation to bypass the editor-open guard.\n\nResponse: {ok, scenes_closed, scripts_closed_not_supported, not_open, remaining_scenes, remaining_scripts, message}. `scenes_failed` appears with per-path Godot error codes when any close fails.',
    inputSchema: {
      type: 'object',
      properties: {
        kind: {
          type: 'string',
          enum: ['scene', 'script', 'any'],
          description: 'Which tab kind to target. "any" (default) closes both scenes and scripts. "scene" or "script" restricts to that side.'
        },
        paths: {
          type: 'array',
          items: { type: 'string' },
          description: 'Optional list of paths to close (with or without "res://"). Omit, pass an empty array, or pass null to close ALL open tabs of the chosen kind. Paths not currently open are returned in `not_open` rather than causing an error.'
        }
      }
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
    description: 'Launch a scene in the Godot editor. By default the call BLOCKS until the editor flips to playing state (so the next get_errors / take_screenshot / send_input call sees a real game). The response includes started, runtime_connected, wait_for_started_ms, wait_for_runtime_ms, scene_path, and runtime_root. Use runtime_root (e.g. "/root/Main") as the prefix for query_runtime_node node_path arguments \u2014 it is computed from the actual root node name in the .tscn, NOT from the file name. Set wait_for_runtime=true to additionally wait for the in-game MCPRuntime helper to connect (required before take_screenshot / send_input will work). By default this watermarks the log surfaces so the subsequent get_console_log / get_errors only show THIS run\'s output \u2014 no more mistaking stale errors from a previous run for fresh ones (set clear_output:false to keep reading the full history). Recommended testing loop: run_scene({wait_for_runtime:true}) \u2192 query_runtime_node / send_input / take_screenshot \u2192 get_errors \u2192 stop_scene.',
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
          description: 'Max time in ms to wait for the above signals. Default: 10000. Bump to 15000\u201320000 on slower machines or autoload-heavy projects. Values above 25000 are clamped (response would otherwise miss the transport timeout); the response signals this via `startup_timeout_clamped: true` plus `requested_startup_timeout_ms` and `effective_startup_timeout_ms`.'
        },
        clear_output: {
          type: 'boolean',
          description: 'Watermark the Output panel and Debugger > Errors tab at launch so get_console_log / get_errors only return entries from THIS run, preventing stale output from a previous run being read as current errors (default: true). Read-side only \u2014 the human\'s Output panel scrollback is preserved. Set false to read the full accumulated history.'
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
    description: 'Combined editor + runtime status snapshot. Returns `playing`, `playing_scene`, `last_launched` ("current"|"main"|res-path), `uptime_ms` since the most recent run_scene, `runtime_helper_connected` (true once the in-game MCPRuntime autoload is talking to the MCP server), `godot_version` (e.g. "4.5.0.stable"), and `godot_version_info` (the full Engine.get_version_info() dict — `major`, `minor`, `patch`, `string`, `build`, `hex`, …). Useful for binding test reports to a specific Godot build without opening the About dialog.',
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
    name: 'get_performance_monitors',
    description: 'Snapshot of Godot\'s Performance singleton from inside the RUNNING game: fps, frame/physics step times, static memory (current + peak), renderer draw calls / objects / primitives, and engine-wide object/node/orphan counts. REQUIRES the game to be running with the MCPRuntime autoload connected (run_scene with wait_for_runtime=true first).\n\nUse when:\n  1. After run_scene — verify the scene actually hits its target fps before reporting "done".\n  2. The user reports lag/jank — localize the bottleneck (low fps vs high draw_calls vs growing memory vs orphan_nodes leak).\n  3. Before/after an optimization change — measure both sides to confirm the change helped (the optimization claim is only credible with numbers).\n\nResponse fields:\n  • fps, frame_time_ms — overall frame budget. Target is usually 16.67ms (60fps) or 8.33ms (120fps).\n  • physics_process_time_ms — physics step time (cost per tick).\n  • physics_ticks_per_second — configured tick rate (Engine.physics_ticks_per_second). Compare against physics_process_time_ms: if step time > 1000/tick_rate, physics is over budget.\n  • static_memory_mb / _bytes, static_memory_peak_mb / _bytes — current and high-water mark.\n  • draw_calls, objects_in_frame, primitives_in_frame — render-side cost.\n  • total_objects, nodes, orphan_nodes — engine-wide instance counts. orphan_nodes > 0 means nodes were created without being added to the tree (memory leak smell).\n  • custom_monitors (only when present) — any user-registered Performance.add_custom_monitor entries.\n\nValues reflect a single frame; sample twice with a wait in between if you need to confirm a trend.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'get_runtime_log',
    description: 'Return entries from the MCPRuntime in-game ring buffer. The buffer holds the last ~500 lines pushed via MCPRuntime.push_runtime_log(level, text) from your scripts plus internal connection events. For script prints/stdout use get_console_log; for runtime push_error / script errors use get_errors (it reads the Debugger > Errors tab \u2014 runtime errors do NOT appear in get_console_log). Returns entries with ts_ms, level, and text plus started_at_ms (when the helper started) and now_ms.',
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
    description: 'Trigger a full filesystem rescan in the Godot editor. Use after creating, deleting, or modifying files externally (e.g. from the terminal or another tool). The scan is asynchronous and returns immediately. If a scan is already in progress (often happens right after a batch of mutations), the call returns ok:true with already_scanning:true — the in-flight scan will pick up your recent disk changes, no new scan is triggered. Response: {ok, already_scanning, message}.',
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
