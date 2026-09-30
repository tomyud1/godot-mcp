/**
 * Live runtime control tools for the in-game MCPRuntime autoload.
 * These operate on the RUNNING game (run_scene with wait_for_runtime=true),
 * not on the editor's open scene — see the editor-scene tools for that.
 */

import type { ToolDefinition } from '../types.js';

export const runtimeTools: ToolDefinition[] = [
  {
    name: 'probe_ui',
    description: 'Structured snapshot of the on-screen Control layout: each visible Control with its viewport-pixel rect, visibility, tint, plus any overlapping sibling pairs. REQUIRES the game running with MCPRuntime connected. PREFER THIS OVER take_screenshot for anything about layout: it is ~1 KB instead of a multi-megabyte image, it gives exact numbers rather than pixels, and it works for agents that cannot see images at all. Overlapping rects are the classic UI bug a low-contrast screenshot hides. Screenshot only when you need to judge art, colour or composition.',
    inputSchema: {
      type: 'object',
      properties: {
        max_controls: { type: 'number', description: 'Cap on controls returned (default: 60). Raise only if the count suggests the cap was hit.' },
        include_hidden: { type: 'boolean', description: 'Include hidden and off-screen controls (default: false). Useful when debugging why something is not appearing.' }
      }
    }
  },
  {
    name: 'probe_camera',
    description: 'Report where Node3D targets land on screen and whether the active camera can actually see them. Answers "is my level geometry in shot" and "why is my player off-camera" with numbers instead of guessing from a frame. REQUIRES the game running with MCPRuntime connected. Screenshot only when you need to judge art, colour or composition.',
    inputSchema: {
      type: 'object',
      properties: {
        node_paths: {
          type: 'array',
          items: { type: 'string' },
          description: 'Node3D paths to check, e.g. ["/root/Main/Player", "/root/Main/Level/Wall"]. Absolute from /root, or relative to the current scene.'
        }
      },
      required: ['node_paths']
    }
  },
  {
    name: 'assert_runtime',
    description: 'Run bounded assertions against the running game and return {passed, actual, expected} for each — a failure is evidence, not a vibe. REQUIRES the game running with MCPRuntime connected. This is how to verify behaviour WITHOUT a screenshot, so it works for non-multimodal agents. Kinds: node_exists, node_visible, node_inside_viewport, rect_contains_point, text_matches, property_equals, group_count, no_errors. Checks run in order and all are evaluated even if an earlier one fails, so one call can check a whole sequence.',
    inputSchema: {
      type: 'object',
      properties: {
        checks: {
          type: 'array',
          description: 'Assertions to run. Each is {kind, ...}. Examples: {"kind":"node_exists","node_path":"Player"}, {"kind":"node_visible","node_path":"HUD/Score","visible":true}, {"kind":"node_inside_viewport","node_path":"MainMenu/StartButton"}, {"kind":"rect_contains_point","node_path":"HUD/Health","point":{"x":100,"y":50}}, {"kind":"text_matches","node_path":"HUD/Score","text":"100"}, {"kind":"property_equals","node_path":"Player","property":"visible","value":true}, {"kind":"group_count","group":"enemies","equals":3}, {"kind":"no_errors","max":0}.',
          items: { type: 'object' }
        }
      },
      required: ['checks']
    }
  },
  {
    name: 'runtime_eval',
    description: 'Execute arbitrary GDScript inside the running game and return the serialized result. REQUIRES confirm=true as an explicit safety gate — omitting it returns an error. Also REQUIRES the game to be running with the MCPRuntime autoload connected (run_scene with wait_for_runtime=true first). The code runs in a temporary Node attached to the game tree, so it can touch any live node: get_tree().current_scene, $Player, await, etc. A trailing expression is returned automatically (e.g. "1 + 2" returns 3); for multi-line code or coroutine results use an explicit "return expr" or "return await ...". WARNING: this has full control over the running game (it can quit it, crash it, or corrupt state) — prefer safer tools like query_runtime_node / runtime_call_method when they suffice. Returns {result} with the value serialized (Vectors, Colors, Transforms, Arrays, and Dictionaries all supported).',
    inputSchema: {
      type: 'object',
      properties: {
        code: {
          type: 'string',
          description: 'GDScript to evaluate in the running game. Examples: "get_tree().current_scene.name", "get_viewport().get_visible_rect().size", "var x = 5\\nx * 3", "await get_tree().create_timer(1.0).timeout\\nreturn \'done\'".'
        },
        confirm: {
          type: 'boolean',
          description: 'REQUIRED. Must be explicitly set to true — safety gate against silently executing arbitrary code in the running game.'
        }
      },
      required: ['code', 'confirm']
    }
  },
  {
    name: 'runtime_wait',
    description: 'Await N game frames in the running game so the engine actually ticks before the agent continues. Unlike the server-side "wait" tool (which only sleeps and does not advance the game), this suspends the tool call until the game has processed the requested frames. Use between send_input calls and before query_runtime_node / take_screenshot so physics and logic settle. Frame-rate dependent: at 60fps, 60 frames \u2248 1 second. Capped at 3000 frames.',
    inputSchema: {
      type: 'object',
      properties: {
        frames: { type: 'number', description: 'Number of frames to await (default: 1, max 3000).' },
        frame_type: { type: 'string', description: '"render" (default) awaits process_frame; "physics" awaits physics_frame.' }
      }
    }
  },
  {
    name: 'runtime_await_signal',
    description: 'Block until a signal fires on a live node in the running game (or the timeout elapses). Returns received: true/false and timeout: true/false. Use to wait for an animation to finish, a tween to complete, a collision, an enemy death, etc. — e.g. await "animation_finished" on an AnimationPlayer before sending the next input. REQUIRES the MCPRuntime autoload connected.',
    inputSchema: {
      type: 'object',
      properties: {
        node_path: { type: 'string', description: 'Absolute path (e.g. /root/Main/Player) or relative to current_scene.' },
        signal_name: { type: 'string', description: 'Signal name to wait for (e.g. animation_finished, died, body_entered).' },
        timeout: { type: 'number', description: 'Seconds to wait before giving up (default 10, range 0.1..25).' }
      },
      required: ['node_path', 'signal_name']
    }
  },
  {
    name: 'runtime_call_method',
    description: 'Call a method on a live node in the running game and return the serialized result. For editor-scene (not running) method calls, use call_node_method instead. Use for direct interactions the input tools cannot express: player.take_damage(10), game.start(), save_game(), etc. For coroutine/await-style methods or arbitrary code, use runtime_eval (which additionally requires confirm=true). REQUIRES the MCPRuntime autoload connected.',
    inputSchema: {
      type: 'object',
      properties: {
        node_path: { type: 'string', description: 'Absolute path (e.g. /root/Main/Player) or relative to current_scene.' },
        method_name: { type: 'string', description: 'Method name to call on the node.' },
        args: { type: 'array', items: {}, description: 'Arguments to pass to the method (default []).' }
      },
      required: ['node_path', 'method_name']
    }
  },
];
