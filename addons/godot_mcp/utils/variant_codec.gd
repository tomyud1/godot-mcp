@tool
extends RefCounted
class_name VariantCodec
## Shared serialization/parsing helpers for MCP tool arguments and results.

static func parse_value(value: Variant) -> Variant:
	if value is Dictionary:
		var dict: Dictionary = value
		var explicit_type: String = str(dict.get(&"type", ""))
		if not explicit_type.is_empty():
			return _parse_explicit_dictionary(explicit_type, dict)
		return _parse_inferred_dictionary(dict)

	if value is Array:
		var parsed: Array = []
		for item in value:
			parsed.append(parse_value(item))
		return parsed

	return value

static func parse_typed_value(value: Variant, type_hint: int) -> Variant:
	if type_hint == -1:
		return parse_value(value)

	if value is Dictionary:
		var dict: Dictionary = value
		if not str(dict.get(&"type", "")).is_empty():
			return parse_value(dict)

		match type_hint:
			TYPE_VECTOR2:
				return Vector2(float(dict.get(&"x", 0)), float(dict.get(&"y", 0)))
			TYPE_VECTOR2I:
				return Vector2i(int(dict.get(&"x", 0)), int(dict.get(&"y", 0)))
			TYPE_VECTOR3:
				return Vector3(float(dict.get(&"x", 0)), float(dict.get(&"y", 0)), float(dict.get(&"z", 0)))
			TYPE_VECTOR3I:
				return Vector3i(int(dict.get(&"x", 0)), int(dict.get(&"y", 0)), int(dict.get(&"z", 0)))
			TYPE_COLOR:
				return Color(float(dict.get(&"r", 1)), float(dict.get(&"g", 1)), float(dict.get(&"b", 1)), float(dict.get(&"a", 1)))
			TYPE_RECT2:
				return Rect2(
					float(dict.get(&"x", 0)),
					float(dict.get(&"y", 0)),
					float(dict.get(&"width", 0)),
					float(dict.get(&"height", 0))
				)
			TYPE_QUATERNION:
				return _parse_quaternion_dictionary(dict)
			TYPE_BASIS:
				return _parse_basis_dictionary(dict)
			TYPE_TRANSFORM3D:
				return _parse_transform3d_dictionary(dict)
			TYPE_AABB:
				return _parse_aabb_dictionary(dict)

	return parse_value(value)

static func serialize_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2:
			return {&"type": &"Vector2", &"x": value.x, &"y": value.y}
		TYPE_VECTOR3:
			return {&"type": &"Vector3", &"x": value.x, &"y": value.y, &"z": value.z}
		TYPE_COLOR:
			return {&"type": &"Color", &"r": value.r, &"g": value.g, &"b": value.b, &"a": value.a}
		TYPE_VECTOR2I:
			return {&"type": &"Vector2i", &"x": value.x, &"y": value.y}
		TYPE_VECTOR3I:
			return {&"type": &"Vector3i", &"x": value.x, &"y": value.y, &"z": value.z}
		TYPE_RECT2:
			return {
				&"type": &"Rect2",
				&"x": value.position.x,
				&"y": value.position.y,
				&"width": value.size.x,
				&"height": value.size.y
			}
		TYPE_QUATERNION:
			return {&"type": &"Quaternion", &"x": value.x, &"y": value.y, &"z": value.z, &"w": value.w}
		TYPE_BASIS:
			return {
				&"type": &"Basis",
				&"x": serialize_value(value.x),
				&"y": serialize_value(value.y),
				&"z": serialize_value(value.z)
			}
		TYPE_TRANSFORM3D:
			return {
				&"type": &"Transform3D",
				&"basis": serialize_value(value.basis),
				&"origin": serialize_value(value.origin)
			}
		TYPE_AABB:
			return {
				&"type": &"AABB",
				&"position": serialize_value(value.position),
				&"size": serialize_value(value.size)
			}
		TYPE_ARRAY:
			var out: Array = []
			for item in value:
				out.append(serialize_value(item))
			return out
		TYPE_DICTIONARY:
			var out: Dictionary = {}
			for key in value:
				out[key] = serialize_value(value[key])
			return out
		TYPE_OBJECT:
			if value and value is Resource and value.resource_path:
				return {&"type": &"Resource", &"path": value.resource_path}
			return null
		_:
			return value

static func _parse_explicit_dictionary(type_name: String, dict: Dictionary) -> Variant:
	match type_name:
		"Vector2":
			return Vector2(float(dict.get(&"x", 0)), float(dict.get(&"y", 0)))
		"Vector3":
			return Vector3(float(dict.get(&"x", 0)), float(dict.get(&"y", 0)), float(dict.get(&"z", 0)))
		"Color":
			return Color(float(dict.get(&"r", 1)), float(dict.get(&"g", 1)), float(dict.get(&"b", 1)), float(dict.get(&"a", 1)))
		"Vector2i":
			return Vector2i(int(dict.get(&"x", 0)), int(dict.get(&"y", 0)))
		"Vector3i":
			return Vector3i(int(dict.get(&"x", 0)), int(dict.get(&"y", 0)), int(dict.get(&"z", 0)))
		"Rect2":
			return Rect2(
				float(dict.get(&"x", 0)),
				float(dict.get(&"y", 0)),
				float(dict.get(&"width", 0)),
				float(dict.get(&"height", 0))
			)
		"Quaternion":
			return _parse_quaternion_dictionary(dict)
		"Basis":
			return _parse_basis_dictionary(dict)
		"Transform3D":
			return _parse_transform3d_dictionary(dict)
		"AABB":
			return _parse_aabb_dictionary(dict)
		_:
			return dict

static func _parse_inferred_dictionary(dict: Dictionary) -> Variant:
	if dict.has(&"basis") and dict.has(&"origin"):
		return _parse_transform3d_dictionary(dict)

	if dict.has(&"position") and dict.has(&"size"):
		var position = parse_value(dict[&"position"])
		var size = parse_value(dict[&"size"])
		if position is Vector3 and size is Vector3:
			return AABB(position, size)

	if dict.has(&"r") and dict.has(&"g") and dict.has(&"b"):
		return Color(float(dict.get(&"r", 1)), float(dict.get(&"g", 1)), float(dict.get(&"b", 1)), float(dict.get(&"a", 1)))

	if dict.has(&"x") and dict.has(&"y") and dict.has(&"z"):
		if dict.has(&"w"):
			return _parse_quaternion_dictionary(dict)

		var x_axis = parse_value(dict[&"x"])
		var y_axis = parse_value(dict[&"y"])
		var z_axis = parse_value(dict[&"z"])
		if x_axis is Vector3 and y_axis is Vector3 and z_axis is Vector3:
			return Basis(x_axis, y_axis, z_axis)

		return Vector3(float(dict.get(&"x", 0)), float(dict.get(&"y", 0)), float(dict.get(&"z", 0)))

	if dict.has(&"x") and dict.has(&"y"):
		return Vector2(float(dict.get(&"x", 0)), float(dict.get(&"y", 0)))

	return dict

static func _parse_quaternion_dictionary(dict: Dictionary) -> Quaternion:
	if dict.has(&"basis"):
		var basis = parse_value(dict[&"basis"])
		if basis is Basis:
			return Quaternion(basis)

	if dict.has(&"axis") and dict.has(&"angle"):
		var axis = parse_value(dict[&"axis"])
		if axis is Vector3 and axis.length_squared() > 0.0:
			return Quaternion(axis.normalized(), float(dict.get(&"angle", 0)))

	return Quaternion(
		float(dict.get(&"x", 0)),
		float(dict.get(&"y", 0)),
		float(dict.get(&"z", 0)),
		float(dict.get(&"w", 1))
	)

static func _parse_basis_dictionary(dict: Dictionary) -> Basis:
	if dict.has(&"x") and dict.has(&"y") and dict.has(&"z"):
		var x_axis = parse_value(dict[&"x"])
		var y_axis = parse_value(dict[&"y"])
		var z_axis = parse_value(dict[&"z"])
		if x_axis is Vector3 and y_axis is Vector3 and z_axis is Vector3:
			return Basis(x_axis, y_axis, z_axis)

	if dict.has(&"quaternion"):
		var quaternion = parse_value(dict[&"quaternion"])
		if quaternion is Quaternion:
			return Basis(quaternion)

	if dict.has(&"axis") and dict.has(&"angle"):
		var axis = parse_value(dict[&"axis"])
		if axis is Vector3 and axis.length_squared() > 0.0:
			return Basis(axis.normalized(), float(dict.get(&"angle", 0)))

	if dict.has(&"euler"):
		var euler = parse_value(dict[&"euler"])
		if euler is Vector3:
			if dict.has(&"order"):
				return Basis.from_euler(euler, int(dict.get(&"order", 0)))
			return Basis.from_euler(euler)

	if dict.has(&"scale"):
		var scale = parse_value(dict[&"scale"])
		if scale is Vector3:
			return Basis.from_scale(scale)

	return Basis()

static func _parse_transform3d_dictionary(dict: Dictionary) -> Transform3D:
	var basis := Basis()
	var origin := Vector3.ZERO

	if dict.has(&"basis"):
		var parsed_basis = parse_value(dict[&"basis"])
		if parsed_basis is Basis:
			basis = parsed_basis
	elif dict.has(&"x_axis") and dict.has(&"y_axis") and dict.has(&"z_axis"):
		var x_axis = parse_value(dict[&"x_axis"])
		var y_axis = parse_value(dict[&"y_axis"])
		var z_axis = parse_value(dict[&"z_axis"])
		if x_axis is Vector3 and y_axis is Vector3 and z_axis is Vector3:
			basis = Basis(x_axis, y_axis, z_axis)

	if dict.has(&"origin"):
		var parsed_origin = parse_value(dict[&"origin"])
		if parsed_origin is Vector3:
			origin = parsed_origin

	return Transform3D(basis, origin)

static func _parse_aabb_dictionary(dict: Dictionary) -> AABB:
	var position := Vector3.ZERO
	var size := Vector3.ZERO

	if dict.has(&"position"):
		var parsed_position = parse_value(dict[&"position"])
		if parsed_position is Vector3:
			position = parsed_position

	if dict.has(&"size"):
		var parsed_size = parse_value(dict[&"size"])
		if parsed_size is Vector3:
			size = parsed_size

	return AABB(position, size)
