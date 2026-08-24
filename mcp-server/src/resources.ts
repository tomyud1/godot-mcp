/**
 * MCP resources for the Godot MCP Server.
 *
 * These are short, opt-in markdown guides that an agent can READ on demand
 * via the standard MCP `resources/list` and `resources/read` requests. They
 * keep the per-tool description schemas lean (one or two sentences) while
 * still letting the agent pull deeper guidance when a workflow gets tricky.
 *
 * Naming: godot-mcp://guide/<topic>
 */

import type { Server } from '@modelcontextprotocol/sdk/server/index.js';
import {
  ListResourcesRequestSchema,
  ReadResourceRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

export interface Guide {
  uri: string;
  name: string;
  /** Short stable identifier for use with the `get_guide` tool (no URI prefix). */
  slug: string;
  description: string;
  mimeType: 'text/markdown';
  text: string;
}

export const GUIDES: Guide[] = [
  {
    uri: 'godot-mcp://guide/testing-loop',
    slug: 'testing-loop',
    name: 'Testing loop for running games',
    description: 'How to drive a running game from the agent: run_scene, send_input, query_runtime_node, take_screenshot, get_errors.',
    mimeType: 'text/markdown',
    text: `# Testing a running Godot game from MCP

The MCPRuntime autoload (registered automatically when the godot_mcp plugin is enabled) lets the agent inspect and drive a running game.

## Minimum viable loop

1. \`run_scene({ wait_for_runtime: true })\` — launches the scene and BLOCKS until the in-game helper connects. Inspect \`runtime_connected\` in the response; if false, take_screenshot/send_input will fail with a clear error.
2. \`get_errors({ max_errors: 20 })\` — catches startup crashes early.
3. Drive input. Examples:
   - Click a button: \`send_input({ event: { type: 'mouse_button', button_index: 1, pressed: true, position: { x: 640, y: 360 } } })\` followed by another with \`pressed: false\`.
   - Press a key: \`send_input({ event: { type: 'key', key: 'Space', pressed: true } })\`.
   - Trigger a named action: \`send_input({ event: { type: 'action', action: 'jump', pressed: true } })\`.
4. \`wait({ ms: 200 })\` between events to let the engine process them.
5. \`query_runtime_node({ node_path: '/root/Main/Player', properties: ['position', 'velocity', 'visible'] })\` — verify state changes.
6. \`take_screenshot({})\` — visual confirmation.
7. \`stop_scene()\` before editing code, or \`get_errors\` again to confirm clean shutdown.

## Driving a non-input-driven game (cutscene, idle simulation)

Skip step 3 and use \`wait\` + \`query_runtime_node\` + \`take_screenshot\` to sample the simulation at intervals.

## Common pitfalls

- Calling \`take_screenshot\` immediately after \`run_scene\` without \`wait_for_runtime: true\` returns "Runtime helper not connected".
- The runtime ring buffer (\`get_runtime_log\`) only contains entries pushed via \`MCPRuntime.push_runtime_log(level, text)\`. For full engine stdout use the editor's \`get_console_log\`.
- \`send_input\` with type \`action\` requires the action to exist in the InputMap (check with \`get_input_map\`).
- If \`run_scene({wait_for_runtime:true})\` ever reports \`started: true, runtime_connected: false\`, that's a real failure most of the time (autoload crash, plugin disabled, port collision). Sanity-check by calling \`get_runtime_status\` once before assuming the helper is dead — the editor-side flag is updated by a separate WebSocket push, so a sub-100ms race is still theoretically possible.

## Performance verification

After the scene is up and you've driven it for a moment, sample \`get_performance_monitors({})\` to confirm the build actually meets its target framerate before reporting "done". Same tool localizes user-reported lag (low fps vs high draw_calls vs growing memory vs orphan_nodes leak) and quantifies before/after for any optimization change — don't claim an optimization helped without numbers from both sides.
`,
  },
  {
    uri: 'godot-mcp://guide/scene-editing',
    slug: 'scene-editing',
    name: 'Scene editing patterns',
    description: 'When to use add_node vs modify_node_property vs set_node_properties vs set_resource_property vs the specialized resource tools.',
    mimeType: 'text/markdown',
    text: `# Scene editing in MCP

## Pick the right tool

| Goal                                            | Tool                                                         |
|-------------------------------------------------|--------------------------------------------------------------|
| Create scene with several nodes in one shot     | \`create_scene\` with \`nodes\` tree                         |
| Add ONE node                                    | \`add_node\` (now supports \`script\`, \`groups\`, \`children\`) |
| Add a SUBTREE                                   | \`add_node\` with \`children\`                                |
| Change ONE simple value (position, modulate)    | \`modify_node_property\`                                     |
| Change MANY values on one node                  | \`set_node_properties\`                                      |
| Change a Resource value (e.g. radius of a Shape, albedo of a Material) | \`set_resource_property\`         |
| Replace the entire Resource (different mesh, different texture) | \`set_mesh\` / \`set_sprite_texture\` / \`set_material\` / \`set_collision_shape\` |
| Persist a node-attached resource as a .tres     | \`save_resource_to_file\`                                    |
| Group membership                                | \`set_node_groups\` (replace/add/remove)                     |
| Verify which nodes belong to a group            | \`find_nodes\` with \`in_group\`                              |
| Search a scene for nodes by name / type / group | \`find_nodes\` (filters AND together; \`type\` matches subclasses) |
| Wire up a signal (persisted to .tscn)           | \`connect_signal\`                                           |
| See what is wired                               | \`list_signal_connections\` (source: scene_file or runtime)  |
| Inspect a resource on disk                      | \`get_resource_info\` (works for any Resource subclass)      |

## Variant value formats

For any tool that takes a typed value (\`modify_node_property.value\`, \`set_node_properties.properties\`, \`set_resource_property.value\`), pass either a primitive or a discriminated object:

- \`{type:"Vector2", x:1, y:2}\`, \`{type:"Vector3", x, y, z}\`
- \`{type:"Color", r, g, b, a}\`
- \`{type:"Quaternion", x, y, z, w}\`
- \`{type:"Basis", euler:{x, y, z}}\`
- \`{type:"Transform3D", basis:{...}, origin:{x, y, z}}\`
- \`{type:"AABB", position:{x,y,z}, size:{x,y,z}}\`
- \`{type:"Rect2", x, y, width, height}\`

For Resource-typed properties, do not pass the value directly — use the resource-aware tools listed above.
`,
  },
  {
    uri: 'godot-mcp://guide/asset-generation',
    slug: 'asset-generation',
    name: 'Generating 2D assets',
    description: 'How generate_2d_asset really works (no temp file, intrinsic dimensions) and the width / height / scale overrides.',
    mimeType: 'text/markdown',
    text: `# generate_2d_asset

The asset generator renders SVG markup directly to a Godot \`Image\` via \`Image.load_svg_from_buffer\` and saves a PNG. There is no temporary SVG file on disk and no dependency on \`user://\`, so concurrent calls and project-rename quirks cannot break it.

## Sizing modes

- Default: render the SVG at its intrinsic size (whatever \`<svg width=... height=...>\` declares).
- \`{ scale: 2.0 }\`: render at 2x.
- \`{ width: 256 }\` (or \`height\`): derive a uniform render scale from the SVG's intrinsic width/height. Pass either dimension; the other axis scales proportionally.

## Tips for clean SVG

- Either single or double quotes work in attributes.
- Use a viewBox plus explicit width/height if you want predictable scaling.
- For pixel-perfect output, set \`shape-rendering="crispEdges"\` and align rect coordinates to integers.

## Output

\`\`\`json
{
  "ok": true,
  "resource_path": "res://assets/generated/foo.png",
  "absolute_path": "/.../foo.png",
  "dimensions": { "width": 128, "height": 128 },
  "render_scale": 2.0,
  "message": "Generated res://assets/generated/foo.png (128x128, scale=2.000)"
}
\`\`\`
`,
  },
  {
    uri: 'godot-mcp://guide/troubleshooting',
    slug: 'troubleshooting',
    name: 'Troubleshooting common failures',
    description: 'Quick fixes for "Runtime helper not connected", project rename surprises, and other recurring errors.',
    mimeType: 'text/markdown',
    text: `# Troubleshooting

## "Runtime helper is not connected"

The MCPRuntime autoload only runs when the game is running.
1. Confirm the godot_mcp plugin is enabled (Project > Project Settings > Plugins).
2. Check that an autoload named \`MCPRuntime\` is registered (\`setup_autoload({operation:"list"})\`). The plugin auto-registers it on enable.
3. Launch with \`run_scene({ wait_for_runtime: true })\` so the call blocks until the helper connects.

## Renaming the project broke things

Changing \`application/config/name\` causes Godot to re-bind \`user://\` to a different OS folder. Files written under the old name appear to vanish.
- Use \`update_project_settings\` for the rename — it pre-creates the new \`user://\` folder and returns a warning describing the move.
- The MCP cache lives under \`res://addons/godot_mcp/cache/\` (project-relative) so it survives renames.

## Tool returned "no GDScript files found in res://"

This is a benign empty result, not a real failure. \`map_project\` will return an empty visualization for an empty project.

## set_sprite_texture set the wrong texture class

\`texture_type: "ImageTexture"\` (deprecated alias) and \`"FromPath"\` both call \`load(path)\`, which the importer typically returns as a CompressedTexture2D. To force an actual ImageTexture in memory use \`texture_type: "NewImageTexture"\`.
`,
  },
  {
    uri: 'godot-mcp://guide/batching',
    slug: 'batching',
    name: 'Batching multi-step mutations with batch_execute',
    description: 'When and how to use batch_execute. Mode matrix (atomic / stop_on_error), disallowed tools, worked examples, undo semantics.',
    mimeType: 'text/markdown',
    text: `# Batching multi-step mutations

\`batch_execute\` runs an ordered list of MCP tool calls as one composite operation. Cuts round-trip latency, response tokens, per-call error handling, and lands the whole batch as ONE undo entry (one \`mcp_undo\` reverts everything).

## When to reach for it

Whenever you would otherwise issue several consecutive mutations on the same scene/script/project. Rule of thumb: **2 mutations? Use sequential calls. 3+? Batch them.**

Classic shape: "create a node, set 5 properties on it, attach a script, connect 2 signals." That's 9 round-trips today, or 1 batch_execute call.

DON'T batch when:
- A later command's args depend on the result of an earlier one (the batch builds args BEFORE sending; earlier results are NOT piped into later sub-commands).
- The work spans the editor and the running game (\`run_scene\` / \`stop_scene\` / \`wait\` are disallowed inside a batch).
- You're doing read-only inspection (\`read_scene\`, \`get_node_properties\`) — those are fine in a batch but the savings are smaller; usually two reads in parallel is simpler.

## Modes

| atomic | stop_on_error | What happens on a sub-command failure |
|--------|---------------|----------------------------------------|
| true (default) | (ignored — always stops) | Every earlier successful step is rolled back from snapshots. The batch either fully applies or appears never to have happened. No undo entry is left behind. |
| false | true (default when atomic=false) | Stops at the first failure. Successful steps stay in place and are committed as one undo entry. |
| false | false | Runs every command regardless of failures. Successful steps committed; \`failures: [...]\` lists every one that failed. |

Pick \`atomic: true\` (the default) unless you genuinely want partial work to land — for example "rename 12 files; whichever ones succeed are fine."

## Disallowed inside a batch

- \`batch_execute\` (no nesting)
- \`mcp_undo\` / \`mcp_redo\` / \`mcp_undo_history\` (would corrupt the in-progress entry)
- \`wait\` (coroutine)
- \`run_scene\` / \`stop_scene\` (process lifecycle isn't snapshotable / rollback-able)

Everything else dispatches through the normal tool path with the same validation and error shape it has when called directly.

## Response shape

\`\`\`
{
  ok: <bool>,
  atomic: <bool>,
  stop_on_error: <bool>,
  succeeded: <int>,
  total: <int>,              // commands.length
  results: [                  // length = succeeded + failures.length
    { ok: true,  name: "...", result: { ... } },
    { ok: false, name: "...", result: { ok: false, error: "..." } }
  ],
  failed_at?: <int>,          // index of FIRST failure
  failed_command?: <string>,
  error?: <string>,           // FIRST failure's error message
  failures?: [                // every failure (only present when ok=false)
    { index: <int>, name: <string>, error: <string> }
  ],
  rolled_back?: <bool>,       // true iff atomic rolled back partial work
  rollback_errors?: [...],    // only if rollback itself hit problems
  undo_entry_id?: <string>    // present when something was committed
}
\`\`\`

## Worked examples

### 1. Build a Player node atomically

\`\`\`json
{
  "commands": [
    { "name": "add_node",            "args": { "scene_path": "res://main.tscn", "parent_path": ".", "node_name": "Player", "node_type": "CharacterBody2D" } },
    { "name": "set_node_properties", "args": { "scene_path": "res://main.tscn", "node_path": "Player", "properties": { "position": { "type": "Vector2", "x": 100, "y": 200 } } } },
    { "name": "attach_script",       "args": { "scene_path": "res://main.tscn", "node_path": "Player", "script_path": "res://scripts/player.gd" } },
    { "name": "set_node_groups",     "args": { "scene_path": "res://main.tscn", "node_path": "Player", "groups": ["players"], "mode": "replace" } },
    { "name": "connect_signal",      "args": { "scene_path": "res://main.tscn", "from_node": "Player", "signal": "health_depleted", "to_node": ".", "method": "_on_player_died" } }
  ]
}
\`\`\`

If any step fails (e.g. \`player.gd\` doesn't exist), all earlier mutations are rolled back. The user sees no half-built Player. One \`mcp_undo\` after success reverts the whole sequence.

### 2. Bulk rename — partial success acceptable

\`\`\`json
{
  "atomic": false,
  "stop_on_error": false,
  "commands": [
    { "name": "rename_file", "args": { "old_path": "res://old_a.tscn", "new_path": "res://new_a.tscn" } },
    { "name": "rename_file", "args": { "old_path": "res://old_b.tscn", "new_path": "res://new_b.tscn" } },
    { "name": "rename_file", "args": { "old_path": "res://old_c.tscn", "new_path": "res://new_c.tscn" } }
  ]
}
\`\`\`

If only \`old_b.tscn\` doesn't exist, \`a\` and \`c\` rename, the response carries \`failures: [{index: 1, ...}]\`, and \`undo_entry_id\` lets a single \`mcp_undo\` revert the two successful renames.

### 3. Read + mutate in one trip

\`\`\`json
{
  "commands": [
    { "name": "get_scene_node_properties", "args": { "scene_path": "res://hud.tscn", "node_path": "HealthBar" } },
    { "name": "modify_node_property",      "args": { "scene_path": "res://hud.tscn", "node_path": "HealthBar", "property_name": "max_value", "value": 200 } }
  ]
}
\`\`\`

The first sub-command's result lives at \`results[0].result\`. Earlier results are NOT piped into later args — if the AI needs the read value to compute the write value, do it as two separate calls.

## Undo semantics

- A batch commits as exactly ONE entry on the undo stack with \`tool: "batch_execute"\`. Listing it via \`mcp_undo_history\` shows that one row.
- One \`mcp_undo\` reverts the entire batch (every snapshot in the entry, processed in reverse order).
- Files touched by multiple sub-commands in the same batch are snapshotted ONCE (the pre-batch state). The intermediate states are discarded — undoing returns to before the batch started, which is what callers expect.
- In \`atomic: true\` mode, a failed batch never lands on the stack at all — there's nothing to undo because everything was rolled back inline.

## Pitfalls

- **Don't try to chain results.** \`batch_execute\` runs commands with their args as-given. If \`commands[1].args.node_path\` depends on a name returned by \`commands[0]\`, that won't work — split the call.
- **Schema errors fail fast.** Pre-validation rejects unknown / disallowed sub-commands BEFORE any mutation. So a typo in \`commands[3].name\` will not partially apply \`commands[0..2]\`.
- **Atomic rollback restores file content, not editor state.** If you had a scene open and unsaved, the rollback restores the .tscn on disk and reloads the editor tab. Any unsaved in-memory edits in the same scene at batch start are lost (this is consistent with the rest of the MCP undo system).
`,
  },
  {
    uri: 'godot-mcp://guide/selection-workflow',
    slug: 'selection-workflow',
    name: 'Working with the editor selection',
    description: 'How to use get_editor_selection / set_editor_selection so the user can say "fix this" without typing a path.',
    mimeType: 'text/markdown',
    text: `# Working with the editor selection

The Godot editor tracks which node(s) the user has clicked on in the Scene dock. \`get_editor_selection\` exposes that to the AI; \`set_editor_selection\` lets the AI focus the user's gizmo on a specific node.

## When to call \`get_editor_selection\` FIRST

Any time the user refers to a node without naming it. Trigger phrases:

- "this node", "this one", "that"
- "fix this", "delete this", "rename this"
- "change the color here", "make this red", "move this up"
- "the selected node", "what I have selected"
- "the highlighted one"

**Pattern:**

1. \`get_editor_selection({})\`
2. If \`count == 0\`: tell the user nothing is selected and ask them to click the node first (or fall back to asking which node by name).
3. If \`count == 1\`: that's the target node — pass its \`path\` to \`modify_node_property\` / \`set_node_properties\` / \`attach_script\` / etc.
4. If \`count > 1\`: ask whether to apply the change to all selected nodes, or pick the first, depending on the request.

\`get_editor_selection\` is cheap (no scene load, just reads the live editor state). Calling it speculatively at the start of an ambiguous request is almost always the right move.

## When to call \`set_editor_selection\`

Two common uses:

1. **Focus the user on a freshly-created node.** After \`add_node\`, follow up with \`set_editor_selection({node_paths: ["<new_path>"]})\` so the 2D / 3D gizmo snaps to the new node and the user can immediately tweak it without hunting in the Scene dock.
2. **Highlight what you found.** After a search or a fix, \`set_editor_selection\` draws the user's attention to the relevant node ("here is the one with the typo — selected for you").

\`mode: "add"\` appends to the existing selection (useful for "select all these matches"); the default \`mode: "replace"\` clears first.

## Caveats

- Selection is scoped to the **currently edited scene tab**. Nodes in other open tabs are not selectable without switching tabs first (use \`open_in_godot\` to switch).
- Selection is editor UI state — it's NOT stored in the .tscn and is NOT covered by \`mcp_undo\` (undoing the last selection change isn't really a thing the user expects).
- Paths are scene-relative ("." = scene root, "UI/HUD/Label" for nested), matching \`find_nodes\` / \`scene_tree_dump\` output. Pass them straight to mutation tools.
- If you pass a path that doesn't resolve, \`set_editor_selection\` pre-validates and refuses the whole call (no partial selection change) — fix the typo and retry.
`,
  },
  {
    uri: 'godot-mcp://guide/tool-index',
    slug: 'tool-index',
    name: 'Quick tool index by goal',
    description: 'A flat goal-to-tool index optimized for "I want to do X — which tool?" lookups.',
    mimeType: 'text/markdown',
    text: `# Quick tool index by goal

## Editing files / scripts
- Edit a small chunk of GDScript: \`edit_script\`
- Validate it parses: \`validate_script\`
- Create / delete / rename files: \`create_script\` (.gd only), \`write_file\` (any text), \`delete_file\` (requires \`confirm:true\`), \`delete_folder\` (recursive, requires \`confirm:true\`), \`rename_file\`
- List GDScripts: \`list_scripts\`

## Scenes
- Create / read / hierarchy: \`create_scene\`, \`read_scene\`, \`get_scene_hierarchy\`, \`scene_tree_dump\`
- Add / remove / move / rename / duplicate / reorder nodes: \`add_node\`, \`remove_node\`, \`move_node\`, \`rename_node\`, \`duplicate_node\`, \`reorder_node\`
- Properties on a node: \`modify_node_property\` (one), \`set_node_properties\` (many), \`get_scene_node_properties\` (read all)
- Class-level property metadata: \`get_node_properties\` (with \`node_type\`)
- Groups: \`set_node_groups\`, \`get_node_groups\`, \`find_nodes\` (filter with \`in_group\`)
- Search nodes in a scene: \`find_nodes\` (\`name_pattern\` / \`type\` / \`in_group\` / \`recursive\`)
- Scripts on nodes: \`attach_script\`, \`detach_script\`
- Resources on nodes: \`set_collision_shape\`, \`set_sprite_texture\`, \`set_mesh\`, \`set_material\`, \`set_resource_property\`, \`save_resource_to_file\`
- Resource introspection: \`get_resource_info\`
- Signals: \`list_signal_connections\` (source scene_file or runtime), \`connect_signal\`, \`disconnect_signal\`
- Instancing other scenes: \`instance_scene\`
- 3D math: \`get_node_spatial_info\`, \`measure_node_distance\`, \`snap_node_to_grid\`

## Project / editor
- Settings: \`get_project_settings\`, \`list_settings\`, \`update_project_settings\` (renames are safe)
- Input: \`get_input_map\`, \`configure_input_map\`
- Collision layers: \`get_collision_layers\`
- Autoloads: \`setup_autoload\`
- ClassDB: \`classdb_query\`
- Output / errors: \`get_console_log\`, \`get_errors\`, \`clear_console_log\`
- Filesystem: \`rescan_filesystem\`, \`list_dir\`, \`read_file\`, \`search_project\`
- Open in editor: \`open_in_godot\`
- Selection (Scene dock): \`get_editor_selection\` (read), \`set_editor_selection\` (write) — see \`godot-mcp://guide/selection-workflow\`

## Running the game
- Launch: \`run_scene\` (block_until_started, wait_for_runtime)
- Status: \`is_playing\`, \`get_runtime_status\`
- Runtime tools: \`take_screenshot\`, \`send_input\`, \`query_runtime_node\`, \`get_runtime_log\`, \`get_performance_monitors\`, \`wait\`
- Stop: \`stop_scene\`

## Asset generation
- SVG -> PNG: \`generate_2d_asset\` (now with \`width\`, \`height\`, \`scale\`)

## Composing multi-step work
- Run several mutations as one atomic call: \`batch_execute\` (see \`godot-mcp://guide/batching\`)
- Undo / redo / list AI mutations: \`mcp_undo\`, \`mcp_redo\`, \`mcp_undo_history\`

## Visualizer
- Project + scenes maps: \`map_project\`, \`map_scenes\`
`,
  },
];

export function registerResources(server: Server): void {
  server.setRequestHandler(ListResourcesRequestSchema, async () => ({
    resources: GUIDES.map(({ uri, name, description, mimeType }) => ({
      uri, name, description, mimeType,
    })),
  }));

  server.setRequestHandler(ReadResourceRequestSchema, async (request) => {
    const uri = request.params.uri;
    const guide = GUIDES.find((g) => g.uri === uri);
    if (!guide) {
      throw new Error(`Unknown resource: ${uri}`);
    }
    return {
      contents: [
        {
          uri: guide.uri,
          mimeType: guide.mimeType,
          text: guide.text,
        },
      ],
    };
  });
}
