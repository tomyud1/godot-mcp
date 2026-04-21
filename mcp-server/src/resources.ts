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
| Verify which nodes belong to a group            | \`find_nodes_in_group\`                                      |
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
    uri: 'godot-mcp://guide/tool-index',
    slug: 'tool-index',
    name: 'Quick tool index by goal',
    description: 'A flat goal-to-tool index optimized for "I want to do X — which tool?" lookups.',
    mimeType: 'text/markdown',
    text: `# Quick tool index by goal

## Editing files / scripts
- Edit a small chunk of GDScript: \`edit_script\`
- Validate it parses: \`validate_script\`
- Create / delete / rename files: \`create_script\`, \`delete_file\` (requires \`confirm:true\`), \`rename_file\`
- List GDScripts: \`list_scripts\`

## Scenes
- Create / read / hierarchy: \`create_scene\`, \`read_scene\`, \`get_scene_hierarchy\`, \`scene_tree_dump\`
- Add / remove / move / rename / duplicate / reorder nodes: \`add_node\`, \`remove_node\`, \`move_node\`, \`rename_node\`, \`duplicate_node\`, \`reorder_node\`
- Properties on a node: \`modify_node_property\` (one), \`set_node_properties\` (many), \`get_scene_node_properties\` (read all)
- Class-level property metadata: \`get_node_properties\` (with \`node_type\`)
- Groups: \`set_node_groups\`, \`get_node_groups\`, \`find_nodes_in_group\`
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

## Running the game
- Launch: \`run_scene\` (block_until_started, wait_for_runtime)
- Status: \`is_playing\`, \`get_runtime_status\`
- Runtime tools: \`take_screenshot\`, \`send_input\`, \`query_runtime_node\`, \`get_runtime_log\`, \`wait\`
- Stop: \`stop_scene\`

## Asset generation
- SVG -> PNG: \`generate_2d_asset\` (now with \`width\`, \`height\`, \`scale\`)

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
