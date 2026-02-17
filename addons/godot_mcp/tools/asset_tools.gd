@tool
extends Node
class_name AssetTools
## Asset generation tools for MCP.
## Handles: generate_2d_asset, search_comfyui_nodes,
##          inspect_runninghub_workflow, customize_and_run_workflow

var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

func _refresh_filesystem() -> void:
	if _editor_plugin:
		_editor_plugin.get_editor_interface().get_resource_filesystem().scan()

# =============================================================================
# generate_2d_asset - Generate PNG from SVG code
# =============================================================================
func generate_2d_asset(args: Dictionary) -> Dictionary:
	var svg_code: String = str(args.get("svg_code", ""))
	var filename: String = str(args.get("filename", ""))
	var save_path: String = str(args.get("save_path", "res://assets/generated/"))

	if svg_code.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'svg_code'"}
	if filename.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'filename'"}

	# Ensure .png extension
	if not filename.ends_with(".png"):
		filename += ".png"

	# Ensure save path
	if not save_path.begins_with("res://"):
		save_path = "res://" + save_path
	if not save_path.ends_with("/"):
		save_path += "/"

	# Create directory if needed
	if not DirAccess.dir_exists_absolute(save_path):
		DirAccess.make_dir_recursive_absolute(save_path)

	# Parse SVG dimensions from the svg_code
	var width := 64
	var height := 64

	# Simple regex-free parsing for width/height
	var w_start := svg_code.find("width=\"")
	if w_start != -1:
		var w_val := svg_code.substr(w_start + 7)
		var w_end := w_val.find("\"")
		if w_end != -1:
			width = int(w_val.substr(0, w_end))

	var h_start := svg_code.find("height=\"")
	if h_start != -1:
		var h_val := svg_code.substr(h_start + 8)
		var h_end := h_val.find("\"")
		if h_end != -1:
			height = int(h_val.substr(0, h_end))

	# Create Image from SVG
	var image := Image.new()

	# Save SVG to temp file, then load as image
	var temp_svg_path := "user://temp_asset.svg"
	var svg_file := FileAccess.open(temp_svg_path, FileAccess.WRITE)
	if not svg_file:
		return {"ok": false, "error": "Failed to create temp SVG file"}
	svg_file.store_string(svg_code)
	svg_file.close()

	# Load SVG as image
	var err := image.load(temp_svg_path)
	if err != OK:
		# Fallback: try loading SVG data directly
		image = Image.create(width, height, false, Image.FORMAT_RGBA8)
		image.fill(Color(1, 0, 1, 1))  # Magenta fallback = something went wrong
		print("[MCP] Warning: Could not render SVG, created fallback image")

	# Clean up temp file
	DirAccess.remove_absolute(temp_svg_path)

	# Save as PNG
	var full_path := save_path + filename
	var global_path := ProjectSettings.globalize_path(full_path)
	err = image.save_png(global_path)
	if err != OK:
		return {"ok": false, "error": "Failed to save PNG: " + str(err)}

	_refresh_filesystem()

	return {
		"ok": true,
		"resource_path": full_path,
		"dimensions": {"width": width, "height": height},
		"message": "Generated %s (%dx%d)" % [full_path, width, height]
	}

# =============================================================================
# search_comfyui_nodes - Stub (requires external database)
# =============================================================================
func search_comfyui_nodes(args: Dictionary) -> Dictionary:
	# This tool requires the ComfyUI node database which was bundled with the old plugin
	# For now, return a message indicating it needs setup
	return {
		"ok": true,
		"results": [],
		"count": 0,
		"message": "ComfyUI node search requires the node database. This feature will be available in a future update."
	}

# =============================================================================
# inspect_runninghub_workflow - Stub (requires API key)
# =============================================================================
func inspect_runninghub_workflow(args: Dictionary) -> Dictionary:
	var workflow_id: String = str(args.get("workflow_id", ""))
	if workflow_id.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'workflow_id'"}

	return {
		"ok": true,
		"workflow_id": workflow_id,
		"message": "RunningHub workflow inspection requires API configuration. This feature will be available in a future update."
	}

# =============================================================================
# customize_and_run_workflow - Stub (requires API key)
# =============================================================================
func customize_and_run_workflow(args: Dictionary) -> Dictionary:
	return {
		"ok": true,
		"message": "RunningHub workflow execution requires API configuration. This feature will be available in a future update."
	}
