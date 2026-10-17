@tool
extends RefCounted
## PropertyWriter — the single code path MCP tools use to write properties and
## to turn JSON values into typed Godot values.
##
## Why this exists: Object.set() silently ignores a value of the wrong type.
## Tools used to convert JSON to Variants independently, so a texture path or a
## mistyped value could report ok:true while nothing changed. Here the declared
## type of the property (or method argument) decides how a JSON value is read:
##   - a Texture2D property accepts "res://x.png", {type:"Resource", path} or an
##     inline resource such as {type:"GradientTexture2D", width:64}
##   - a String property keeps "res://..." as plain text
##   - anything that doesn't fit is an error, never a silent drop
## Every write is read back. A value Godot adjusted (clamped, wrapped) is
## reported; a write Godot ignored is an error.
##
## Usage: plan() validates and decodes without touching the target, apply()
## writes a plan, write() does both. Callers that save files (scene tools) run
## everything before saving, so a failure leaves nothing on disk.

const VariantCodec = preload("res://addons/godot_mcp/utils/variant_codec.gd")

const _HEADER_USAGE := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP

## Component keys for the struct-like built-in types, used for strict decoding.
const _COMPONENTS := {
	TYPE_VECTOR2: ["x", "y"],
	TYPE_VECTOR2I: ["x", "y"],
	TYPE_VECTOR3: ["x", "y", "z"],
	TYPE_VECTOR3I: ["x", "y", "z"],
	TYPE_VECTOR4: ["x", "y", "z", "w"],
	TYPE_VECTOR4I: ["x", "y", "z", "w"],
}

const _PACKED_ELEMENT := {
	TYPE_PACKED_BYTE_ARRAY: TYPE_INT,
	TYPE_PACKED_INT32_ARRAY: TYPE_INT,
	TYPE_PACKED_INT64_ARRAY: TYPE_INT,
	TYPE_PACKED_FLOAT32_ARRAY: TYPE_FLOAT,
	TYPE_PACKED_FLOAT64_ARRAY: TYPE_FLOAT,
	TYPE_PACKED_STRING_ARRAY: TYPE_STRING,
	TYPE_PACKED_VECTOR2_ARRAY: TYPE_VECTOR2,
	TYPE_PACKED_VECTOR3_ARRAY: TYPE_VECTOR3,
	TYPE_PACKED_VECTOR4_ARRAY: TYPE_VECTOR4,
	TYPE_PACKED_COLOR_ARRAY: TYPE_COLOR,
}


# =============================================================================
# Public API
# =============================================================================

## Validate and decode `props` ({name: json_value}) against `target` without
## changing it. Keys may be colon paths ("material:albedo_color") that walk
## into sub-resources. Returns {errors: Array[String], plan: Array}.
static func plan(target: Object, props: Dictionary, prefix: String = "properties") -> Dictionary:
	var errors: Array = []
	var entries: Array = []
	var maps: Dictionary = {}     # instance_id -> property map
	var pending: Dictionary = {}  # "instance_id/prop" -> value planned in this call

	# Plan plain keys before colon paths, so "material:albedo_color" can walk
	# into a "material" assigned in the same call regardless of key order.
	var keys: Array = props.keys()
	keys.sort_custom(func(a, b): return str(a).count(":") < str(b).count(":"))
	for key_v in keys:
		var key := str(key_v)
		var where := _join(prefix, key)
		var segments := key.split(":", false)
		if segments.is_empty():
			errors.append("%s: empty property name" % where)
			continue

		# Walk colon paths down to the object that owns the final property.
		var owner: Object = target
		var walk_ok := true
		for i in range(segments.size() - 1):
			var seg := segments[i]
			var seg_map := _property_map(owner, maps)
			if not seg_map.has(seg):
				errors.append("%s: '%s' is not a property of %s%s" % [where, seg, describe(owner), _suggestion(seg, seg_map.keys())])
				walk_ok = false
				break
			var pkey := "%d/%s" % [owner.get_instance_id(), seg]
			var sub: Variant = pending[pkey] if pending.has(pkey) else owner.get(seg)
			if not (sub is Resource):
				errors.append("%s: '%s' on %s holds %s, not a resource. Assign one first in the same call, e.g. {\"%s\": {\"type\": \"<ResourceClass>\"}}, or put the nested values inside that inline resource." % [where, seg, describe(owner), short_value(sub), seg])
				walk_ok = false
				break
			if is_external_resource(sub):
				errors.append("%s: '%s' is the shared resource file %s, used by reference; changing it here would not be saved. Either edit the file itself (set_node_properties with scene_path \"%s\"; affects everything using it) or give this node its own copy by assigning an inline resource, e.g. {\"%s\": {\"type\": \"%s\", ...}}." % [where, seg, (sub as Resource).resource_path, (sub as Resource).resource_path, seg, (sub as Resource).get_class()])
				walk_ok = false
				break
			owner = sub
		if not walk_ok:
			continue

		var prop := segments[segments.size() - 1]
		var pmap := _property_map(owner, maps)
		if not pmap.has(prop):
			errors.append("%s: '%s' is not a property of %s%s" % [where, prop, describe(owner), _suggestion(prop, pmap.keys())])
			continue
		if prop == "script":
			errors.append("%s: scripts are attached with attach_script (or the 'script' key of a node spec), not as a property" % where)
			continue
		var info: Dictionary = pmap[prop]
		var current: Variant = owner.get(prop)
		var dec := decode(props[key_v], info, current, where)
		if not dec.errors.is_empty():
			errors.append_array(dec.errors)
			continue
		pending["%d/%s" % [owner.get_instance_id(), prop]] = dec.value
		entries.append({
			"key": key,
			"where": where,
			"owner": owner,
			"prop": prop,
			"value": dec.value,
			"old": current,
			"depth": segments.size(),
			"order": int(info.get("_order", 0)),
		})

	# Apply in the owner's declared property order, not JSON key order. Godot
	# relies on it (Sprite2D.frame is checked against hframes/vframes, scenes
	# load properties in this order). Nested paths go after their parents.
	entries.sort_custom(func(a, b):
		if a.depth != b.depth:
			return a.depth < b.depth
		return a.order < b.order)
	return {"errors": errors, "plan": entries}


## Write a plan from plan(). Each value is read back:
##   - stored as requested             -> applied
##   - stored but changed by a setter  -> applied + listed in `adjusted`
##   - not stored at all               -> error
## Returns {errors, applied, adjusted}.
static func apply(entries: Array) -> Dictionary:
	var errors: Array = []
	var applied: Array = []
	var adjusted: Array = []
	for e: Dictionary in entries:
		var owner: Object = e.owner
		owner.set(e.prop, e.value)
		var stored: Variant = owner.get(e.prop)
		if typeof(e.value) == TYPE_OBJECT and e.value != null:
			if not is_same(stored, e.value):
				errors.append("%s: Godot did not accept the value (the property still holds %s)" % [e.where, short_value(stored)])
				continue
		elif not values_equal(stored, e.value):
			if values_equal(stored, e.old) and not values_equal(e.value, e.old):
				errors.append("%s: Godot ignored the write (the value is still %s). The property may be read-only or computed from other properties." % [e.where, short_value(stored)])
				continue
			adjusted.append({
				"property": e.key,
				"requested": VariantCodec.serialize_value(e.value),
				"stored": VariantCodec.serialize_value(stored),
			})
		applied.append({
			"property": e.key,
			"old": VariantCodec.serialize_value(e.old),
			"new": VariantCodec.serialize_value(stored),
		})
	return {"errors": errors, "applied": applied, "adjusted": adjusted}


## plan() + apply(). Returns {ok, errors, applied, adjusted}. Nothing is
## written when planning fails.
static func write(target: Object, props: Dictionary, prefix: String = "properties") -> Dictionary:
	var p := plan(target, props, prefix)
	if not p.errors.is_empty():
		return {"ok": false, "errors": p.errors, "applied": [], "adjusted": []}
	var r := apply(p.plan)
	r["ok"] = r.errors.is_empty()
	return r


## Decode `value` for a slot described by `info` (a property-list or
## method-argument dictionary: type, class_name, hint, hint_string).
## `current` is the slot's current value; typed arrays/dictionaries use it to
## learn their element types. Returns {value, errors}.
static func decode(value: Variant, info: Dictionary, current: Variant = null, where: String = "value") -> Dictionary:
	var t := int(info.get("type", TYPE_NIL))
	var hint := int(info.get("hint", PROPERTY_HINT_NONE))
	var hint_string := str(info.get("hint_string", ""))

	if value == null:
		if t == TYPE_OBJECT or t == TYPE_NIL:
			return _ok(null)
		return _fail(where, "expects %s, got null" % type_label(info))

	match t:
		TYPE_NIL:
			return decode_variant(value, where)
		TYPE_BOOL:
			if value is bool:
				return _ok(value)
			if _is_number(value) and (float(value) == 0.0 or float(value) == 1.0):
				return _ok(float(value) == 1.0)
			if value is String and (value as String).to_lower() in ["true", "false"]:
				return _ok((value as String).to_lower() == "true")
			return _fail(where, "expects a bool (true/false), got %s" % json_type(value))
		TYPE_INT:
			return _decode_int(value, hint, hint_string, where)
		TYPE_FLOAT:
			if _is_number(value):
				return _ok(float(value))
			if value is String and (value as String).is_valid_float():
				return _ok((value as String).to_float())
			return _fail(where, "expects a number, got %s" % json_type(value))
		TYPE_STRING:
			return _decode_string(value, where)
		TYPE_STRING_NAME:
			var s := _decode_string(value, where)
			if s.errors.is_empty():
				s.value = StringName(s.value)
			return s
		TYPE_NODE_PATH:
			if value is NodePath:
				return _ok(value)
			if value is String:
				return _ok(NodePath(value))
			if value is Dictionary and str(value.get("type", "")) == "NodePath" and value.has("path"):
				return _ok(NodePath(str(value.path)))
			return _fail(where, "expects a node path string (e.g. \"../Player\"), got %s" % json_type(value))
		TYPE_OBJECT:
			return _decode_object(value, info, where)
		TYPE_ARRAY:
			return _decode_array(value, info, current, where)
		TYPE_DICTIONARY:
			return _decode_dictionary(value, current, where)
		TYPE_COLOR:
			return _decode_color(value, where)
		_:
			if _PACKED_ELEMENT.has(t):
				return _decode_packed(value, t, where)
			return _decode_struct(value, t, where)


## Decode a value for a slot that accepts any type (Variant). Plain JSON stays
## as-is; explicit {type: ...} objects become the named type, and
## {type:"Resource", path} / {type:"<ResourceClass>", ...} become resources.
## Plain strings are never loaded here: a Variant slot can't tell a path from text.
static func decode_variant(value: Variant, where: String = "value") -> Dictionary:
	if value is Array:
		var out: Array = []
		var errors: Array = []
		for i in range((value as Array).size()):
			var d := decode_variant(value[i], "%s[%d]" % [where, i])
			errors.append_array(d.errors)
			out.append(d.value)
		return {"value": out, "errors": errors}
	if not (value is Dictionary):
		return _ok(value)
	var dict: Dictionary = value
	var tname := str(dict.get("type", ""))
	if tname.is_empty():
		return _ok(VariantCodec.parse_value(dict))
	if tname == "NodePath":
		return _ok(NodePath(str(dict.get("path", ""))))
	var builtin := builtin_type_from_name(tname)
	if builtin != -1 and builtin != TYPE_OBJECT and builtin != TYPE_NIL:
		return decode(dict, {"type": builtin}, null, where)
	if tname == "Resource" or _is_resource_class(tname):
		return _decode_object(dict, {"type": TYPE_OBJECT, "class_name": "Resource"}, where)
	# Unknown discriminator: keep the legacy behavior (plain dictionary).
	return _ok(VariantCodec.parse_value(dict))


## Decode positional arguments for obj.method(...) using its signature. For
## set()/set_deferred() the value argument is decoded against the named
## property, so set("texture", "res://x.png") loads the texture.
## Returns {args, errors}.
static func decode_call_args(obj: Object, method: String, raw_args: Array, where: String = "args") -> Dictionary:
	var infos: Array = []
	for m in obj.get_method_list():
		if str(m.get("name", "")) == method:
			infos = m.get("args", [])
			break
	if (method == "set" or method == "set_deferred") and raw_args.size() == 2 and raw_args[0] is String:
		var pinfo := find_property(obj, str(raw_args[0]))
		if pinfo.is_empty():
			return {"args": [], "errors": ["%s[0]: '%s' is not a property of %s%s" % [where, raw_args[0], describe(obj), _suggestion(str(raw_args[0]), _property_map(obj, {}).keys())]]}
		infos = [{"type": TYPE_STRING_NAME}, pinfo]
	var out: Array = []
	var errors: Array = []
	for i in range(raw_args.size()):
		var w := "%s[%d]" % [where, i]
		var d: Dictionary
		if i < infos.size():
			d = decode(raw_args[i], infos[i], null, w)
		else:
			d = decode_variant(raw_args[i], w)  # vararg methods (call, emit_signal, ...)
		errors.append_array(d.errors)
		out.append(d.value)
	return {"args": out, "errors": errors}


## Property-list entry for `name` on `obj`, or {} if it has no such property.
static func find_property(obj: Object, name: String) -> Dictionary:
	return _property_map(obj, {}).get(name, {})


## The closest property names to `name` on `obj`, as " (did you mean 'x'?)" or "".
static func property_suggestion(obj: Object, name: String) -> String:
	return _suggestion(name, _property_map(obj, {}).keys())


# =============================================================================
# Value helpers (shared with tools)
# =============================================================================

## Equality that tolerates float rounding, int/float and String/StringName.
static func values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		if _is_number(a) and _is_number(b):
			return is_equal_approx(float(a), float(b))
		if (a is String or a is StringName) and (b is String or b is StringName):
			return str(a) == str(b)
		return false
	match typeof(a):
		TYPE_FLOAT:
			return is_equal_approx(a, b)
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR, TYPE_QUATERNION, TYPE_PLANE, \
		TYPE_RECT2, TYPE_AABB, TYPE_BASIS, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D:
			return a.is_equal_approx(b)
		TYPE_OBJECT:
			return is_same(a, b)
		TYPE_ARRAY:
			if (a as Array).size() != (b as Array).size():
				return false
			for i in range((a as Array).size()):
				if not values_equal(a[i], b[i]):
					return false
			return true
		_:
			return a == b


## True for a resource saved in its own file (not embedded in a scene).
static func is_external_resource(res: Variant) -> bool:
	if not (res is Resource):
		return false
	var p := (res as Resource).resource_path
	return not p.is_empty() and not p.contains("::")


## "Player (CharacterBody2D)" for nodes, the class name otherwise.
static func describe(obj: Object) -> String:
	if obj == null:
		return "null"
	if obj is Node and not str((obj as Node).name).is_empty():
		return "%s (%s)" % [(obj as Node).name, obj.get_class()]
	return obj.get_class()


## Short human-readable form of a value for error messages.
static func short_value(v: Variant) -> String:
	if v == null:
		return "null"
	if v is Resource:
		var p := (v as Resource).resource_path
		return "%s%s" % [v.get_class(), (" (%s)" % p) if not p.is_empty() and not p.contains("::") else ""]
	if v is Object:
		return describe(v)
	var s := var_to_str(v)
	return s if s.length() <= 80 else s.substr(0, 77) + "..."


## Human label for the type a slot expects ("Texture2D", "int", "Vector2", ...).
static func type_label(info: Dictionary) -> String:
	var t := int(info.get("type", TYPE_NIL))
	if t == TYPE_OBJECT:
		return " or ".join(_expected_classes(info))
	if t == TYPE_NIL:
		return "any value"
	return type_string(t)


## JSON-facing name of a value's type for error messages.
static func json_type(v: Variant) -> String:
	match typeof(v):
		TYPE_NIL: return "null"
		TYPE_BOOL: return "a bool"
		TYPE_INT, TYPE_FLOAT: return "a number (%s)" % str(v)
		TYPE_STRING, TYPE_STRING_NAME: return "a string (\"%s\")" % str(v).left(60)
		TYPE_ARRAY: return "an array"
		TYPE_DICTIONARY: return "an object"
		TYPE_OBJECT: return describe(v)
		_: return type_string(typeof(v))


## Built-in type id for a name like "Vector2" or "PackedColorArray"; -1 if none.
static func builtin_type_from_name(name: String) -> int:
	for t in range(TYPE_MAX):
		if type_string(t) == name:
			return t
	return -1


# =============================================================================
# Decoders
# =============================================================================

static func _decode_int(value: Variant, hint: int, hint_string: String, where: String) -> Dictionary:
	if hint == PROPERTY_HINT_FLAGS and (value is String or value is Array):
		return _decode_flags(value if value is Array else [value], hint_string, where)
	if value is String:
		if hint == PROPERTY_HINT_ENUM:
			return _decode_enum_name(value, hint_string, where)
		if (value as String).is_valid_int():
			return _ok((value as String).to_int())
		return _fail(where, "expects an integer, got %s" % json_type(value))
	if value is bool:
		return _ok(int(value))
	var n: int
	if value is int:
		n = value
	elif value is float:
		if not is_equal_approx(value, roundf(value)):
			return _fail(where, "expects an integer, got %s" % str(value))
		n = int(roundf(value))
	else:
		return _fail(where, "expects an integer, got %s" % json_type(value))
	if hint == PROPERTY_HINT_ENUM and not hint_string.is_empty():
		var options := _enum_options(hint_string)
		if not options.values().has(n):
			return _fail(where, "%d is not a valid option. Valid: %s" % [n, _enum_listing(options)])
	return _ok(n)


static func _decode_string(value: Variant, where: String) -> Dictionary:
	if value is String or value is StringName:
		return _ok(str(value))
	if value is float and is_equal_approx(value, roundf(value)) and absf(value) < 1e15:
		return _ok(str(int(value)))  # JSON numbers arrive as floats: 5 -> "5", not "5.0"
	if _is_number(value) or value is bool:
		return _ok(str(value))
	return _fail(where, "expects a string, got %s" % json_type(value))


## Enum hint strings look like "Disabled,Enabled" or "Inherit:0,Nearest:1".
static func _enum_options(hint_string: String) -> Dictionary:
	var out: Dictionary = {}
	var next := 0
	for part in hint_string.split(","):
		var name := part
		var val := next
		var colon := part.rfind(":")
		if colon != -1 and part.substr(colon + 1).is_valid_int():
			name = part.substr(0, colon)
			val = part.substr(colon + 1).to_int()
		out[name.strip_edges()] = val
		next = val + 1
	return out


static func _enum_listing(options: Dictionary) -> String:
	var parts: Array = []
	for k in options:
		parts.append("%s (%d)" % [k, options[k]])
	return ", ".join(parts)


static func _normalize_name(s: String) -> String:
	return s.to_lower().replace(" ", "").replace("_", "").replace("-", "")


## Accepts the option label ("Nearest"), a constant-style name
## ("TEXTURE_FILTER_NEAREST") or a numeric string.
static func _decode_enum_name(value: String, hint_string: String, where: String) -> Dictionary:
	if value.is_valid_int():
		return _decode_int(value.to_int(), PROPERTY_HINT_ENUM, hint_string, where)
	var options := _enum_options(hint_string)
	var wanted := _normalize_name(value)
	for k in options:
		if _normalize_name(k) == wanted:
			return _ok(options[k])
	var suffix_hits: Array = []
	for k in options:
		var nk := _normalize_name(k)
		if not nk.is_empty() and wanted.ends_with(nk):
			suffix_hits.append(k)
	if suffix_hits.size() == 1:
		return _ok(options[suffix_hits[0]])
	return _fail(where, "'%s' is not a valid option. Valid: %s" % [value, _enum_listing(options)])


static func _decode_flags(values: Array, hint_string: String, where: String) -> Dictionary:
	var bits: Dictionary = {}
	var next := 1
	for part in hint_string.split(","):
		var name := part
		var val := next
		var colon := part.rfind(":")
		if colon != -1 and part.substr(colon + 1).is_valid_int():
			name = part.substr(0, colon)
			val = part.substr(colon + 1).to_int()
		bits[_normalize_name(name)] = val
		next = val * 2
	var out := 0
	for v in values:
		if _is_number(v):
			out |= int(v)
			continue
		var key := _normalize_name(str(v))
		if not bits.has(key):
			return _fail(where, "'%s' is not a valid flag. Valid: %s" % [str(v), hint_string])
		out |= int(bits[key])
	return _ok(out)


static func _decode_color(value: Variant, where: String) -> Dictionary:
	if value is Color:
		return _ok(value)
	if value is String:
		var sentinel := Color(-1, -1, -1, -1)
		var c := Color.from_string(value, sentinel)
		if c == sentinel:
			return _fail(where, "'%s' is not a color. Use \"#rrggbb\", a name like \"red\", or {r, g, b, a} (0..1)" % value)
		return _ok(c)
	if value is Array:
		var arr: Array = value
		if (arr.size() == 3 or arr.size() == 4) and _all_numbers(arr):
			return _ok(Color(float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3]) if arr.size() == 4 else 1.0))
		return _fail(where, "expects a Color: [r, g, b] or [r, g, b, a] with numbers 0..1")
	if value is Dictionary:
		var d: Dictionary = value
		var err := _check_keys(d, ["r", "g", "b"], ["a"], "Color", where, ["r", "g", "b", "a"])
		if not err.is_empty():
			return {"value": null, "errors": err}
		return _ok(Color(float(d.r), float(d.g), float(d.b), float(d.get("a", 1.0))))
	return _fail(where, "expects a Color, got %s" % json_type(value))


## Strict decoder for Vector*, Rect2*, Quaternion, Plane, Transform2D, Basis,
## Transform3D and AABB. Missing or unknown components are errors (a {x, y}
## for a Vector3 used to become z=0 silently).
static func _decode_struct(value: Variant, t: int, where: String) -> Dictionary:
	if typeof(value) == t:
		return _ok(value)
	var label := type_string(t)

	if _COMPONENTS.has(t):
		var comps: Array = _COMPONENTS[t]
		var nums: Array = []
		if value is Array:
			if (value as Array).size() != comps.size() or not _all_numbers(value):
				return _fail(where, "expects %s as [%s] (numbers)" % [label, ", ".join(comps)])
			nums = value
		elif value is Dictionary:
			var err := _check_keys(value, comps, [], label, where, comps)
			if not err.is_empty():
				return {"value": null, "errors": err}
			for c in comps:
				nums.append(value[c])
		else:
			return _fail(where, "expects %s as {%s}, got %s" % [label, ", ".join(comps), json_type(value)])
		var is_int := t in [TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_VECTOR4I]
		if is_int:
			for n in nums:
				if not is_equal_approx(float(n), roundf(float(n))):
					return _fail(where, "%s components must be integers" % label)
		match t:
			TYPE_VECTOR2: return _ok(Vector2(nums[0], nums[1]))
			TYPE_VECTOR2I: return _ok(Vector2i(roundi(nums[0]), roundi(nums[1])))
			TYPE_VECTOR3: return _ok(Vector3(nums[0], nums[1], nums[2]))
			TYPE_VECTOR3I: return _ok(Vector3i(roundi(nums[0]), roundi(nums[1]), roundi(nums[2])))
			TYPE_VECTOR4: return _ok(Vector4(nums[0], nums[1], nums[2], nums[3]))
			TYPE_VECTOR4I: return _ok(Vector4i(roundi(nums[0]), roundi(nums[1]), roundi(nums[2]), roundi(nums[3])))

	match t:
		TYPE_RECT2, TYPE_RECT2I:
			var r := Rect2()
			if value is Array and (value as Array).size() == 4 and _all_numbers(value):
				r = Rect2(value[0], value[1], value[2], value[3])
			elif value is Dictionary and (value as Dictionary).has("position"):
				var err := _check_keys(value, ["position", "size"], [], label, where)
				if not err.is_empty():
					return {"value": null, "errors": err}
				var pos := _decode_struct(value.position, TYPE_VECTOR2, where + ".position")
				var size := _decode_struct(value.size, TYPE_VECTOR2, where + ".size")
				if not (pos.errors.is_empty() and size.errors.is_empty()):
					return {"value": null, "errors": pos.errors + size.errors}
				r = Rect2(pos.value, size.value)
			elif value is Dictionary:
				var err := _check_keys(value, ["x", "y", "width", "height"], [], label, where, ["x", "y", "width", "height"])
				if not err.is_empty():
					return {"value": null, "errors": err}
				r = Rect2(value.x, value.y, value.width, value.height)
			else:
				return _fail(where, "expects %s as {x, y, width, height}, {position, size} or [x, y, w, h]" % label)
			return _ok(Rect2i(r) if t == TYPE_RECT2I else r)
		TYPE_QUATERNION:
			if value is Array and (value as Array).size() == 4 and _all_numbers(value):
				return _ok(Quaternion(value[0], value[1], value[2], value[3]))
			if value is Dictionary:
				var d: Dictionary = value
				if d.has("euler"):
					var err := _check_keys(d, ["euler"], [], label, where)
					if not err.is_empty():
						return {"value": null, "errors": err}
					var e := _decode_struct(d.euler, TYPE_VECTOR3, where + ".euler")
					if not e.errors.is_empty():
						return e
					return _ok(Quaternion.from_euler(e.value))
				if d.has("axis"):
					var err2 := _check_keys(d, ["axis", "angle"], [], label, where, ["angle"])
					if not err2.is_empty():
						return {"value": null, "errors": err2}
					var ax := _decode_struct(d.axis, TYPE_VECTOR3, where + ".axis")
					if not ax.errors.is_empty():
						return ax
					return _ok(Quaternion((ax.value as Vector3).normalized(), float(d.angle)))
				var err3 := _check_keys(d, ["x", "y", "z", "w"], [], label, where, ["x", "y", "z", "w"])
				if not err3.is_empty():
					return {"value": null, "errors": err3}
				return _ok(Quaternion(d.x, d.y, d.z, d.w))
			return _fail(where, "expects a Quaternion as {x, y, z, w}, {euler} or {axis, angle}")
		TYPE_PLANE:
			if value is Array and (value as Array).size() == 4 and _all_numbers(value):
				return _ok(Plane(value[0], value[1], value[2], value[3]))
			if value is Dictionary:
				var err := _check_keys(value, ["normal", "d"], [], label, where, ["d"])
				if not err.is_empty():
					return {"value": null, "errors": err}
				var nrm := _decode_struct(value.normal, TYPE_VECTOR3, where + ".normal")
				if not nrm.errors.is_empty():
					return nrm
				return _ok(Plane(nrm.value, float(value.d)))
			return _fail(where, "expects a Plane as {normal: {x, y, z}, d}")
		TYPE_TRANSFORM2D:
			if value is Dictionary:
				var d: Dictionary = value
				if d.has("x") or d.has("y"):
					var err := _check_keys(d, ["x", "y", "origin"], [], label, where)
					if not err.is_empty():
						return {"value": null, "errors": err}
					var xs := _decode_struct(d.x, TYPE_VECTOR2, where + ".x")
					var ys := _decode_struct(d.y, TYPE_VECTOR2, where + ".y")
					var os := _decode_struct(d.origin, TYPE_VECTOR2, where + ".origin")
					var errs: Array = xs.errors + ys.errors + os.errors
					if not errs.is_empty():
						return {"value": null, "errors": errs}
					return _ok(Transform2D(xs.value, ys.value, os.value))
				var err2 := _check_keys(d, [], ["origin", "rotation", "scale", "skew"], label, where, ["rotation", "skew"])
				if not err2.is_empty():
					return {"value": null, "errors": err2}
				var origin := Vector2.ZERO
				var scale := Vector2.ONE
				if d.has("origin"):
					var o := _decode_struct(d.origin, TYPE_VECTOR2, where + ".origin")
					if not o.errors.is_empty():
						return o
					origin = o.value
				if d.has("scale"):
					var s := _decode_struct(d.scale, TYPE_VECTOR2, where + ".scale")
					if not s.errors.is_empty():
						return s
					scale = s.value
				return _ok(Transform2D(float(d.get("rotation", 0.0)), scale, float(d.get("skew", 0.0)), origin))
			return _fail(where, "expects a Transform2D as {origin, rotation?, scale?, skew?} or {x, y, origin}")
		TYPE_BASIS, TYPE_TRANSFORM3D, TYPE_AABB:
			if not (value is Dictionary):
				return _fail(where, "expects %s as an object" % label)
			var allowed := {
				TYPE_BASIS: ["x", "y", "z", "euler", "order", "quaternion", "axis", "angle", "scale"],
				TYPE_TRANSFORM3D: ["basis", "origin", "x_axis", "y_axis", "z_axis"],
				TYPE_AABB: ["position", "size"],
			}
			var err := _check_keys(value, [], allowed[t], label, where)
			if not err.is_empty():
				return {"value": null, "errors": err}
			var d2: Dictionary = (value as Dictionary).duplicate()
			d2["type"] = label
			var parsed: Variant = VariantCodec.parse_value(d2)
			if typeof(parsed) != t:
				return _fail(where, "could not read %s from %s" % [label, JSON.stringify(value)])
			return _ok(parsed)

	return _fail(where, "values of type %s can't be set from MCP" % label)


static func _decode_packed(value: Variant, t: int, where: String) -> Dictionary:
	if typeof(value) == t:
		return _ok(value)
	if not (value is Array):
		return _fail(where, "expects %s as an array, got %s" % [type_string(t), json_type(value)])
	var elem_t: int = _PACKED_ELEMENT[t]
	var items: Array = []
	var errors: Array = []
	for i in range((value as Array).size()):
		var d := decode(value[i], {"type": elem_t}, null, "%s[%d]" % [where, i])
		errors.append_array(d.errors)
		items.append(d.value)
	if not errors.is_empty():
		return {"value": null, "errors": errors}
	match t:
		TYPE_PACKED_BYTE_ARRAY: return _ok(PackedByteArray(items))
		TYPE_PACKED_INT32_ARRAY: return _ok(PackedInt32Array(items))
		TYPE_PACKED_INT64_ARRAY: return _ok(PackedInt64Array(items))
		TYPE_PACKED_FLOAT32_ARRAY: return _ok(PackedFloat32Array(items))
		TYPE_PACKED_FLOAT64_ARRAY: return _ok(PackedFloat64Array(items))
		TYPE_PACKED_STRING_ARRAY: return _ok(PackedStringArray(items))
		TYPE_PACKED_VECTOR2_ARRAY: return _ok(PackedVector2Array(items))
		TYPE_PACKED_VECTOR3_ARRAY: return _ok(PackedVector3Array(items))
		TYPE_PACKED_VECTOR4_ARRAY: return _ok(PackedVector4Array(items))
		TYPE_PACKED_COLOR_ARRAY: return _ok(PackedColorArray(items))
	return _fail(where, "unsupported packed array type %s" % type_string(t))


static func _decode_array(value: Variant, info: Dictionary, current: Variant, where: String) -> Dictionary:
	if not (value is Array):
		return _fail(where, "expects an array, got %s" % json_type(value))
	var elem := _array_element_info(info, current)
	var out: Array = []
	var errors: Array = []
	for i in range((value as Array).size()):
		var d := decode(value[i], elem, null, "%s[%d]" % [where, i])
		errors.append_array(d.errors)
		out.append(d.value)
	if not errors.is_empty():
		return {"value": null, "errors": errors}
	# A typed array property only accepts a typed array of the same kind.
	if current is Array and (current as Array).is_typed():
		var c: Array = current
		return _ok(Array(out, c.get_typed_builtin(), c.get_typed_class_name(), c.get_typed_script()))
	var et := int(elem.get("type", TYPE_NIL))
	if et != TYPE_NIL:
		var cn := StringName(elem.get("class_name", "")) if et == TYPE_OBJECT else &""
		if et != TYPE_OBJECT or ClassDB.class_exists(cn):
			return _ok(Array(out, et, cn, null))
	return _ok(out)


## Element slot info for an Array property: from the current typed value if
## there is one, otherwise from the hint ("24/17:Texture2D" or "int").
static func _array_element_info(info: Dictionary, current: Variant) -> Dictionary:
	if current is Array and (current as Array).is_typed():
		var c: Array = current
		var cn := str(c.get_typed_class_name())
		var out := {"type": c.get_typed_builtin(), "class_name": cn}
		if c.get_typed_builtin() == TYPE_OBJECT:
			var scr: Variant = c.get_typed_script()
			if scr is Script and not (scr as Script).get_global_name().is_empty():
				cn = str((scr as Script).get_global_name())
			out = {"type": TYPE_OBJECT, "class_name": cn, "hint": PROPERTY_HINT_RESOURCE_TYPE, "hint_string": cn}
		return out
	var hs := str(info.get("hint_string", ""))
	if hs.is_empty():
		return {"type": TYPE_NIL}
	var colon := hs.find(":")
	if colon != -1:
		var left := hs.substr(0, colon)
		var right := hs.substr(colon + 1)
		var parts := left.split("/")
		if parts[0].is_valid_int():
			return {
				"type": parts[0].to_int(),
				"hint": parts[1].to_int() if parts.size() > 1 and parts[1].is_valid_int() else PROPERTY_HINT_NONE,
				"hint_string": right,
				"class_name": right,
			}
	if int(info.get("hint", 0)) == PROPERTY_HINT_ARRAY_TYPE:
		var bt := builtin_type_from_name(hs)
		if bt != -1:
			return {"type": bt}
		return {"type": TYPE_OBJECT, "class_name": hs, "hint": PROPERTY_HINT_RESOURCE_TYPE, "hint_string": hs}
	return {"type": TYPE_NIL}


static func _decode_dictionary(value: Variant, current: Variant, where: String) -> Dictionary:
	if not (value is Dictionary):
		return _fail(where, "expects an object/dictionary, got %s" % json_type(value))
	var typed: bool = current is Dictionary and (current as Dictionary).is_typed()
	var key_info := {"type": TYPE_NIL}
	var val_info := {"type": TYPE_NIL}
	if typed:
		var c: Dictionary = current
		key_info = {"type": c.get_typed_key_builtin(), "class_name": str(c.get_typed_key_class_name())}
		val_info = {"type": c.get_typed_value_builtin(), "class_name": str(c.get_typed_value_class_name())}
		if int(val_info.type) == TYPE_OBJECT:
			val_info["hint"] = PROPERTY_HINT_RESOURCE_TYPE
			val_info["hint_string"] = val_info.class_name
	var out: Dictionary = {}
	var errors: Array = []
	for k in (value as Dictionary).keys():
		var kd := decode(k, key_info, null, "%s.<key %s>" % [where, str(k)])
		var vd := decode(value[k], val_info, null, "%s.%s" % [where, str(k)])
		errors.append_array(kd.errors)
		errors.append_array(vd.errors)
		out[kd.value] = vd.value
	if not errors.is_empty():
		return {"value": null, "errors": errors}
	if typed:
		var c2: Dictionary = current
		return _ok(Dictionary(out,
			c2.get_typed_key_builtin(), c2.get_typed_key_class_name(), c2.get_typed_key_script(),
			c2.get_typed_value_builtin(), c2.get_typed_value_class_name(), c2.get_typed_value_script()))
	return _ok(out)


## Resource-typed slots. Accepts:
##   "res://x.png"                       load the file
##   {type:"Resource", path:"res://..."} load the file (also {path} or {type:"Texture2D", path})
##   {type:"RectangleShape2D", size:...} new inline resource; other keys are its properties
## The result must match the slot's class (Texture2D, Shape2D, ...).
static func _decode_object(value: Variant, info: Dictionary, where: String) -> Dictionary:
	var expected := _expected_classes(info)
	var label := " or ".join(expected)

	if int(info.get("hint", 0)) == PROPERTY_HINT_NODE_TYPE or _all_node_classes(expected):
		return _fail(where, "references a node (%s). Node references can't be assigned through MCP yet; use a NodePath property or wire it up in code." % label)

	var obj: Object = null
	if value is Object:
		obj = value
	elif value is String:
		var loaded := _load_resource(value, where)
		if not loaded.errors.is_empty():
			return loaded
		obj = loaded.value
	elif value is Dictionary:
		var d: Dictionary = value
		var tname := str(d.get("type", ""))
		if d.has("path") or d.has("resource_path"):
			var err := _check_keys(d, [], ["type", "path", "resource_path", "class"], "a resource reference", where)
			if not err.is_empty():
				return {"value": null, "errors": err}
			var loaded2 := _load_resource(str(d.get("path", d.get("resource_path", ""))), where)
			if not loaded2.errors.is_empty():
				return loaded2
			obj = loaded2.value
			for cls in [tname, str(d.get("class", ""))]:
				if not cls.is_empty() and cls != "Resource" and not is_instance_of_class(obj, cls):
					return _fail(where, "%s is a %s, not a %s" % [d.get("path", d.get("resource_path")), obj.get_class(), cls])
		elif tname.is_empty():
			return _fail(where, "expects %s: pass a file path (\"res://...\") or an inline resource {\"type\": \"<%s class>\", ...properties}" % [label, label])
		elif tname == "Resource":
			return _fail(where, "{\"type\": \"Resource\"} needs a \"path\"")
		else:
			if ClassDB.class_exists(tname) and not _class_fits(tname, expected):
				return _fail(where, "expects %s, got {\"type\": \"%s\"}" % [label, tname])
			var made := _instantiate_resource(tname, expected, where)
			if not made.errors.is_empty():
				return made
			obj = made.value
			var nested: Dictionary = d.duplicate()
			nested.erase("type")
			if not nested.is_empty():
				var r := write(obj, nested, where)
				if not r.ok:
					return {"value": null, "errors": r.errors}
	else:
		return _fail(where, "expects %s: pass a file path (\"res://...\") or an inline resource {\"type\": \"<%s class>\", ...}, got %s" % [label, label, json_type(value)])

	if obj != null and not _matches_any(obj, expected):
		return _fail(where, "expects %s, got %s" % [label, short_value(obj)])
	return _ok(obj)


static func _load_resource(path_in: String, where: String) -> Dictionary:
	var path := path_in.strip_edges()
	if path.is_empty():
		return _fail(where, "empty resource path")
	if not path.contains("://"):
		path = "res://" + path
	if not ResourceLoader.exists(path):
		return _fail(where, "no resource at %s (missing, or not imported yet; call rescan_filesystem after creating files)" % path)
	var res := load(path)
	if res == null:
		return _fail(where, "failed to load %s" % path)
	return _ok(res)


static func _instantiate_resource(tname: String, expected: Array, where: String) -> Dictionary:
	if ClassDB.class_exists(tname):
		if not ClassDB.is_parent_class(tname, "Resource"):
			return _fail(where, "'%s' is not a resource class" % tname)
		if not ClassDB.can_instantiate(tname):
			var concrete: Array = []
			for c in ClassDB.get_inheriters_from_class(tname):
				if ClassDB.can_instantiate(c):
					concrete.append(c)
			concrete.sort()
			return _fail(where, "'%s' is abstract. Use a concrete class%s, or load a file with {\"path\": \"res://...\"}" % [tname, (" such as " + ", ".join(concrete.slice(0, 6))) if not concrete.is_empty() else ""])
		return _ok(ClassDB.instantiate(tname))
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == tname:
			var scr := load(str(entry.get("path", "")))
			if scr is Script and (scr as Script).can_instantiate():
				var inst: Variant = (scr as Script).new()
				if inst is Resource:
					return _ok(inst)
			return _fail(where, "'%s' is not an instantiable resource class" % tname)
	var candidates: Array = []
	for base in expected:
		if ClassDB.class_exists(base):
			candidates.append_array(ClassDB.get_inheriters_from_class(base))
	if candidates.is_empty():
		candidates = Array(ClassDB.get_inheriters_from_class("Resource"))
	return _fail(where, "unknown resource class '%s'%s" % [tname, _suggestion(tname, candidates)])


# =============================================================================
# Internals
# =============================================================================

static func _property_map(obj: Object, cache: Dictionary) -> Dictionary:
	var id := obj.get_instance_id()
	if cache.has(id):
		return cache[id]
	var out: Dictionary = {}
	var idx := 0
	for p in obj.get_property_list():
		if int(p.get("usage", 0)) & _HEADER_USAGE:
			continue
		var n := str(p.get("name", ""))
		if n.is_empty():
			continue
		var entry: Dictionary = p.duplicate()
		entry["_order"] = idx
		idx += 1
		out[n] = entry
	cache[id] = out
	return out


static func _expected_classes(info: Dictionary) -> Array:
	var hint := int(info.get("hint", 0))
	var hs := str(info.get("hint_string", ""))
	if (hint == PROPERTY_HINT_RESOURCE_TYPE or hint == PROPERTY_HINT_NODE_TYPE) and not hs.is_empty():
		var out: Array = []
		for c in hs.split(","):
			if not c.strip_edges().is_empty():
				out.append(c.strip_edges())
		return out
	var cn := str(info.get("class_name", ""))
	if not cn.is_empty():
		return [cn]
	return ["Object"]


static func _all_node_classes(classes: Array) -> bool:
	for c in classes:
		if not (ClassDB.class_exists(c) and ClassDB.is_parent_class(c, "Node")):
			return false
	return not classes.is_empty()


## True if engine class `cls` is (a subclass of) one of `classes`.
static func _class_fits(cls: String, classes: Array) -> bool:
	for c in classes:
		if c == "Object" or c == cls or (ClassDB.class_exists(c) and ClassDB.is_parent_class(cls, c)):
			return true
	return false


static func _matches_any(obj: Object, classes: Array) -> bool:
	for c in classes:
		if is_instance_of_class(obj, c):
			return true
	return false


## is_class() for engine classes, script inheritance for class_name scripts.
static func is_instance_of_class(obj: Object, cls: String) -> bool:
	if cls == "Object":
		return true
	if ClassDB.class_exists(cls):
		return obj.is_class(cls)
	var scr: Variant = obj.get_script()
	while scr is Script:
		if str((scr as Script).get_global_name()) == cls:
			return true
		scr = (scr as Script).get_base_script()
	return false


static func _is_resource_class(name: String) -> bool:
	if ClassDB.class_exists(name):
		return ClassDB.is_parent_class(name, "Resource")
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == name:
			return true
	return false


## Strict key check for object-shaped values. `numeric` lists keys whose
## values must be numbers. Returns a list of errors.
static func _check_keys(d: Dictionary, required: Array, optional: Array, label: String, where: String, numeric: Array = []) -> Array:
	var errors: Array = []
	var allowed: Array = required + optional + ["type"]
	for k in d.keys():
		if not allowed.has(str(k)):
			errors.append("%s: unknown key '%s' for %s (expected %s)" % [where, k, label, ", ".join(required + optional)])
	for k in required:
		if not d.has(k):
			errors.append("%s: %s is missing '%s'" % [where, label, k])
	for k in numeric:
		if d.has(k) and not _is_number(d[k]):
			errors.append("%s.%s: expects a number, got %s" % [where, k, json_type(d[k])])
	# A {type: ...} discriminator naming a different built-in type is a mistake
	# (e.g. {type:"Vector2"} for a Vector3). Vector2 vs Vector2i is fine.
	var tname := str(d.get("type", ""))
	if not tname.is_empty() and builtin_type_from_name(tname) != -1 \
			and tname.trim_suffix("i") != label.trim_suffix("i"):
		errors.append("%s: expects %s, got {\"type\": \"%s\"}" % [where, label, tname])
	return errors


## " (did you mean 'x'?)" for the closest candidates, or "". Combines edit
## distance (catches short typos like txt -> text) with substring and
## bigram similarity (catches longer names like color -> modulate_color).
static func _suggestion(name: String, candidates: Array) -> String:
	var lower := name.to_lower()
	var max_dist := maxi(1, lower.length() / 3)
	var scored: Array = []
	for c in candidates:
		var cs := str(c)
		var cl := cs.to_lower()
		var dist := _edit_distance(lower, cl)
		var score := lower.similarity(cl)
		if dist <= max_dist:
			score = maxf(score, 1.0 - float(dist) / 10.0)
		elif cl.contains(lower) or lower.contains(cl):
			score = maxf(score, 0.6)
		if score >= 0.5:
			scored.append([score, cs])
	if scored.is_empty():
		return ""
	scored.sort_custom(func(x, y): return x[0] > y[0])
	var names: Array = []
	for item in scored.slice(0, 3):
		names.append("'%s'" % item[1])
	return " (did you mean %s?)" % " or ".join(names)


## Levenshtein distance; inputs are short identifiers.
static func _edit_distance(a: String, b: String) -> int:
	if absi(a.length() - b.length()) > 3:
		return 99
	var prev: Array = range(b.length() + 1)
	for i in range(1, a.length() + 1):
		var cur: Array = [i]
		for j in range(1, b.length() + 1):
			var cost := 0 if a[i - 1] == b[j - 1] else 1
			cur.append(mini(mini(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost))
		prev = cur
	return prev[b.length()]


static func _join(prefix: String, key: String) -> String:
	return key if prefix.is_empty() else "%s.%s" % [prefix, key]


static func _is_number(v: Variant) -> bool:
	return v is int or v is float


static func _all_numbers(arr: Array) -> bool:
	for v in arr:
		if not _is_number(v):
			return false
	return true


static func _ok(v: Variant) -> Dictionary:
	return {"value": v, "errors": []}


static func _fail(where: String, msg: String) -> Dictionary:
	return {"value": null, "errors": ["%s: %s" % [where, msg]]}
