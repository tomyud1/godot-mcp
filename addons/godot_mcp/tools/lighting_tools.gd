@tool
extends Node
class_name LightingTools
## Lighting tools for MCP.
## Handles: get_light_info, set_sun_light, validate_scene_lighting

const SceneToolContext = preload("res://addons/godot_mcp/utils/scene_tool_context.gd")

const _EULER_ORDER := EULER_ORDER_YXZ
const _EULER_ORDER_NAME := "YXZ"

const _DIRECTIONAL_SHADOW_MODES := {
	"orthogonal": DirectionalLight3D.SHADOW_ORTHOGONAL,
	"parallel_2_splits": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
	"parallel_4_splits": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
}

const _DIRECTIONAL_SKY_MODES := {
	"light_and_sky": DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY,
	"light_only": DirectionalLight3D.SKY_MODE_LIGHT_ONLY,
	"sky_only": DirectionalLight3D.SKY_MODE_SKY_ONLY,
}

const _LIGHT_SETTING_KEYS := [
	"color",
	"energy",
	"indirect_energy",
	"volumetric_fog_energy",
	"specular",
	"temperature_kelvin",
	"angular_distance",
	"shadow_enabled",
	"shadow_bias",
	"shadow_normal_bias",
	"shadow_blur",
	"light_cull_mask",
	"shadow_caster_mask",
	"editor_only",
	"visible",
	"sky_mode",
	"directional_shadow_mode",
	"directional_shadow_max_distance",
	"directional_shadow_blend_splits",
	"directional_shadow_fade_start",
	"directional_shadow_split_1",
	"directional_shadow_split_2",
	"directional_shadow_split_3",
	"directional_shadow_pancake_size",
]

const _SCRIPT_OVERRIDE_KEYWORDS := [
	"rotation_degrees",
	"rotation",
	"global_rotation",
	"transform",
	"global_transform",
	"basis",
	"look_at(",
	"look_at_from_position(",
	"quaternion",
	"light_energy",
	"shadow_enabled",
]

var _context := SceneToolContext.new()

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_context.set_owner_name("LightingTools")
	_context.set_editor_plugin(plugin)

func set_scene_tools_ref(scene_tools: Node) -> void:
	_context.set_scene_tools_ref(scene_tools)

func _require_scene_tools() -> Dictionary:
	return _context.require_scene_tools()

func _load_scene(scene_path: String) -> Array:
	return _context.load_scene(scene_path)

func _save_scene(scene_root: Node, scene_path: String) -> Dictionary:
	return _context.save_scene(scene_root, scene_path)

func _release_scene_root(scene_root: Node, should_free: bool) -> void:
	_context.release_scene_root(scene_root, should_free)

func _find_node(scene_root: Node, node_path: String) -> Node:
	return _context.find_node(scene_root, node_path)

func _ensure_res_path(path: String) -> String:
	return _context.ensure_res_path(path)

func _serialize_value(value: Variant) -> Variant:
	return _context.serialize_value(value)

func _parse_typed_value(value: Variant, type_hint: int) -> Variant:
	return _context.parse_typed_value(value, type_hint)

func _get_node3d_global_transform(node: Node3D) -> Transform3D:
	return _context.get_node3d_global_transform(node)

func _set_node3d_global_transform(node: Node3D, global_transform: Transform3D) -> void:
	_context.set_node3d_global_transform(node, global_transform)

func _load_inspection_root(scene_path: String, runtime: bool) -> Array:
	return _context.load_inspection_root(scene_path, runtime)

func _find_first_node_by_class(node: Node, target_class_name: String) -> Node:
	if node.is_class(target_class_name):
		return node
	for child: Node in node.get_children():
		var found = _find_first_node_by_class(child, target_class_name)
		if found:
			return found
	return null

func _resolve_light_target(root: Node, node_path: String, target_class_name: String) -> Array:
	var normalized_path := node_path.strip_edges()
	if normalized_path.is_empty() or normalized_path == ".":
		var auto_target = root if root.is_class(target_class_name) else _find_first_node_by_class(root, target_class_name)
		if auto_target:
			return [auto_target, {}]
		return [null, {&"ok": false, &"error": "No %s found in scene" % target_class_name}]

	var target = _find_node(root, node_path)
	if not target:
		return [null, {&"ok": false, &"error": "Node not found: " + node_path}]
	if not target.is_class(target_class_name):
		return [null, {&"ok": false, &"error": "Node '%s' (%s) is not a %s" % [node_path, target.get_class(), target_class_name]}]
	return [target, {}]

func _node_path_from_root(root: Node, target: Node) -> String:
	if root == target:
		return "."
	var relative := str(root.get_path_to(target))
	return "." if relative.is_empty() else relative

func _parse_named_enum(value: Variant, mapping: Dictionary, field_name: String) -> Array:
	if typeof(value) == TYPE_INT:
		var numeric_value := int(value)
		if mapping.values().has(numeric_value):
			return [numeric_value, {}]
		return [null, {&"ok": false, &"error": "Invalid %s enum value: %s" % [field_name, str(value)]}]

	var key := str(value).to_lower()
	if mapping.has(key):
		return [mapping[key], {}]

	return [null, {&"ok": false, &"error": "Invalid %s. Supported values: %s" % [field_name, ", ".join(mapping.keys())]}]

func _enum_name(value: int, mapping: Dictionary) -> String:
	for key in mapping:
		if mapping[key] == value:
			return str(key)
	return ""

func _rotation_degrees_from_radians(rotation_radians: Vector3) -> Vector3:
	return Vector3(
		rad_to_deg(rotation_radians.x),
		rad_to_deg(rotation_radians.y),
		rad_to_deg(rotation_radians.z)
	)

func _basis_to_rotation_radians(basis: Basis) -> Vector3:
	return basis.orthonormalized().get_euler(_EULER_ORDER)

func _collect_node_script_hints(root: Node, node: Node) -> Array:
	var hints: Array = []
	var current: Node = node

	while current:
		var script = current.get_script()
		if script:
			var script_path := str(script.resource_path)
			var source_text := ""
			if not script_path.is_empty() and FileAccess.file_exists(script_path):
				var file := FileAccess.open(script_path, FileAccess.READ)
				if file:
					source_text = file.get_as_text()

			var keyword_hits: Array = []
			if not source_text.is_empty():
				for keyword in _SCRIPT_OVERRIDE_KEYWORDS:
					if source_text.find(keyword) != -1:
						keyword_hits.append(keyword)

			hints.append({
				&"node_path": _node_path_from_root(root, current),
				&"node_name": current.name,
				&"script_path": script_path if not script_path.is_empty() else "(built-in script)",
				&"override_keywords": keyword_hits,
				&"affects_target_directly": current == node,
			})

		current = current.get_parent()

	return hints

func _get_light_emitted_direction(light: Light3D) -> Variant:
	if light is OmniLight3D:
		return null
	var global_transform := _get_node3d_global_transform(light)
	return (-global_transform.basis.orthonormalized().z).normalized()

func _direction_to_sun_angles(emitted_direction: Vector3) -> Dictionary:
	var normalized_direction := emitted_direction.normalized()
	var sun_vector := -normalized_direction
	return {
		&"sun_azimuth_degrees": rad_to_deg(atan2(sun_vector.x, -sun_vector.z)),
		&"sun_elevation_degrees": rad_to_deg(asin(clampf(sun_vector.y, -1.0, 1.0))),
	}

func _sun_vector_from_angles(elevation_degrees: float, azimuth_degrees: float) -> Vector3:
	var elevation_radians := deg_to_rad(elevation_degrees)
	var azimuth_radians := deg_to_rad(azimuth_degrees)
	var horizontal := cos(elevation_radians)
	return Vector3(
		sin(azimuth_radians) * horizontal,
		sin(elevation_radians),
		-cos(azimuth_radians) * horizontal
	).normalized()

func _basis_from_emitted_direction(emitted_direction: Vector3) -> Basis:
	var normalized_direction := emitted_direction.normalized()
	if normalized_direction.length_squared() == 0.0:
		normalized_direction = Vector3.DOWN

	var z_axis := -normalized_direction
	var reference_up := Vector3.UP
	if absf(normalized_direction.dot(reference_up)) > 0.999:
		reference_up = Vector3.BACK

	var x_axis := reference_up.cross(z_axis).normalized()
	if x_axis.length_squared() == 0.0:
		x_axis = Vector3.RIGHT
	var y_axis := z_axis.cross(x_axis).normalized()
	return Basis(x_axis, y_axis, z_axis).orthonormalized()

func _collect_directional_lights(node: Node, out: Array) -> void:
	if node is DirectionalLight3D:
		out.append(node)
	for child: Node in node.get_children():
		_collect_directional_lights(child, out)

func _build_directional_order_info(root: Node, target: DirectionalLight3D) -> Dictionary:
	var directional_lights: Array = []
	_collect_directional_lights(root, directional_lights)

	var first_path := ""
	var target_index := -1
	for i: int in range(directional_lights.size()):
		var light: DirectionalLight3D = directional_lights[i]
		if i == 0:
			first_path = _node_path_from_root(root, light)
		if light == target:
			target_index = i

	return {
		&"directional_light_count": directional_lights.size(),
		&"directional_light_index": target_index,
		&"is_first_directional_light": target_index == 0,
		&"first_directional_light_path": first_path,
	}

func _build_directional_warnings(order_info: Dictionary, emitted_direction: Vector3, light: DirectionalLight3D) -> Array:
	var warnings: Array = []
	if emitted_direction.y >= 0.0:
		warnings.append("Directional light is not pointing downward. This usually causes lighting and shadows to look like they are coming from below the ground.")
	if light.sky_mode == DirectionalLight3D.SKY_MODE_SKY_ONLY:
		warnings.append("This light is SKY_MODE_SKY_ONLY, so it will not illuminate scene geometry.")
	if not bool(order_info.get(&"is_first_directional_light", false)):
		warnings.append("This is not the first DirectionalLight3D in scene-tree order. PhysicalSkyMaterial uses the first directional light as the sun source.")
	return warnings

func _append_directional_rotation_warnings(warnings: Array, local_rotation_degrees: Vector3, global_rotation_degrees: Vector3) -> void:
	if global_rotation_degrees.x > 0.0:
		warnings.append("Global rotation.x is positive in Godot's default YXZ Euler order, which usually means the directional light is pitched upward.")
	if local_rotation_degrees.x > 0.0:
		warnings.append("Local rotation.x is positive in Godot's default YXZ Euler order. If no parent transform is compensating, the light will point upward.")

func _apply_common_light_settings(light: Light3D, args: Dictionary) -> Dictionary:
	if args.has(&"color"):
		var parsed_color = _parse_typed_value(args[&"color"], TYPE_COLOR)
		if not (parsed_color is Color):
			return {&"ok": false, &"error": "'color' must be a Color-compatible value"}
		light.light_color = parsed_color

	if args.has(&"energy"):
		light.light_energy = float(args[&"energy"])
	if args.has(&"indirect_energy"):
		light.light_indirect_energy = float(args[&"indirect_energy"])
	if args.has(&"volumetric_fog_energy"):
		light.light_volumetric_fog_energy = float(args[&"volumetric_fog_energy"])
	if args.has(&"specular"):
		light.light_specular = float(args[&"specular"])
	if args.has(&"temperature_kelvin"):
		light.light_temperature = float(args[&"temperature_kelvin"])
	if args.has(&"angular_distance"):
		light.light_angular_distance = float(args[&"angular_distance"])
	if args.has(&"shadow_enabled"):
		light.shadow_enabled = bool(args[&"shadow_enabled"])
	if args.has(&"shadow_bias"):
		light.shadow_bias = float(args[&"shadow_bias"])
	if args.has(&"shadow_normal_bias"):
		light.shadow_normal_bias = float(args[&"shadow_normal_bias"])
	if args.has(&"shadow_blur"):
		light.shadow_blur = float(args[&"shadow_blur"])
	if args.has(&"light_cull_mask"):
		light.light_cull_mask = int(args[&"light_cull_mask"])
	if args.has(&"shadow_caster_mask"):
		light.shadow_caster_mask = int(args[&"shadow_caster_mask"])
	if args.has(&"editor_only"):
		light.editor_only = bool(args[&"editor_only"])
	if args.has(&"visible"):
		light.visible = bool(args[&"visible"])

	return {}

func _apply_directional_light_settings(light: DirectionalLight3D, args: Dictionary) -> Dictionary:
	if args.has(&"sky_mode"):
		var parsed_sky_mode = _parse_named_enum(args[&"sky_mode"], _DIRECTIONAL_SKY_MODES, "sky_mode")
		if not parsed_sky_mode[1].is_empty():
			return parsed_sky_mode[1]
		light.sky_mode = int(parsed_sky_mode[0])

	if args.has(&"directional_shadow_mode"):
		var parsed_shadow_mode = _parse_named_enum(args[&"directional_shadow_mode"], _DIRECTIONAL_SHADOW_MODES, "directional_shadow_mode")
		if not parsed_shadow_mode[1].is_empty():
			return parsed_shadow_mode[1]
		light.directional_shadow_mode = int(parsed_shadow_mode[0])

	if args.has(&"directional_shadow_max_distance"):
		light.directional_shadow_max_distance = float(args[&"directional_shadow_max_distance"])
	if args.has(&"directional_shadow_blend_splits"):
		light.directional_shadow_blend_splits = bool(args[&"directional_shadow_blend_splits"])
	if args.has(&"directional_shadow_fade_start"):
		light.directional_shadow_fade_start = float(args[&"directional_shadow_fade_start"])
	if args.has(&"directional_shadow_split_1"):
		light.directional_shadow_split_1 = float(args[&"directional_shadow_split_1"])
	if args.has(&"directional_shadow_split_2"):
		light.directional_shadow_split_2 = float(args[&"directional_shadow_split_2"])
	if args.has(&"directional_shadow_split_3"):
		light.directional_shadow_split_3 = float(args[&"directional_shadow_split_3"])
	if args.has(&"directional_shadow_pancake_size"):
		light.directional_shadow_pancake_size = float(args[&"directional_shadow_pancake_size"])

	return {}

func _has_explicit_light_setting_changes(args: Dictionary) -> bool:
	for key in _LIGHT_SETTING_KEYS:
		if args.has(StringName(key)):
			return true
		if args.has(key):
			return true
	return false

func _build_common_light_info(light: Light3D) -> Dictionary:
	var local_transform := light.transform
	var global_transform := _get_node3d_global_transform(light)
	var local_rotation_radians := _basis_to_rotation_radians(local_transform.basis)
	var global_rotation_radians := _basis_to_rotation_radians(global_transform.basis)
	return {
		&"node_name": light.name,
		&"node_type": light.get_class(),
		&"visible": light.visible,
		&"editor_only": light.editor_only,
		&"light_color": _serialize_value(light.light_color),
		&"light_energy": light.light_energy,
		&"light_indirect_energy": light.light_indirect_energy,
		&"light_volumetric_fog_energy": light.light_volumetric_fog_energy,
		&"light_specular": light.light_specular,
		&"light_temperature": light.light_temperature,
		&"light_angular_distance": light.light_angular_distance,
		&"light_cull_mask": light.light_cull_mask,
		&"shadow_enabled": light.shadow_enabled,
		&"shadow_bias": light.shadow_bias,
		&"shadow_normal_bias": light.shadow_normal_bias,
		&"shadow_blur": light.shadow_blur,
		&"shadow_caster_mask": light.shadow_caster_mask,
		&"local_transform": _serialize_value(local_transform),
		&"global_transform": _serialize_value(global_transform),
		&"local_position": _serialize_value(local_transform.origin),
		&"global_position": _serialize_value(global_transform.origin),
		&"rotation_order": _EULER_ORDER_NAME,
		&"local_rotation_radians": _serialize_value(local_rotation_radians),
		&"global_rotation_radians": _serialize_value(global_rotation_radians),
		&"local_rotation_degrees": _serialize_value(_rotation_degrees_from_radians(local_rotation_radians)),
		&"global_rotation_degrees": _serialize_value(_rotation_degrees_from_radians(global_rotation_radians)),
	}

func _build_light_info(root: Node, light: Light3D, scene_path: String, inspection_source: String) -> Dictionary:
	var info := _build_common_light_info(light)
	var resolved_path := _node_path_from_root(root, light)
	var local_rotation_degrees_raw := _rotation_degrees_from_radians(_basis_to_rotation_radians(light.transform.basis))
	var global_rotation_degrees_raw := _rotation_degrees_from_radians(_basis_to_rotation_radians(_get_node3d_global_transform(light).basis))
	info[&"scene_path"] = scene_path
	info[&"node_path"] = resolved_path
	info[&"inspection_source"] = inspection_source

	if inspection_source == "editor_live":
		info[&"runtime_scope"] = "editor_live_scene"
		var editor_plugin := _context.get_editor_plugin()
		if editor_plugin:
			info[&"play_session_active"] = editor_plugin.get_editor_interface().is_playing_scene()
	else:
		info[&"runtime_scope"] = "scene_file"

	var script_hints := _collect_node_script_hints(root, light)
	info[&"script_hints"] = script_hints

	var warnings: Array = []
	if not script_hints.is_empty():
		warnings.append("This light or one of its ancestors has an attached script. Scripts can override transform or light settings at runtime.")
		for hint in script_hints:
			var keywords: Array = hint.get(&"override_keywords", [])
			if not keywords.is_empty():
				warnings.append("Script %s references likely transform/light override keywords: %s" % [hint.get(&"script_path", ""), ", ".join(keywords)])

	var emitted_direction = _get_light_emitted_direction(light)
	if emitted_direction is Vector3:
		info[&"emitted_direction"] = _serialize_value(emitted_direction)

	if light is DirectionalLight3D:
		var directional_light: DirectionalLight3D = light
		var order_info := _build_directional_order_info(root, directional_light)
		for key in order_info:
			info[key] = order_info[key]
		info[&"sky_mode"] = directional_light.sky_mode
		info[&"sky_mode_name"] = _enum_name(directional_light.sky_mode, _DIRECTIONAL_SKY_MODES)
		info[&"directional_shadow_mode"] = directional_light.directional_shadow_mode
		info[&"directional_shadow_mode_name"] = _enum_name(directional_light.directional_shadow_mode, _DIRECTIONAL_SHADOW_MODES)
		info[&"directional_shadow_max_distance"] = directional_light.directional_shadow_max_distance
		info[&"directional_shadow_blend_splits"] = directional_light.directional_shadow_blend_splits
		info[&"directional_shadow_fade_start"] = directional_light.directional_shadow_fade_start
		info[&"directional_shadow_split_1"] = directional_light.directional_shadow_split_1
		info[&"directional_shadow_split_2"] = directional_light.directional_shadow_split_2
		info[&"directional_shadow_split_3"] = directional_light.directional_shadow_split_3
		info[&"directional_shadow_pancake_size"] = directional_light.directional_shadow_pancake_size
		if emitted_direction is Vector3:
			var sun_angles := _direction_to_sun_angles(emitted_direction)
			for key in sun_angles:
				info[key] = sun_angles[key]
			warnings.append_array(_build_directional_warnings(order_info, emitted_direction, directional_light))
			_append_directional_rotation_warnings(warnings, local_rotation_degrees_raw, global_rotation_degrees_raw)

		if directional_light.light_energy <= 0.001:
			warnings.append("Directional light energy is zero or near zero, so it will not visibly illuminate the scene.")
		if not directional_light.shadow_enabled:
			warnings.append("Directional light shadows are disabled.")

	info[&"warnings"] = warnings
	return info

func get_light_info(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", ""))
	var runtime := bool(args.get(&"runtime", false))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var inspection_result := _load_inspection_root(scene_path, runtime)
	if not inspection_result[1].is_empty():
		return inspection_result[1]

	var root: Node = inspection_result[0]
	var inspection_source: String = inspection_result[2]
	var should_free: bool = inspection_result[3]
	var target_result := _resolve_light_target(root, node_path, "Light3D")
	if not target_result[1].is_empty():
		_release_scene_root(root, should_free)
		return target_result[1]

	var light: Light3D = target_result[0]
	var info := _build_light_info(root, light, scene_path, inspection_source)
	_release_scene_root(root, should_free)
	info[&"ok"] = true
	return info

func set_sun_light(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", ""))
	var allow_below_horizon := bool(args.get(&"allow_below_horizon", false))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target_result := _resolve_light_target(root, node_path, "DirectionalLight3D")
	if not target_result[1].is_empty():
		root.queue_free()
		return target_result[1]

	var light: DirectionalLight3D = target_result[0]
	var resolved_path := _node_path_from_root(root, light)
	var old_emitted_direction = _get_light_emitted_direction(light)
	var existing_sun_angles := {&"sun_elevation_degrees": 45.0, &"sun_azimuth_degrees": 0.0}
	if old_emitted_direction is Vector3:
		existing_sun_angles = _direction_to_sun_angles(old_emitted_direction)

	var elevation_degrees := float(args.get(&"elevation_degrees", existing_sun_angles[&"sun_elevation_degrees"]))
	var azimuth_degrees := float(args.get(&"azimuth_degrees", existing_sun_angles[&"sun_azimuth_degrees"]))

	if elevation_degrees < 0.0 and not allow_below_horizon:
		root.queue_free()
		return {&"ok": false, &"error": "Sun elevation is below the horizon. Pass allow_below_horizon = true if this is intentional."}

	if not args.has(&"elevation_degrees") and not args.has(&"azimuth_degrees") and not _has_explicit_light_setting_changes(args):
		root.queue_free()
		return {&"ok": false, &"error": "No sun angle or light setting changes were provided"}

	var sun_vector := _sun_vector_from_angles(elevation_degrees, azimuth_degrees)
	var emitted_direction: Vector3 = -sun_vector
	var desired_global_transform := _get_node3d_global_transform(light)
	var desired_basis := _basis_from_emitted_direction(emitted_direction)
	var current_scale := desired_global_transform.basis.get_scale()
	desired_global_transform.basis = desired_basis.scaled(current_scale)
	_set_node3d_global_transform(light, desired_global_transform)

	var common_error := _apply_common_light_settings(light, args)
	if not common_error.is_empty():
		root.queue_free()
		return common_error

	var directional_error := _apply_directional_light_settings(light, args)
	if not directional_error.is_empty():
		root.queue_free()
		return directional_error

	var resulting_global_transform := _get_node3d_global_transform(light)
	var resulting_global_rotation_radians := _basis_to_rotation_radians(resulting_global_transform.basis)
	var resulting_global_rotation_degrees := _rotation_degrees_from_radians(resulting_global_rotation_radians)
	var resulting_emitted_direction = _get_light_emitted_direction(light)
	var warnings: Array = []
	if resulting_emitted_direction is Vector3 and resulting_emitted_direction.y >= 0.0:
		warnings.append("Applied sun still points upward after configuration. Check parent transforms and inherited rotations.")
	if resulting_global_rotation_degrees.x > 0.0:
		warnings.append("Applied global rotation.x is positive in YXZ order after configuration.")

	var save_error := _save_scene(root, scene_path)
	if not save_error.is_empty():
		return save_error

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": resolved_path,
		&"old_emitted_direction": _serialize_value(old_emitted_direction),
		&"new_emitted_direction": _serialize_value(emitted_direction),
		&"global_rotation_radians": _serialize_value(resulting_global_rotation_radians),
		&"global_rotation_degrees": _serialize_value(resulting_global_rotation_degrees),
		&"warnings": warnings,
		&"sun_elevation_degrees": elevation_degrees,
		&"sun_azimuth_degrees": azimuth_degrees,
		&"message": "Configured directional sun light orientation and settings",
	}

func validate_scene_lighting(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var runtime := bool(args.get(&"runtime", false))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var inspection_result := _load_inspection_root(scene_path, runtime)
	if not inspection_result[1].is_empty():
		return inspection_result[1]

	var root: Node = inspection_result[0]
	var inspection_source: String = inspection_result[2]
	var should_free: bool = inspection_result[3]

	var directional_lights: Array = []
	_collect_directional_lights(root, directional_lights)

	var lights: Array = []
	var summary_warnings: Array = []
	var enabled_directional_vectors: Array = []
	var issue_count := 0

	for light_node in directional_lights:
		var light: DirectionalLight3D = light_node
		var info := _build_light_info(root, light, scene_path, inspection_source)
		lights.append(info)
		issue_count += int(info.get(&"warnings", []).size())

		if light.visible and light.light_energy > 0.001:
			var emitted_direction = _get_light_emitted_direction(light)
			if emitted_direction is Vector3:
				enabled_directional_vectors.append({
					&"node_path": info.get(&"node_path", ""),
					&"direction": emitted_direction,
				})

	if lights.is_empty():
		summary_warnings.append("No DirectionalLight3D nodes were found in the scene.")

	if enabled_directional_vectors.size() > 1:
		for i: int in range(enabled_directional_vectors.size()):
			for j: int in range(i + 1, enabled_directional_vectors.size()):
				var a: Dictionary = enabled_directional_vectors[i]
				var b: Dictionary = enabled_directional_vectors[j]
				var a_dir: Vector3 = a[&"direction"]
				var b_dir: Vector3 = b[&"direction"]
				if a_dir.dot(b_dir) < 0.95:
					summary_warnings.append(
						"Directional lights %s and %s point in noticeably different directions. This can create conflicting sun/shadow cues."
						% [a.get(&"node_path", ""), b.get(&"node_path", "")]
					)

	if directional_lights.size() > 1:
		summary_warnings.append("Multiple DirectionalLight3D nodes are present. PhysicalSkyMaterial uses only the first directional light as the sun source.")

	_release_scene_root(root, should_free)

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"inspection_source": inspection_source,
		&"runtime_scope": "editor_live_scene" if inspection_source == "editor_live" else "scene_file",
		&"directional_light_count": directional_lights.size(),
		&"lights": lights,
		&"summary_warnings": summary_warnings,
		&"issue_count": issue_count + summary_warnings.size(),
		&"message": "Validated lighting diagnostics for %d directional light(s)" % directional_lights.size(),
	}
