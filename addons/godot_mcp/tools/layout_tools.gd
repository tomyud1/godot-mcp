@tool
extends Node
class_name LayoutTools
## Scene layout analysis tools for MCP.
## Handles: summarize_scene_layout

const SceneToolContext = preload("res://addons/godot_mcp/utils/scene_tool_context.gd")

var _context := SceneToolContext.new()

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_context.set_owner_name("LayoutTools")
	_context.set_editor_plugin(plugin)

func set_scene_tools_ref(scene_tools: Node) -> void:
	_context.set_scene_tools_ref(scene_tools)

func _serialize_value(value: Variant) -> Variant:
	return _context.serialize_value(value)

func _node_path_from_root(root: Node, target: Node) -> String:
	if root == target:
		return "."
	var relative := str(root.get_path_to(target))
	return "." if relative.is_empty() else relative

func _merge_aabb(a: AABB, b: AABB) -> AABB:
	var min_corner := Vector3(
		minf(a.position.x, b.position.x),
		minf(a.position.y, b.position.y),
		minf(a.position.z, b.position.z)
	)
	var a_end: Vector3 = a.position + a.size
	var b_end: Vector3 = b.position + b.size
	var max_corner := Vector3(
		maxf(a_end.x, b_end.x),
		maxf(a_end.y, b_end.y),
		maxf(a_end.z, b_end.z)
	)
	return AABB(min_corner, max_corner - min_corner)

func _footprint_from_aabb(aabb: AABB) -> Dictionary:
	return {
		&"min_x": aabb.position.x,
		&"max_x": aabb.position.x + aabb.size.x,
		&"min_z": aabb.position.z,
		&"max_z": aabb.position.z + aabb.size.z,
		&"width": aabb.size.x,
		&"depth": aabb.size.z,
	}

func _aabb_from_points(points: PackedVector3Array) -> Variant:
	if points.is_empty():
		return null

	var min_corner: Vector3 = points[0]
	var max_corner: Vector3 = points[0]
	for point: Vector3 in points:
		min_corner = Vector3(
			minf(min_corner.x, point.x),
			minf(min_corner.y, point.y),
			minf(min_corner.z, point.z)
		)
		max_corner = Vector3(
			maxf(max_corner.x, point.x),
			maxf(max_corner.y, point.y),
			maxf(max_corner.z, point.z)
		)

	return AABB(min_corner, max_corner - min_corner)

func _transform_aabb(aabb: AABB, transform: Transform3D) -> AABB:
	var corners: Array[Vector3] = [
		aabb.position,
		aabb.position + Vector3(aabb.size.x, 0, 0),
		aabb.position + Vector3(0, aabb.size.y, 0),
		aabb.position + Vector3(0, 0, aabb.size.z),
		aabb.position + Vector3(aabb.size.x, aabb.size.y, 0),
		aabb.position + Vector3(aabb.size.x, 0, aabb.size.z),
		aabb.position + Vector3(0, aabb.size.y, aabb.size.z),
		aabb.position + aabb.size,
	]

	var transformed_points := PackedVector3Array()
	for point: Vector3 in corners:
		transformed_points.append(transform * point)

	return _aabb_from_points(transformed_points)

func _local_aabb_for_shape(shape: Shape3D) -> Variant:
	if not shape:
		return null

	if shape is BoxShape3D:
		var size: Vector3 = shape.size
		return AABB(-size * 0.5, size)
	if shape is SphereShape3D:
		var radius: float = shape.radius
		return AABB(Vector3(-radius, -radius, -radius), Vector3(radius * 2.0, radius * 2.0, radius * 2.0))
	if shape is CylinderShape3D:
		var cylinder_radius: float = shape.radius
		var cylinder_height: float = shape.height
		return AABB(
			Vector3(-cylinder_radius, -cylinder_height * 0.5, -cylinder_radius),
			Vector3(cylinder_radius * 2.0, cylinder_height, cylinder_radius * 2.0)
		)
	if shape is CapsuleShape3D:
		var capsule_radius: float = shape.radius
		var capsule_height: float = shape.height
		return AABB(
			Vector3(-capsule_radius, -capsule_height * 0.5, -capsule_radius),
			Vector3(capsule_radius * 2.0, capsule_height, capsule_radius * 2.0)
		)
	if shape is ConvexPolygonShape3D:
		return _aabb_from_points(shape.points)
	if shape is ConcavePolygonShape3D:
		return _aabb_from_points(shape.get_faces())

	return null

func _collision_shape_global_aabb(shape_node: CollisionShape3D) -> Variant:
	if not shape_node.shape or shape_node.disabled:
		return null

	var local_aabb = _local_aabb_for_shape(shape_node.shape)
	if not (local_aabb is AABB):
		return null

	var global_transform: Transform3D = _context.get_node3d_global_transform(shape_node)
	return _transform_aabb(local_aabb, global_transform)

func _collect_collision_shapes(root: Node, node: Node, out: Array) -> void:
	if node is CollisionShape3D:
		var shape_node: CollisionShape3D = node
		var parent_collision_object := shape_node.get_parent()
		var global_aabb = _collision_shape_global_aabb(shape_node)
		if global_aabb is AABB:
			out.append({
				&"node": shape_node,
				&"node_path": _node_path_from_root(root, shape_node),
				&"collision_object_path": _node_path_from_root(root, parent_collision_object) if parent_collision_object is Node else "",
				&"collision_object_type": parent_collision_object.get_class() if parent_collision_object is Node else "",
				&"shape_type": shape_node.shape.get_class(),
				&"global_aabb": global_aabb,
			})

	for child: Node in node.get_children():
		_collect_collision_shapes(root, child, out)

func _classify_collision_entry(entry: Dictionary, floor_height_threshold: float, wall_height_threshold: float, thin_threshold: float) -> String:
	var aabb: AABB = entry[&"global_aabb"]
	var width := aabb.size.x
	var height := aabb.size.y
	var depth := aabb.size.z

	if height <= floor_height_threshold and maxf(width, depth) >= thin_threshold * 2.0:
		return "floor"
	if height >= wall_height_threshold:
		if width <= thin_threshold and depth > width:
			return "wall_x_constant"
		if depth <= thin_threshold and width > depth:
			return "wall_z_constant"
	return "obstacle"

func _wall_segment_from_entry(entry: Dictionary, classification: String) -> Dictionary:
	var aabb: AABB = entry[&"global_aabb"]
	var footprint := _footprint_from_aabb(aabb)
	if classification == "wall_x_constant":
		return {
			&"orientation": "x_constant",
			&"line_coordinate": aabb.position.x + aabb.size.x * 0.5,
			&"start": footprint[&"min_z"],
			&"end": footprint[&"max_z"],
			&"thickness": aabb.size.x,
			&"height": aabb.size.y,
			&"node_path": entry[&"node_path"],
		}
	return {
		&"orientation": "z_constant",
		&"line_coordinate": aabb.position.z + aabb.size.z * 0.5,
		&"start": footprint[&"min_x"],
		&"end": footprint[&"max_x"],
		&"thickness": aabb.size.z,
		&"height": aabb.size.y,
		&"node_path": entry[&"node_path"],
	}

func _group_walls_by_line(walls: Array, line_merge_tolerance: float) -> Dictionary:
	var groups: Dictionary = {}
	for wall in walls:
		var orientation: String = wall[&"orientation"]
		var line_coordinate: float = wall[&"line_coordinate"]
		var bucket_key := "%s:%.3f" % [orientation, snappedf(line_coordinate, maxf(line_merge_tolerance, 0.001))]
		if not groups.has(bucket_key):
			groups[bucket_key] = []
		groups[bucket_key].append(wall)
	return groups

func _sort_wall_intervals(a: Dictionary, b: Dictionary) -> bool:
	return float(a[&"start"]) < float(b[&"start"])

func _detect_openings(walls: Array, line_merge_tolerance: float, min_opening_width: float) -> Array:
	var openings: Array = []
	var grouped_walls := _group_walls_by_line(walls, line_merge_tolerance)

	for bucket_key in grouped_walls:
		var group: Array = grouped_walls[bucket_key]
		group.sort_custom(_sort_wall_intervals)

		for i: int in range(group.size() - 1):
			var left: Dictionary = group[i]
			var right: Dictionary = group[i + 1]
			var gap_start := float(left[&"end"])
			var gap_end := float(right[&"start"])
			var gap_width := gap_end - gap_start
			if gap_width < min_opening_width:
				continue

			var orientation: String = left[&"orientation"]
			var line_coordinate: float = left[&"line_coordinate"]
			var center := Vector3.ZERO
			if orientation == "x_constant":
				center = Vector3(line_coordinate, 0.0, gap_start + gap_width * 0.5)
			else:
				center = Vector3(gap_start + gap_width * 0.5, 0.0, line_coordinate)

			openings.append({
				&"orientation": orientation,
				&"line_coordinate": line_coordinate,
				&"start": gap_start,
				&"end": gap_end,
				&"width": gap_width,
				&"center": _serialize_value(center),
				&"between_nodes": [left[&"node_path"], right[&"node_path"]],
			})

	return openings

func summarize_scene_layout(args: Dictionary) -> Dictionary:
	var scene_path: String = _context.ensure_res_path(str(args.get(&"scene_path", "")))
	var runtime: bool = bool(args.get(&"runtime", false))
	var floor_height_threshold: float = float(args.get(&"floor_height_threshold", 0.75))
	var wall_height_threshold: float = float(args.get(&"wall_height_threshold", 1.5))
	var thin_threshold: float = float(args.get(&"thin_threshold", 1.0))
	var line_merge_tolerance: float = float(args.get(&"line_merge_tolerance", 0.25))
	var min_opening_width: float = float(args.get(&"min_opening_width", 0.75))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var inspection_result := _context.load_inspection_root(scene_path, runtime)
	if not inspection_result[1].is_empty():
		return inspection_result[1]

	var root: Node = inspection_result[0]
	var inspection_source: String = inspection_result[2]
	var should_free: bool = inspection_result[3]

	var collision_entries: Array = []
	_collect_collision_shapes(root, root, collision_entries)

	var scene_bounds: Variant = null
	var floors: Array = []
	var walls: Array = []
	var obstacles: Array = []
	var all_shapes: Array = []

	for entry in collision_entries:
		var aabb: AABB = entry[&"global_aabb"]
		scene_bounds = aabb if scene_bounds == null else _merge_aabb(scene_bounds, aabb)

		var classification := _classify_collision_entry(entry, floor_height_threshold, wall_height_threshold, thin_threshold)
		var item := {
			&"node_path": entry[&"node_path"],
			&"collision_object_path": entry[&"collision_object_path"],
			&"collision_object_type": entry[&"collision_object_type"],
			&"shape_type": entry[&"shape_type"],
			&"classification": classification,
			&"global_aabb": _serialize_value(aabb),
			&"footprint": _footprint_from_aabb(aabb),
			&"bottom_y": aabb.position.y,
			&"top_y": aabb.position.y + aabb.size.y,
		}
		all_shapes.append(item)

		match classification:
			"floor":
				floors.append(item)
			"wall_x_constant", "wall_z_constant":
				var wall_segment := _wall_segment_from_entry(entry, classification)
				for key in wall_segment:
					item[key] = wall_segment[key]
				walls.append(item)
			_:
				obstacles.append(item)

	var openings := _detect_openings(walls, line_merge_tolerance, min_opening_width)
	var floorplan_bounds := {}
	if scene_bounds is AABB:
		floorplan_bounds = _footprint_from_aabb(scene_bounds)

	_context.release_scene_root(root, should_free)

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"inspection_source": inspection_source,
		&"runtime_scope": "editor_live_scene" if inspection_source == "editor_live" else "scene_file",
		&"scene_bounds": _serialize_value(scene_bounds) if scene_bounds is AABB else null,
		&"floorplan_bounds": floorplan_bounds,
		&"collision_shape_count": all_shapes.size(),
		&"floor_count": floors.size(),
		&"wall_count": walls.size(),
		&"obstacle_count": obstacles.size(),
		&"opening_count": openings.size(),
		&"floors": floors,
		&"walls": walls,
		&"obstacles": obstacles,
		&"openings": openings,
		&"collision_shapes": all_shapes,
		&"message": "Summarized scene layout from %d collision shape(s)" % all_shapes.size(),
	}
