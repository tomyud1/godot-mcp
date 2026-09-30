/**
 * Tool annotation derivation.
 *
 * The MCP tools spec lets a server declare how risky each tool is
 * (`readOnlyHint`, `destructiveHint`, `idempotentHint`). Clients use these to
 * decide whether to prompt the user before running a call, so getting them
 * right is the difference between "auto-approve reads, confirm writes" and
 * "the agent silently rewrites the project".
 *
 * Annotations are derived from the tool name rather than hand-written on all
 * 82 tools: the prefixes below are stable, and a derived value that is wrong
 * for one tool is corrected by that tool's `annotationOverrides` in its own
 * module. Keeping the derivation in one file means a new tool gets sensible
 * annotations for free instead of silently defaulting to "unknown".
 */

import type { ToolDefinition, ToolAnnotations } from '../types.js';

/** Prefixes that indicate the tool only inspects state. */
const READ_ONLY_PREFIXES = [
  'get_', 'list_', 'read_', 'search_', 'find_', 'query_',
  'validate_', 'measure_', 'is_', 'map_', 'classdb_', 'summarize_',
];

/** Exact tool names that read, despite not matching a read-only prefix. */
const READ_ONLY_EXACT = new Set<string>([
  'read_scene',
  'scene_tree_dump',
  'search_project',
  'take_screenshot',
  'take_editor_viewport_screenshot',
]);

/** Tools that can destroy work and cannot be undone from the tool surface. */
const DESTRUCTIVE = new Set<string>([
  'delete_file',
  'remove_node',
  'rename_file',
  'runtime_eval',
  'stop_scene',
  'clear_console_log',
  'disconnect_signal',
  'update_scene_signal_connections',
]);

/**
 * Tools that mutate, despite looking read-only by name. Derived annotations
 * would otherwise mark these safe and get them auto-approved.
 */
const WRITES_DISGUISED_AS_READS = new Set<string>([
  // Parsing a script can populate the import cache / fix warnings.
  'validate_script',
  // Triggers a filesystem re-scan inside the editor.
  'rescan_filesystem',
  // Rewrites a baked navmesh resource in the project.
  'bake_navigation_mesh',
]);

/**
 * Tools that are safe to repeat with identical arguments. Anything that
 * appends, spawns, or accumulates is excluded by omission.
 */
const IDEMPOTENT_EXACT = new Set<string>([
  ...READ_ONLY_EXACT,
  'get_godot_status',
  'edit_script',
  'modify_node_property',
  'set_node_properties',
  'set_node_groups',
  'set_material',
  'set_mesh',
  'set_collision_shape',
  'set_sprite_texture',
  'set_scene_node_property',
  'set_resource_property',
  'set_navigation_mesh',
  'set_sun_light',
  'configure_input_map',
  'update_project_settings',
  'create_script',
  'create_scene',
  'create_folder',
  'snap_node_to_grid',
  'snap_node_to_ground',
  'place_node_relative',
  'stop_scene',
]);

/** Tools that reach outside the project directory. */
const OPEN_WORLD = new Set<string>([
  'open_in_godot',
  'run_scene',
]);

/**
 * Tools that should always stop for a human, even in permissive client modes.
 *
 * `destructiveHint` is advisory and many clients ignore it, so the strongest
 * lever available to a server is the `_meta` flag below. It is set for the
 * irreversible operations only — auto-prompting on every write would train
 * users to click through confirmations without reading them.
 */
export function requiresUserInteraction(toolName: string): boolean {
  return DESTRUCTIVE.has(toolName);
}

/** Derive the base annotation set for one tool. */
export function deriveAnnotations(tool: Pick<ToolDefinition, 'name' | 'annotationOverrides'>): ToolAnnotations {
  const { name } = tool;

  let readOnly = READ_ONLY_EXACT.has(name) || READ_ONLY_PREFIXES.some((p) => name.startsWith(p));
  // A `validate_`/`get_` tool that actually writes is not read-only.
  if (WRITES_DISGUISED_AS_READS.has(name)) readOnly = false;

  const destructive = DESTRUCTIVE.has(name);

  // Writes are assumed non-idempotent unless explicitly listed: `add_node`
  // twice creates two nodes, `snap_*` accumulates edits, and so on.
  const idempotent = readOnly || IDEMPOTENT_EXACT.has(name);

  const annotations: ToolAnnotations = {
    readOnlyHint: readOnly,
    destructiveHint: destructive,
    idempotentHint: idempotent,
    openWorldHint: OPEN_WORLD.has(name),
  };

  // The tool's own module gets the last word.
  return { ...annotations, ...(tool.annotationOverrides ?? {}) };
}

/** Annotations for the two tools that are defined inline in index.ts. */
export function builtinToolAnnotations(name: string): ToolAnnotations {
  switch (name) {
    case 'get_godot_status':
      return {
        title: 'Get Godot status',
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      };
    case 'get_guide':
      return {
        title: 'Get guide',
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      };
    default:
      return { readOnlyHint: true, destructiveHint: false, idempotentHint: true };
  }
}
