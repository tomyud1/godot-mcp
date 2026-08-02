/**
 * Live runtime control tools for the in-game MCPRuntime autoload.
 * These operate on the RUNNING game (run_scene with wait_for_runtime=true),
 * not on the editor's open scene — see the editor-scene tools for that.
 */

import type { ToolDefinition } from '../types.js';

export const runtimeTools: ToolDefinition[] = [
  {
    name: 'runtime_eval',
    description: 'Execute arbitrary GDScript inside the running game and return the serialized result. REQUIRES the game to be running with the MCPRuntime autoload connected (run_scene with wait_for_runtime=true first). The code runs in a temporary Node attached to the game tree, so it can touch any live node: get_tree().current_scene, $Player, await, etc. A trailing expression is returned automatically (e.g. "1 + 2" returns 3); for multi-line code or coroutine results use an explicit "return expr" or "return await ...". WARNING: this has full control over the running game (it can quit it, crash it, or corrupt state) — prefer safer tools like query_runtime_node / runtime_call_method when they suffice. Returns {result} with the value serialized (Vectors, Colors, Transforms, Arrays, and Dictionaries all supported).',
    inputSchema: {
      type: 'object',
      properties: {
        code: {
          type: 'string',
          description: 'GDScript to evaluate in the running game. Examples: "get_tree().current_scene.name", "get_viewport().get_visible_rect().size", "var x = 5\\nx * 3", "await get_tree().create_timer(1.0).timeout\\nreturn \'done\'".'
        }
      },
      required: ['code']
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
    description: 'Call a method on a live node in the running game and return the serialized result. For editor-scene (not running) method calls, use call_node_method instead. Use for direct interactions the input tools cannot express: player.take_damage(10), game.start(), save_game(), etc. For coroutine/await-style methods or arbitrary code, use runtime_eval. REQUIRES the MCPRuntime autoload connected.',
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
