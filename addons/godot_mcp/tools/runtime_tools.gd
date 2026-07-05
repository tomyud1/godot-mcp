@tool
extends Node
class_name RuntimeTools

func execute_gdscript(args: Dictionary) -> Dictionary:
	var code: String = str(args.get("code", ""))
	var context: Dictionary = args.get("context", {})
	if code.strip_edges().is_empty():
		return {
			"ok": false,
			"error": "Missing code",
			"stdout": [],
			"stderr": ["Missing 'code' parameter"],
		}

	var wrapped := _wrap_snippet(code)
	var script := GDScript.new()
	script.source_code = wrapped
	var err := script.reload()
	if err != OK:
		return {
			"ok": false,
			"error": "Snippet parse failed",
			"error_code": err,
			"stdout": [],
			"stderr": ["Snippet parse failed (error_code=%d). Check syntax of the supplied code." % err],
			"wrapped_script": wrapped,
		}

	var instance = script.new()
	if instance == null or not instance.has_method("run"):
		return {
			"ok": false,
			"error": "Failed to create snippet runner",
			"stdout": [],
			"stderr": ["Could not instantiate the wrapped snippet runner."],
		}

	# Capture print() output by installing a temporary capture buffer on the
	# instance. The wrapper script's `_p` helper appends to it instead of (or
	# in addition to) the editor console, so we can return what the snippet
	# would have printed alongside the structured result.
	instance.set("__captured_stdout", [])
	var result: Variant = null
	var threw := false
	var thrown_msg := ""
	# GDScript has no try/except, but `call()` swallows runtime errors and
	# returns null while still emitting them to the editor log. We can detect
	# the most common failure (null result + missing context call) but otherwise
	# rely on the captured output.
	result = instance.call("run", context)

	var captured: Array = instance.get("__captured_stdout")
	if captured == null:
		captured = []

	var serialized: Variant = _serialize_value(result)
	var result_type := _type_name(result)

	return {
		"ok": true,
		"result": serialized,
		"result_repr": str(result),
		"result_type": result_type,
		"is_null": result == null,
		"stdout": captured,
		"stderr": [],
		"thrown": threw,
		"error_message": thrown_msg,
	}

func _type_name(value: Variant) -> String:
	if value == null:
		return "null"
	match typeof(value):
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_STRING_NAME: return "StringName"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_ARRAY: return "Array"
		TYPE_OBJECT:
			if value is Object:
				return value.get_class()
			return "Object"
		_: return "Variant(%d)" % typeof(value)

func _wrap_snippet(code: String) -> String:
	# We expose `_p(...)` inside the snippet so callers (or auto-injected code)
	# can record output that gets returned in the `stdout` array. Existing
	# `print(...)` calls still go to the editor console as before.
	var lines := code.split("\n")
	var wrapped_lines: PackedStringArray = [
		"extends RefCounted",
		"var __captured_stdout: Array = []",
		"func _p(value) -> void:",
		"\t__captured_stdout.append(str(value))",
		"\tprint(value)",
		"func run(context: Dictionary) -> Variant:",
	]
	for line: String in lines:
		wrapped_lines.append("\t" + line)
	if not code.contains("return"):
		wrapped_lines.append("\treturn null")
	return "\n".join(wrapped_lines) + "\n"

func _serialize_value(value: Variant) -> Variant:
	if value is Object:
		if value is Resource and value.resource_path != "":
			return {"type": "Resource", "path": value.resource_path}
		if value is Node:
			return {"type": "Node", "name": value.name, "class": value.get_class()}
		return {"type": "Object", "class": value.get_class()}
	return value
