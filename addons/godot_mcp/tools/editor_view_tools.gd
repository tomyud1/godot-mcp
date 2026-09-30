@tool
extends Node
class_name EditorViewTools
## Editor viewport tools for MCP.
## Handles: take_editor_viewport_screenshot

const VariantCodec = preload("res://addons/godot_mcp/utils/variant_codec.gd")

var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

func _serialize_value(value: Variant) -> Variant:
	return VariantCodec.serialize_value(value)

func _ensure_output_path(output_path: String, allow_absolute: bool = false) -> Array:
	var normalized_path := output_path.strip_edges()
	if normalized_path.is_empty():
		var dir_path := "user://mcp_screenshots"
		var absolute_dir := ProjectSettings.globalize_path(dir_path)
		DirAccess.make_dir_recursive_absolute(absolute_dir)
		normalized_path = "%s/editor_viewport_%d.png" % [dir_path, Time.get_ticks_msec()]
	elif not normalized_path.begins_with("res://") and not normalized_path.begins_with("user://") and normalized_path.is_absolute_path() and not allow_absolute:
		# This tool creates the output directory and writes a file. Left
		# unrestricted, that is an arbitrary-write primitive driven by whatever
		# steered the agent, so absolute paths need an explicit opt-in.
		return [
			normalized_path, "",
			{
				&"ok": false,
				&"error": "Refusing to write a screenshot to an absolute path: " + normalized_path,
				&"hint": "Use res:// or user:// (or a relative path, which maps to user://). Pass allow_absolute_output=true only if you specifically want a path outside the project and the user asked for it.",
			}
		]
	elif not normalized_path.begins_with("res://") and not normalized_path.begins_with("user://") and not normalized_path.is_absolute_path():
		normalized_path = "user://" + normalized_path

	# A res:// or user:// path may still traverse out via "..". Note that
	# is_absolute_path() is true for "user://" too, so the scheme prefixes must
	# be checked first.
	var confinement := MCPPaths.check(normalized_path, true)
	if not confinement.is_empty():
		return [normalized_path, "", confinement]

	var absolute_path := normalized_path if normalized_path.is_absolute_path() else ProjectSettings.globalize_path(normalized_path)
	var base_dir := absolute_path.get_base_dir()
	if not base_dir.is_empty():
		var mkdir_error := DirAccess.make_dir_recursive_absolute(base_dir)
		if mkdir_error != OK:
			return [normalized_path, absolute_path, {&"ok": false, &"error": "Failed to create screenshot directory: " + base_dir}]

	return [normalized_path, absolute_path, {}]

func take_editor_viewport_screenshot(args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}

	var viewport_index: int = int(args.get(&"viewport_index", 0))
	var output_path: String = str(args.get(&"output_path", ""))
	var force_draw: bool = bool(args.get(&"force_draw", true))
	var allow_absolute_output: bool = bool(args.get(&"allow_absolute_output", false))

	if viewport_index < 0 or viewport_index > 3:
		return {&"ok": false, &"error": "Invalid 'viewport_index'. Use 0, 1, 2, or 3."}

	var path_result := _ensure_output_path(output_path, allow_absolute_output)
	if not path_result[2].is_empty():
		return path_result[2]
	var normalized_path: String = path_result[0]
	var absolute_path: String = path_result[1]

	var ei = _editor_plugin.get_editor_interface()
	var viewport = ei.get_editor_viewport_3d(viewport_index)
	if not viewport:
		return {&"ok": false, &"error": "Editor 3D viewport %d is not available" % viewport_index}

	if force_draw:
		RenderingServer.force_draw()

	var texture = viewport.get_texture()
	if not texture:
		return {&"ok": false, &"error": "Failed to read the editor viewport texture"}

	var image := texture.get_image()
	if image == null or image.is_empty():
		return {&"ok": false, &"error": "Viewport capture returned an empty image. Make sure the 3D editor viewport is visible and rendered."}

	var save_error := image.save_png(absolute_path)
	if save_error != OK:
		return {&"ok": false, &"error": "Failed to save screenshot: " + str(save_error)}

	var response := {
		&"ok": true,
		&"viewport_index": viewport_index,
		&"resource_path": normalized_path if normalized_path.begins_with("res://") or normalized_path.begins_with("user://") else "",
		&"absolute_path": absolute_path,
		&"width": image.get_width(),
		&"height": image.get_height(),
		&"message": "Captured editor viewport screenshot",
	}

	var camera = viewport.get_camera_3d()
	if camera:
		var camera_transform: Transform3D = camera.get_camera_transform()
		response[&"camera_transform"] = _serialize_value(camera_transform)
		response[&"camera_position"] = _serialize_value(camera_transform.origin)

	return response
