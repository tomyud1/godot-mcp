@tool
extends RefCounted
class_name VariantCodec
## Shared serialization/parsing helpers for MCP tool arguments and results.

static func type_id_to_name(type_id: int, object_label: String = "Object") -> String:
	match type_id:
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "bool"
		TYPE_INT:
			return "int"
		TYPE_FLOAT:
			return "float"
		TYPE_STRING:
			return "String"
		TYPE_VECTOR2:
			return "Vector2"
		TYPE_VECTOR2I:
			return "Vector2i"
		TYPE_RECT2:
			return "Rect2"
		TYPE_RECT2I:
			return "Rect2i"
		TYPE_VECTOR3:
			return "Vector3"
		TYPE_VECTOR3I:
			return "Vector3i"
		TYPE_TRANSFORM2D:
			return "Transform2D"
		TYPE_VECTOR4:
			return "Vector4"
		TYPE_VECTOR4I:
			return "Vector4i"
		TYPE_PLANE:
			return "Plane"
		TYPE_QUATERNION:
			return "Quaternion"
		TYPE_AABB:
			return "AABB"
		TYPE_BASIS:
			return "Basis"
		TYPE_TRANSFORM3D:
			return "Transform3D"
		TYPE_PROJECTION:
			return "Projection"
		TYPE_COLOR:
			return "Color"
		TYPE_STRING_NAME:
			return "StringName"
		TYPE_NODE_PATH:
			return "NodePath"
		TYPE_RID:
			return "RID"
		TYPE_OBJECT:
			return object_label
		TYPE_CALLABLE:
			return "Callable"
		TYPE_SIGNAL:
			return "Signal"
		TYPE_DICTIONARY:
			return "Dictionary"
		TYPE_ARRAY:
			return "Array"
		TYPE_PACKED_BYTE_ARRAY:
			return "PackedByteArray"
		TYPE_PACKED_INT32_ARRAY:
			return "PackedInt32Array"
		TYPE_PACKED_INT64_ARRAY:
			return "PackedInt64Array"
		TYPE_PACKED_FLOAT32_ARRAY:
			return "PackedFloat32Array"
		TYPE_PACKED_FLOAT64_ARRAY:
			return "PackedFloat64Array"
		TYPE_PACKED_STRING_ARRAY:
			return "PackedStringArray"
		TYPE_PACKED_VECTOR2_ARRAY:
			return "PackedVector2Array"
		TYPE_PACKED_VECTOR3_ARRAY:
			return "PackedVector3Array"
		TYPE_PACKED_COLOR_ARRAY:
			return "PackedColorArray"
		_:
			return "Variant"

static func type_name_to_id(type_name: String) -> int:
	match type_name:
		"bool", "Bool":
			return TYPE_BOOL
		"int", "Int":
			return TYPE_INT
		"float", "Float":
			return TYPE_FLOAT
		"String", "string":
			return TYPE_STRING
		"StringName":
			return TYPE_STRING_NAME
		"NodePath":
			return TYPE_NODE_PATH
		"Vector2":
			return TYPE_VECTOR2
		"Vector2i":
			return TYPE_VECTOR2I
		"Vector3":
			return TYPE_VECTOR3
		"Vector3i":
			return TYPE_VECTOR3I
		"Color":
			return TYPE_COLOR
		"Quaternion":
			return TYPE_QUATERNION
		"Basis":
			return TYPE_BASIS
		"Transform3D":
			return TYPE_TRANSFORM3D
		"AABB":
			return TYPE_AABB
		"Array":
			return TYPE_ARRAY
		"Resource", "Object":
			return TYPE_OBJECT
		_:
			return TYPE_NIL

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

static func parse_typed_value(value: Variant, type_hint: int, property_metadata: Dictionary = {}) -> Variant:
	if value == null:
		return null

	if type_hint == -1:
		return parse_value(value)

	match type_hint:
		TYPE_OBJECT:
			return _parse_object_typed_value(value)
		TYPE_ARRAY:
			return _parse_array_typed_value(value)
		TYPE_STRING_NAME:
			return StringName(str(value))
		TYPE_NODE_PATH:
			return NodePath(str(value))
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			return _parse_packed_array_typed_value(value, type_hint)

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
		TYPE_PACKED_BYTE_ARRAY:
			return {&"type": &"PackedByteArray", &"values": Array(value)}
		TYPE_PACKED_INT32_ARRAY:
			return {&"type": &"PackedInt32Array", &"values": Array(value)}
		TYPE_PACKED_INT64_ARRAY:
			return {&"type": &"PackedInt64Array", &"values": Array(value)}
		TYPE_PACKED_FLOAT32_ARRAY:
			return {&"type": &"PackedFloat32Array", &"values": Array(value)}
		TYPE_PACKED_FLOAT64_ARRAY:
			return {&"type": &"PackedFloat64Array", &"values": Array(value)}
		TYPE_PACKED_STRING_ARRAY:
			return {&"type": &"PackedStringArray", &"values": Array(value)}
		TYPE_PACKED_VECTOR2_ARRAY:
			return {&"type": &"PackedVector2Array", &"values": serialize_value(Array(value))}
		TYPE_PACKED_VECTOR3_ARRAY:
			return {&"type": &"PackedVector3Array", &"values": serialize_value(Array(value))}
		TYPE_PACKED_COLOR_ARRAY:
			return {&"type": &"PackedColorArray", &"values": serialize_value(Array(value))}
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
		"Resource":
			return _parse_resource_dictionary(dict)
		"Array":
			return _parse_array_dictionary(dict)
		"PackedByteArray":
			return _parse_packed_array_dictionary(dict, TYPE_PACKED_BYTE_ARRAY)
		"PackedInt32Array":
			return _parse_packed_array_dictionary(dict, TYPE_PACKED_INT32_ARRAY)
		"PackedInt64Array":
			return _parse_packed_array_dictionary(dict, TYPE_PACKED_INT64_ARRAY)
		"PackedFloat32Array":
			return _parse_packed_array_dictionary(dict, TYPE_PACKED_FLOAT32_ARRAY)
		"PackedFloat64Array":
			return _parse_packed_array_dictionary(dict, TYPE_PACKED_FLOAT64_ARRAY)
		"PackedStringArray":
			return _parse_packed_array_dictionary(dict, TYPE_PACKED_STRING_ARRAY)
		"PackedVector2Array":
			return _parse_packed_array_dictionary(dict, TYPE_PACKED_VECTOR2_ARRAY)
		"PackedVector3Array":
			return _parse_packed_array_dictionary(dict, TYPE_PACKED_VECTOR3_ARRAY)
		"PackedColorArray":
			return _parse_packed_array_dictionary(dict, TYPE_PACKED_COLOR_ARRAY)
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

static func _parse_object_typed_value(value: Variant) -> Variant:
	if value == null:
		return null

	if value is Resource:
		return value

	if value is String:
		return _load_resource_from_path(str(value))

	var parsed = parse_value(value)
	if parsed is Resource or parsed == null:
		return parsed

	return parsed

static func _parse_array_typed_value(value: Variant) -> Variant:
	if value is Dictionary and str((value as Dictionary).get(&"type", "")) == "Array":
		return parse_value(value)

	if value is Array:
		var parsed: Array = []
		for item in value:
			parsed.append(parse_value(item))
		return parsed

	return parse_value(value)

static func _parse_array_dictionary(dict: Dictionary) -> Array:
	var raw_values = dict.get(&"values", dict.get(&"items", []))
	var base: Array = []

	if raw_values is Array:
		for item in raw_values:
			base.append(parse_value(item))

	var typed_builtin = int(dict.get(&"typed_builtin", TYPE_NIL))
	if typed_builtin == TYPE_NIL and dict.has(&"element_type"):
		typed_builtin = type_name_to_id(str(dict.get(&"element_type", "")))

	if typed_builtin == TYPE_NIL:
		return base

	var typed_class_name := StringName(str(dict.get(&"typed_class_name", dict.get(&"class_name", ""))))
	var typed_script: Variant = null
	var typed_script_path := str(dict.get(&"typed_script_path", dict.get(&"script_path", "")))
	if not typed_script_path.is_empty():
		typed_script = _load_resource_from_path(typed_script_path)

	if typed_builtin != TYPE_OBJECT:
		return Array(base, typed_builtin, StringName(), null)

	return Array(base, typed_builtin, typed_class_name, typed_script)

static func _parse_resource_dictionary(dict: Dictionary) -> Variant:
	var raw_path := str(dict.get(&"path", dict.get(&"resource_path", "")))
	if raw_path.strip_edges().is_empty():
		return null
	return _load_resource_from_path(raw_path)

static func _load_resource_from_path(raw_path: String) -> Variant:
	var path := raw_path.strip_edges()
	if path.is_empty():
		return null
	if not path.begins_with("res://") and not path.begins_with("user://"):
		path = "res://" + path
	var loaded = load(path)
	return loaded if loaded is Resource else null

static func _parse_packed_array_typed_value(value: Variant, type_hint: int) -> Variant:
	if value is Dictionary and not str((value as Dictionary).get(&"type", "")).is_empty():
		return parse_value(value)
	if not (value is Array):
		return value

	match type_hint:
		TYPE_PACKED_BYTE_ARRAY:
			return PackedByteArray(value)
		TYPE_PACKED_INT32_ARRAY:
			return PackedInt32Array(value)
		TYPE_PACKED_INT64_ARRAY:
			return PackedInt64Array(value)
		TYPE_PACKED_FLOAT32_ARRAY:
			return PackedFloat32Array(value)
		TYPE_PACKED_FLOAT64_ARRAY:
			return PackedFloat64Array(value)
		TYPE_PACKED_STRING_ARRAY:
			return PackedStringArray(value)
		TYPE_PACKED_VECTOR2_ARRAY:
			return PackedVector2Array(value)
		TYPE_PACKED_VECTOR3_ARRAY:
			return PackedVector3Array(value)
		TYPE_PACKED_COLOR_ARRAY:
			return PackedColorArray(value)
		_:
			return value

static func _parse_packed_array_dictionary(dict: Dictionary, type_hint: int) -> Variant:
	var raw_values = dict.get(&"values", dict.get(&"items", []))
	return _parse_packed_array_typed_value(raw_values, type_hint)
