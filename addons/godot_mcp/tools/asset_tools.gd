@tool
extends Node
class_name AssetTools
## Asset generation tools for MCP.
## Handles: generate_2d_asset, search_comfyui_nodes,
##          inspect_runninghub_workflow, customize_and_run_workflow

const MCPPaths = preload("res://addons/godot_mcp/utils/paths.gd")

var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

func _refresh_filesystem() -> void:
	if _editor_plugin:
		_editor_plugin.get_editor_interface().get_resource_filesystem().scan()

# =============================================================================
# generate_2d_asset - Render an SVG to a PNG asset
# =============================================================================
#
# Implementation notes (Bugs 1, 2, 3 from MCP feedback):
#   * No temp file on disk. Image.load_svg_from_buffer() takes raw bytes,
#     eliminating the user:// dependency and the parallel-call race condition.
#   * Reported dimensions come from the rendered Image, not from string-parsing
#     the SVG, so single-quoted attributes and missing width/height work.
#   * Optional explicit width/height arguments override the SVG's intrinsic
#     size by computing a render scale.
#   * If anything still goes wrong, we surface the actual Godot error code so
#     the caller can diagnose it without code-spelunking.
func generate_2d_asset(args: Dictionary) -> Dictionary:
	var svg_code: String = str(args.get(&"svg_code", ""))
	var filename: String = str(args.get(&"filename", ""))
	var save_path: String = str(args.get(&"save_path", "res://assets/generated/"))
	var explicit_width: int = int(args.get(&"width", 0))
	var explicit_height: int = int(args.get(&"height", 0))
	var scale_arg: float = float(args.get(&"scale", 0.0))

	if svg_code.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'svg_code'"}
	if filename.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'filename'"}

	if not filename.ends_with(".png"):
		filename += ".png"

	if not save_path.begins_with("res://"):
		save_path = "res://" + save_path
	if not save_path.ends_with("/"):
		save_path += "/"

	if not DirAccess.dir_exists_absolute(save_path):
		var mkerr := DirAccess.make_dir_recursive_absolute(save_path)
		if mkerr != OK and not DirAccess.dir_exists_absolute(save_path):
			return {&"ok": false, &"error": "Could not create save_path %s (err=%d %s)" % [
				ProjectSettings.globalize_path(save_path), mkerr, error_string(mkerr)]}

	# Determine render scale.
	# Priority: explicit `scale` > derived from explicit width/height > 1.0.
	var render_scale: float = 1.0
	if scale_arg > 0.0:
		render_scale = scale_arg
	elif explicit_width > 0 or explicit_height > 0:
		# Pull intrinsic size if possible (best-effort, regex tolerates either quote style).
		var intrinsic := _intrinsic_svg_size(svg_code)
		var int_w: int = intrinsic.get("width", 0)
		var int_h: int = intrinsic.get("height", 0)
		if int_w > 0 and explicit_width > 0:
			render_scale = float(explicit_width) / float(int_w)
		elif int_h > 0 and explicit_height > 0:
			render_scale = float(explicit_height) / float(int_h)
		# Otherwise fall through; agent must trust whatever render comes out.

	# Render SVG → Image directly from bytes. No temp file, no race.
	var image := Image.new()
	var svg_bytes := svg_code.to_utf8_buffer()
	var err := image.load_svg_from_buffer(svg_bytes, render_scale)
	if err != OK:
		return {
			&"ok": false,
			&"error": "Image.load_svg_from_buffer failed (err=%d %s). The SVG may be malformed." % [err, error_string(err)]
		}

	var full_path := save_path + filename
	var global_path := ProjectSettings.globalize_path(full_path)
	err = image.save_png(global_path)
	if err != OK:
		return {
			&"ok": false,
			&"error": "Failed to save PNG to %s (err=%d %s)" % [global_path, err, error_string(err)]
		}

	_refresh_filesystem()

	return {
		&"ok": true,
		&"resource_path": full_path,
		&"absolute_path": global_path,
		&"dimensions": {&"width": image.get_width(), &"height": image.get_height()},
		&"render_scale": render_scale,
		&"message": "Generated %s (%dx%d, scale=%.3f)" % [full_path, image.get_width(), image.get_height(), render_scale],
	}

# Best-effort SVG size extraction. Tolerates either quote style and arbitrary
# whitespace. Used only as a fallback; the rendered Image is authoritative.
func _intrinsic_svg_size(svg_code: String) -> Dictionary:
	var result: Dictionary = {}
	var re := RegEx.new()
	if re.compile("\\b(width|height)\\s*=\\s*[\"\\']([0-9.]+)") != OK:
		return result
	for m in re.search_all(svg_code):
		var attr := m.get_string(1)
		var val := int(m.get_string(2))
		if attr == "width":
			result["width"] = val
		else:
			result["height"] = val
	return result

# =============================================================================
# search_comfyui_nodes - Stub (requires external database)
# =============================================================================
func search_comfyui_nodes(_args: Dictionary) -> Dictionary:
	return {
		&"ok": true,
		&"results": [],
		&"count": 0,
		&"message": "ComfyUI node search requires the node database. This feature will be available in a future update.",
	}

# =============================================================================
# inspect_runninghub_workflow - Stub (requires API key)
# =============================================================================
func inspect_runninghub_workflow(args: Dictionary) -> Dictionary:
	var workflow_id: String = str(args.get(&"workflow_id", ""))
	if workflow_id.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'workflow_id'"}
	return {
		&"ok": true,
		&"workflow_id": workflow_id,
		&"message": "RunningHub workflow inspection requires API configuration. This feature will be available in a future update.",
	}

# =============================================================================
# customize_and_run_workflow - Stub (requires API key)
# =============================================================================
func customize_and_run_workflow(_args: Dictionary) -> Dictionary:
	return {
		&"ok": true,
		&"message": "Workflow customization requires RunningHub API configuration.",
	}
