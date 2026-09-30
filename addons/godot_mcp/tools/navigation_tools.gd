@tool
extends Node
class_name NavigationTools
## Navigation mesh tools for MCP.
## Handles: set_navigation_mesh, get_navigation_mesh_info, bake_navigation_mesh

const SceneToolContext = preload("res://addons/godot_mcp/utils/scene_tool_context.gd")

const _REGION_BOOL_SETTINGS := [
	"enabled",
	"use_edge_connections",
]

const _REGION_FLOAT_SETTINGS := [
	"enter_cost",
	"travel_cost",
]

const _REGION_INT_SETTINGS := [
	"navigation_layers",
]

const _NAVMESH_FLOAT_SETTINGS := [
	"agent_radius",
	"agent_height",
	"agent_max_climb",
	"agent_max_slope",
	"border_size",
	"cell_size",
	"cell_height",
	"detail_sample_distance",
	"detail_sample_max_error",
	"edge_max_error",
	"edge_max_length",
	"region_merge_size",
	"region_min_size",
	"vertices_per_polygon",
]

const _NAVMESH_BOOL_SETTINGS := [
	"filter_ledge_spans",
	"filter_low_hanging_obstacles",
	"filter_walkable_low_height_spans",
]

const _NAVMESH_INT_SETTINGS := [
	"geometry_collision_mask",
]

const _PARSED_GEOMETRY_TYPES := {
	"mesh_instances": NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES,
	"static_colliders": NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS,
	"both": NavigationMesh.PARSED_GEOMETRY_BOTH,
}

const _SOURCE_GEOMETRY_MODES := {
	"root_node_children": NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN,
	"groups_with_children": NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN,
	"groups_explicit": NavigationMesh.SOURCE_GEOMETRY_GROUPS_EXPLICIT,
}

const _SAMPLE_PARTITION_TYPES := {
	"watershed": NavigationMesh.SAMPLE_PARTITION_WATERSHED,
	"monotone": NavigationMesh.SAMPLE_PARTITION_MONOTONE,
	"layers": NavigationMesh.SAMPLE_PARTITION_LAYERS,
}

const _REGION_SETTING_ALIASES := {
	"layers": "navigation_layers",
}

const _NAVMESH_SETTING_ALIASES := {
	"parsed_geometry_type": "geometry_parsed_geometry_type",
	"source_geometry_mode": "geometry_source_geometry_mode",
	"source_group_name": "geometry_source_group_name",
	"collision_mask": "geometry_collision_mask",
}

var _context := SceneToolContext.new()

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_context.set_owner_name("NavigationTools")
	_context.set_editor_plugin(plugin)

func set_scene_tools_ref(scene_tools: Node) -> void:
	_context.set_scene_tools_ref(scene_tools)

func _require_scene_tools() -> Dictionary:
	return _context.require_scene_tools()

func _load_scene(scene_path: String) -> Array:
	return _context.load_scene(scene_path)

func _save_scene(scene_root: Node, scene_path: String) -> Dictionary:
	return _context.save_scene(scene_root, scene_path)

func _find_node(scene_root: Node, node_path: String) -> Node:
	return _context.find_node(scene_root, node_path)

func _ensure_res_path(path: String) -> String:
	return _context.ensure_res_path(path)

func _parse_value(value: Variant) -> Variant:
	return _context.parse_value(value)

func _parse_typed_value(value: Variant, type_hint: int) -> Variant:
	return _context.parse_typed_value(value, type_hint)

func _serialize_value(value: Variant) -> Variant:
	return _context.serialize_value(value)

func _find_navigation_region(root: Node, node_path: String) -> Array:
	var target = _find_node(root, node_path)
	if not target:
		return [null, {&"ok": false, &"error": "Node not found: " + node_path}]
	if not (target is NavigationRegion3D):
		return [null, {&"ok": false, &"error": "Node '%s' (%s) is not a NavigationRegion3D" % [node_path, target.get_class()]}]
	return [target, {}]

func _parse_navigation_enum(value: Variant, mapping: Dictionary) -> Variant:
	if typeof(value) == TYPE_INT:
		var numeric_value: int = int(value)
		if mapping.values().has(numeric_value):
			return numeric_value
		return null

	var key := str(value).to_lower()
	if mapping.has(key):
		return mapping[key]
	return null

func _enum_name(value: int, mapping: Dictionary) -> String:
	for key in mapping:
		if mapping[key] == value:
			return str(key)
	return ""

func _normalize_region_setting_name(setting_name: String) -> String:
	return _REGION_SETTING_ALIASES.get(setting_name, setting_name)

func _normalize_navmesh_setting_name(setting_name: String) -> String:
	return _NAVMESH_SETTING_ALIASES.get(setting_name, setting_name)

func _is_external_navigation_mesh_resource(navigation_mesh: NavigationMesh) -> bool:
	if not navigation_mesh:
		return false
	if navigation_mesh.resource_path.is_empty():
		return false
	return navigation_mesh.resource_path.find("::") == -1

func _apply_region_settings(region: NavigationRegion3D, settings: Variant) -> Dictionary:
	if settings == null:
		return {}
	if not (settings is Dictionary):
		return {&"ok": false, &"error": "'region_settings' must be a dictionary"}

	var region_settings: Dictionary = settings
	for key in region_settings:
		var setting_name := _normalize_region_setting_name(str(key))
		var setting_value = region_settings[key]

		if setting_name in _REGION_BOOL_SETTINGS:
			region.set(setting_name, bool(setting_value))
		elif setting_name in _REGION_FLOAT_SETTINGS:
			region.set(setting_name, float(setting_value))
		elif setting_name in _REGION_INT_SETTINGS:
			region.set(setting_name, int(setting_value))
		else:
			return {&"ok": false, &"error": "Unknown NavigationRegion3D setting: " + setting_name}

	return {}

func _apply_navigation_mesh_settings(navigation_mesh: NavigationMesh, settings: Variant) -> Dictionary:
	if settings == null:
		return {}
	if not (settings is Dictionary):
		return {&"ok": false, &"error": "'navigation_mesh_settings' must be a dictionary"}

	var nav_settings: Dictionary = settings
	for key in nav_settings:
		var setting_name := _normalize_navmesh_setting_name(str(key))
		var setting_value = nav_settings[key]

		if setting_name in _NAVMESH_FLOAT_SETTINGS:
			navigation_mesh.set(setting_name, float(setting_value))
		elif setting_name in _NAVMESH_BOOL_SETTINGS:
			navigation_mesh.set(setting_name, bool(setting_value))
		elif setting_name in _NAVMESH_INT_SETTINGS:
			navigation_mesh.set(setting_name, int(setting_value))
		elif setting_name == "geometry_source_group_name":
			navigation_mesh.geometry_source_group_name = StringName(str(setting_value))
		elif setting_name == "geometry_parsed_geometry_type":
			var parsed_geometry = _parse_navigation_enum(setting_value, _PARSED_GEOMETRY_TYPES)
			if parsed_geometry == null:
				return {&"ok": false, &"error": "Invalid geometry_parsed_geometry_type. Use mesh_instances, static_colliders, both, or a numeric enum value."}
			navigation_mesh.geometry_parsed_geometry_type = int(parsed_geometry)
		elif setting_name == "geometry_source_geometry_mode":
			var source_mode = _parse_navigation_enum(setting_value, _SOURCE_GEOMETRY_MODES)
			if source_mode == null:
				return {&"ok": false, &"error": "Invalid geometry_source_geometry_mode. Use root_node_children, groups_with_children, groups_explicit, or a numeric enum value."}
			navigation_mesh.geometry_source_geometry_mode = int(source_mode)
		elif setting_name == "sample_partition_type":
			var partition_type = _parse_navigation_enum(setting_value, _SAMPLE_PARTITION_TYPES)
			if partition_type == null:
				return {&"ok": false, &"error": "Invalid sample_partition_type. Use watershed, monotone, layers, or a numeric enum value."}
			navigation_mesh.sample_partition_type = int(partition_type)
		elif setting_name == "filter_baking_aabb":
			var parsed_aabb = _parse_typed_value(setting_value, TYPE_AABB)
			if not (parsed_aabb is AABB):
				return {&"ok": false, &"error": "filter_baking_aabb must be an AABB-compatible value"}
			navigation_mesh.filter_baking_aabb = parsed_aabb
		elif setting_name == "filter_baking_aabb_offset":
			var parsed_offset = _parse_typed_value(setting_value, TYPE_VECTOR3)
			if not (parsed_offset is Vector3):
				return {&"ok": false, &"error": "filter_baking_aabb_offset must be a Vector3-compatible value"}
			navigation_mesh.filter_baking_aabb_offset = parsed_offset
		else:
			return {&"ok": false, &"error": "Unknown NavigationMesh setting: " + setting_name}

	return {}

func _prepare_navigation_mesh(region: NavigationRegion3D, create_if_missing: bool, duplicate_external_resource: bool) -> Array:
	var created := false
	var duplicated_external := false
	var navigation_mesh: NavigationMesh = region.navigation_mesh

	if not navigation_mesh:
		if not create_if_missing:
			return [null, created, duplicated_external]
		navigation_mesh = NavigationMesh.new()
		region.navigation_mesh = navigation_mesh
		created = true
	elif duplicate_external_resource and _is_external_navigation_mesh_resource(navigation_mesh):
		var duplicated = navigation_mesh.duplicate(true)
		if not (duplicated is NavigationMesh):
			return [null, created, duplicated_external]
		navigation_mesh = duplicated
		navigation_mesh.resource_local_to_scene = true
		region.navigation_mesh = navigation_mesh
		duplicated_external = true

	return [navigation_mesh, created, duplicated_external]

func _compute_bounds_from_vertices(vertices: PackedVector3Array) -> Variant:
	if vertices.is_empty():
		return null

	var min_corner: Vector3 = vertices[0]
	var max_corner: Vector3 = vertices[0]
	for vertex: Vector3 in vertices:
		min_corner = Vector3(
			minf(min_corner.x, vertex.x),
			minf(min_corner.y, vertex.y),
			minf(min_corner.z, vertex.z)
		)
		max_corner = Vector3(
			maxf(max_corner.x, vertex.x),
			maxf(max_corner.y, vertex.y),
			maxf(max_corner.z, vertex.z)
		)

	return AABB(min_corner, max_corner - min_corner)

func _collect_navigation_mesh_info(region: NavigationRegion3D) -> Dictionary:
	var info := {
		&"node_name": region.name,
		&"node_type": region.get_class(),
		&"enabled": region.enabled,
		&"navigation_layers": region.navigation_layers,
		&"enter_cost": region.enter_cost,
		&"travel_cost": region.travel_cost,
		&"use_edge_connections": region.use_edge_connections,
	}

	var navigation_mesh: NavigationMesh = region.navigation_mesh
	info[&"has_navigation_mesh"] = navigation_mesh != null

	if not navigation_mesh:
		return info

	var vertices: PackedVector3Array = navigation_mesh.get_vertices()
	var polygon_count: int = navigation_mesh.get_polygon_count()
	info[&"navigation_mesh"] = {
		&"resource_path": navigation_mesh.resource_path,
		&"resource_local_to_scene": navigation_mesh.resource_local_to_scene,
		&"resource_is_external": _is_external_navigation_mesh_resource(navigation_mesh),
		&"agent_radius": navigation_mesh.agent_radius,
		&"agent_height": navigation_mesh.agent_height,
		&"agent_max_climb": navigation_mesh.agent_max_climb,
		&"agent_max_slope": navigation_mesh.agent_max_slope,
		&"border_size": navigation_mesh.border_size,
		&"cell_size": navigation_mesh.cell_size,
		&"cell_height": navigation_mesh.cell_height,
		&"detail_sample_distance": navigation_mesh.detail_sample_distance,
		&"detail_sample_max_error": navigation_mesh.detail_sample_max_error,
		&"edge_max_error": navigation_mesh.edge_max_error,
		&"edge_max_length": navigation_mesh.edge_max_length,
		&"filter_ledge_spans": navigation_mesh.filter_ledge_spans,
		&"filter_low_hanging_obstacles": navigation_mesh.filter_low_hanging_obstacles,
		&"filter_walkable_low_height_spans": navigation_mesh.filter_walkable_low_height_spans,
		&"filter_baking_aabb": _serialize_value(navigation_mesh.filter_baking_aabb),
		&"filter_baking_aabb_offset": _serialize_value(navigation_mesh.filter_baking_aabb_offset),
		&"geometry_collision_mask": navigation_mesh.geometry_collision_mask,
		&"geometry_parsed_geometry_type": navigation_mesh.geometry_parsed_geometry_type,
		&"geometry_parsed_geometry_type_name": _enum_name(navigation_mesh.geometry_parsed_geometry_type, _PARSED_GEOMETRY_TYPES),
		&"geometry_source_geometry_mode": navigation_mesh.geometry_source_geometry_mode,
		&"geometry_source_geometry_mode_name": _enum_name(navigation_mesh.geometry_source_geometry_mode, _SOURCE_GEOMETRY_MODES),
		&"geometry_source_group_name": str(navigation_mesh.geometry_source_group_name),
		&"sample_partition_type": navigation_mesh.sample_partition_type,
		&"sample_partition_type_name": _enum_name(navigation_mesh.sample_partition_type, _SAMPLE_PARTITION_TYPES),
		&"region_merge_size": navigation_mesh.region_merge_size,
		&"region_min_size": navigation_mesh.region_min_size,
		&"vertices_per_polygon": navigation_mesh.vertices_per_polygon,
		&"polygon_count": polygon_count,
		&"vertex_count": vertices.size(),
		&"has_baked_data": polygon_count > 0 and not vertices.is_empty(),
	}

	var baked_bounds = _compute_bounds_from_vertices(vertices)
	if baked_bounds is AABB:
		info[&"navigation_mesh"][&"baked_bounds"] = _serialize_value(baked_bounds)

	return info

func _get_scene_tree() -> SceneTree:
	return _context.get_scene_tree()

func _bake_navigation_region_in_tree(scene_root: Node, region: NavigationRegion3D) -> Dictionary:
	var mount_result := _context.mount_scene_root(scene_root, "_MCPNavigationBakeRoot")
	if not mount_result[1].is_empty():
		return mount_result[1]
	var helper: Node = mount_result[0]

	# NavigationRegion3D baking requires the root node to be inside a SceneTree.
	region.bake_navigation_mesh(false)

	_context.unmount_scene_root(scene_root, helper)

	return {}

func _extract_navigation_mesh_settings(args: Dictionary) -> Variant:
	if args.has(&"navigation_mesh_settings"):
		return args[&"navigation_mesh_settings"]
	if args.has(&"settings"):
		return args[&"settings"]
	return {}

func set_navigation_mesh(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var _gate := MCPPaths.check(scene_path, false)
	if not _gate.is_empty():
		return _gate
	var node_path: String = str(args.get(&"node_path", "."))
	var create_if_missing: bool = bool(args.get(&"create_if_missing", true))
	var duplicate_external_resource: bool = bool(args.get(&"duplicate_external_resource", true))
	var navigation_mesh_settings = _extract_navigation_mesh_settings(args)
	var region_settings = args.get(&"region_settings", {})

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var region_result := _find_navigation_region(root, node_path)
	if not region_result[1].is_empty():
		root.queue_free()
		return region_result[1]

	var region: NavigationRegion3D = region_result[0]
	var region_error := _apply_region_settings(region, region_settings)
	if not region_error.is_empty():
		root.queue_free()
		return region_error

	var navmesh_result := _prepare_navigation_mesh(region, create_if_missing, duplicate_external_resource)
	var navigation_mesh: NavigationMesh = navmesh_result[0]
	var created_navigation_mesh: bool = navmesh_result[1]
	var duplicated_external_resource_result: bool = navmesh_result[2]
	if not navigation_mesh:
		root.queue_free()
		return {&"ok": false, &"error": "NavigationRegion3D has no navigation_mesh. Set create_if_missing=true to create one."}

	var settings_error := _apply_navigation_mesh_settings(navigation_mesh, navigation_mesh_settings)
	if not settings_error.is_empty():
		root.queue_free()
		return settings_error

	var info := _collect_navigation_mesh_info(region)
	var save_error := _save_scene(root, scene_path)
	if not save_error.is_empty():
		return save_error

	info[&"ok"] = true
	info[&"scene_path"] = scene_path
	info[&"node_path"] = node_path
	info[&"created_navigation_mesh"] = created_navigation_mesh
	info[&"duplicated_external_resource"] = duplicated_external_resource_result
	info[&"message"] = "Updated NavigationMesh on '%s'" % node_path
	return info

func get_navigation_mesh_info(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var _gate := MCPPaths.check(scene_path, false)
	if not _gate.is_empty():
		return _gate
	var node_path: String = str(args.get(&"node_path", "."))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var region_result := _find_navigation_region(root, node_path)
	if not region_result[1].is_empty():
		root.queue_free()
		return region_result[1]

	var region: NavigationRegion3D = region_result[0]
	var info := _collect_navigation_mesh_info(region)
	root.queue_free()

	info[&"ok"] = true
	info[&"scene_path"] = scene_path
	info[&"node_path"] = node_path
	return info

func bake_navigation_mesh(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var _gate := MCPPaths.check(scene_path, false)
	if not _gate.is_empty():
		return _gate
	var node_path: String = str(args.get(&"node_path", "."))
	var create_if_missing: bool = bool(args.get(&"create_if_missing", true))
	var duplicate_external_resource: bool = bool(args.get(&"duplicate_external_resource", true))
	var navigation_mesh_settings = _extract_navigation_mesh_settings(args)
	var region_settings = args.get(&"region_settings", {})

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var region_result := _find_navigation_region(root, node_path)
	if not region_result[1].is_empty():
		root.queue_free()
		return region_result[1]

	var region: NavigationRegion3D = region_result[0]
	var region_error := _apply_region_settings(region, region_settings)
	if not region_error.is_empty():
		root.queue_free()
		return region_error

	var navmesh_result := _prepare_navigation_mesh(region, create_if_missing, duplicate_external_resource)
	var navigation_mesh: NavigationMesh = navmesh_result[0]
	var created_navigation_mesh: bool = navmesh_result[1]
	var duplicated_external_resource_result: bool = navmesh_result[2]
	if not navigation_mesh:
		root.queue_free()
		return {&"ok": false, &"error": "NavigationRegion3D has no navigation_mesh. Set create_if_missing=true to create one before baking."}

	var settings_error := _apply_navigation_mesh_settings(navigation_mesh, navigation_mesh_settings)
	if not settings_error.is_empty():
		root.queue_free()
		return settings_error

	# Use the region API directly so this stays on the non-deprecated bake path.
	var bake_error := _bake_navigation_region_in_tree(root, region)
	if not bake_error.is_empty():
		root.queue_free()
		return bake_error

	if not region.navigation_mesh:
		root.queue_free()
		return {&"ok": false, &"error": "Navigation mesh bake completed without producing a NavigationMesh resource"}

	var info := _collect_navigation_mesh_info(region)
	var save_error := _save_scene(root, scene_path)
	if not save_error.is_empty():
		return save_error

	info[&"ok"] = true
	info[&"scene_path"] = scene_path
	info[&"node_path"] = node_path
	info[&"created_navigation_mesh"] = created_navigation_mesh
	info[&"duplicated_external_resource"] = duplicated_external_resource_result
	info[&"message"] = "Baked NavigationMesh for '%s'" % node_path
	return info
