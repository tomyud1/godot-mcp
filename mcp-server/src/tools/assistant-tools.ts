import type { ToolDefinition } from '../types.js';

export const assistantTools: ToolDefinition[] = [
  { name: 'duplicate_node', description: 'Duplicate a node subtree inside a saved scene.', inputSchema: { type: 'object', properties: {
    scene_path: { type: 'string' }, node_path: { type: 'string' }, new_name: { type: 'string' },
  }, required: ['scene_path', 'node_path'] } },
  { name: 'reorder_node', description: 'Move a saved-scene node to a sibling index.', inputSchema: { type: 'object', properties: {
    scene_path: { type: 'string' }, node_path: { type: 'string' }, new_index: { type: 'number' },
  }, required: ['scene_path', 'node_path', 'new_index'] } },
  { name: 'get_scene_hierarchy', description: 'Return a nested hierarchy for a saved scene.', inputSchema: { type: 'object', properties: {
    scene_path: { type: 'string' },
  }, required: ['scene_path'] } },
  { name: 'get_scene_node_properties', description: 'List inspectable properties and current values for a saved-scene node.', inputSchema: { type: 'object', properties: {
    scene_path: { type: 'string' }, node_path: { type: 'string' },
  }, required: ['scene_path', 'node_path'] } },
  { name: 'set_scene_node_property', description: 'Set a typed property on a node in a saved scene.', inputSchema: { type: 'object', properties: {
    scene_path: { type: 'string' }, node_path: { type: 'string' }, property_name: { type: 'string' }, value: {},
    value_type: { type: 'number', description: 'Optional Godot Variant.Type id for parsing structured values.' },
  }, required: ['scene_path', 'node_path', 'property_name', 'value'] } },
  { name: 'map_scenes', description: 'Build a structural map of scene files and their instance relationships.', inputSchema: { type: 'object', properties: {
    root: { type: 'string' }, include_addons: { type: 'boolean' },
  } } },
  { name: 'get_node_property', description: 'Read one property from a node in a saved scene.', inputSchema: { type: 'object', properties: {
    scene_path: { type: 'string' }, node_path: { type: 'string' }, property_name: { type: 'string' },
  }, required: ['scene_path', 'node_path', 'property_name'] } },
  { name: 'parse_tscn_as_json', description: 'Parse a text .tscn into a loss-conscious structured document.', inputSchema: { type: 'object', properties: {
    path: { type: 'string' },
  }, required: ['path'] } },
  { name: 'apply_tscn_json_patch', description: 'Patch sections of a text .tscn document while preserving its section model.', inputSchema: { type: 'object', properties: {
    path: { type: 'string' }, patch: { type: 'object' },
  }, required: ['path', 'patch'] } },
  { name: 'write_tscn_from_json', description: 'Write a .tscn from a parsed document. Use only when explicitly requested.', inputSchema: { type: 'object', properties: {
    path: { type: 'string' }, document: { type: 'object' },
  }, required: ['path', 'document'] } },
  { name: 'list_nodes_in_scene', description: 'List every node path, class, and attached script in a saved scene.', inputSchema: { type: 'object', properties: {
    scene_path: { type: 'string' },
  }, required: ['scene_path'] } },
  { name: 'find_scene_by_name', description: 'Find scene files by filename or root node name.', inputSchema: { type: 'object', properties: {
    name: { type: 'string' },
  }, required: ['name'] } },
  { name: 'instantiate_packed_scene', description: 'Instantiate a packed scene under a node in another saved scene.', inputSchema: { type: 'object', properties: {
    scene_path: { type: 'string' }, parent_path: { type: 'string' }, packed_scene_path: { type: 'string' }, name: { type: 'string' },
  }, required: ['scene_path', 'parent_path', 'packed_scene_path'] } },
  { name: 'list_signals', description: 'List built-in and custom signals exposed by a saved-scene node.', inputSchema: { type: 'object', properties: {
    scene_path: { type: 'string' }, node_path: { type: 'string' },
  }, required: ['scene_path', 'node_path'] } },
  { name: 'godot_class_doc', description: 'Fetch a focused section of the current Godot class reference.', inputSchema: { type: 'object', properties: {
    class_name: { type: 'string' }, section: { type: 'string', enum: ['brief', 'description', 'methods', 'properties', 'signals', 'constants', 'all'] },
    filter: { type: 'string' }, with_description: { type: 'boolean' },
  }, required: ['class_name'] } },
  { name: 'search_godot_docs', description: 'Search stable Godot guides and class documentation.', inputSchema: { type: 'object', properties: {
    query: { type: 'string' }, regex: { type: 'boolean' }, force_online: { type: 'boolean' }, max_results: { type: 'number' },
  }, required: ['query'] } },
  { name: 'capture_editor_screenshot', description: 'Capture the Godot editor viewport and return it as MCP image content.', inputSchema: {
    type: 'object', properties: {},
  } },
  { name: 'execute_gdscript', description: 'Execute an in-memory GDScript snippet inside the editor. Powerful and stateful; use only for bounded Godot API queries or explicitly requested actions.', inputSchema: { type: 'object', properties: {
    code: { type: 'string' }, context: { type: 'object' },
  }, required: ['code'] } },
  { name: 'get_profiler_stats', description: 'Read live performance monitors from the running game.', inputSchema: { type: 'object', properties: {} } },
  { name: 'runtime_inspect', description: 'Inspect selected properties and a bounded subtree of a live runtime node.', inputSchema: { type: 'object', properties: {
    node_path: { type: 'string' }, properties: { type: 'array', items: { type: 'string' } },
    include_tree: { type: 'boolean' }, tree_depth: { type: 'number' },
  }, required: ['node_path'] } },
  { name: 'runtime_find_instances', description: 'Find live nodes by native class, global script class, or script filename.', inputSchema: { type: 'object', properties: {
    pattern: { type: 'string' }, max_results: { type: 'number' },
  }, required: ['pattern'] } },
  { name: 'runtime_call', description: 'Call a method on a live runtime node. Use method set with [property, value] for mutation.', inputSchema: { type: 'object', properties: {
    node_path: { type: 'string' }, method: { type: 'string' }, args: { type: 'array' },
  }, required: ['node_path', 'method'] } },
  { name: 'diagnose_ui', description: 'Diagnose live Control layout, visibility, mouse filtering, focus, and ancestors.', inputSchema: { type: 'object', properties: {
    node_path: { type: 'string' },
  }, required: ['node_path'] } },
];
