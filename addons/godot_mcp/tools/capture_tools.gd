@tool
extends Node
class_name MCPCaptureTools
## Captures the Godot editor viewport for MCP clients with vision support.

const MAX_DIMENSION := 1280
var _editor_plugin: EditorPlugin

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

func capture_editor_screenshot(_args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}
	var base := _editor_plugin.get_editor_interface().get_base_control()
	if base == null or base.get_viewport() == null:
		return {&"ok": false, &"error": "Editor viewport not available"}
	await _editor_plugin.get_tree().process_frame
	var image: Image = base.get_viewport().get_texture().get_image()
	if image == null:
		return {&"ok": false, &"error": "Failed to read editor viewport"}
	if image.is_compressed() and image.decompress() != OK:
		return {&"ok": false, &"error": "Failed to decompress editor screenshot"}
	var original_width := image.get_width()
	var original_height := image.get_height()
	var longest := maxi(original_width, original_height)
	if longest > MAX_DIMENSION:
		var scale := float(MAX_DIMENSION) / float(longest)
		image.resize(maxi(1, roundi(original_width * scale)), maxi(1, roundi(original_height * scale)), Image.INTERPOLATE_BILINEAR)
	var png := image.save_png_to_buffer()
	if png.is_empty():
		return {&"ok": false, &"error": "Failed to encode editor screenshot"}
	return {
		&"ok": true,
		&"mime": "image/png",
		&"image_b64": Marshalls.raw_to_base64(png),
		&"width": image.get_width(),
		&"height": image.get_height(),
		&"original_width": original_width,
		&"original_height": original_height,
	}
