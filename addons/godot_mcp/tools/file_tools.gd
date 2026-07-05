@tool
extends Node
class_name FileTools
## File operation tools for MCP.
## Handles: list_dir, read_file, search_project, create_script

const DEFAULT_MAX_BYTES := 20_000
const DEFAULT_MAX_RESULTS := 50
const DEFAULT_MAX_PER_FILE := 5
const DEFAULT_MATCH_LINE_CHARS := 200
const DEFAULT_PREVIEW_HEAD := 40
const DEFAULT_PREVIEW_TAIL := 10
const MAX_TRAVERSAL_DEPTH := 20
const REDACTED_TEXT := "[REDACTED]"
const _SKIP_EXTENSIONS: Dictionary = {
	".import": true, ".png": true, ".jpg": true, ".jpeg": true,
	".webp": true, ".svg": true, ".ogg": true, ".wav": true,
	".mp3": true, ".escn": true, ".glb": true, ".gltf": true,
	".uid": true,
}

var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

# =============================================================================
# analyze_script_header - cheap header inspection for .gd files
# -----------------------------------------------------------------------------
# Reads only the first chunk of a script and returns the structural bits the
# model needs (extends, class_name, @tool, signal/export counts) without
# load()-ing the script (which would echo parse errors to the editor output).
# =============================================================================
const _SCRIPT_HEADER_LINE_BUDGET := 200

static func analyze_script_header(path: String) -> Dictionary:
	var info: Dictionary = {
		&"path": path,
		&"extends": "",
		&"class_name": "",
		&"is_tool": false,
		&"export_count": 0,
		&"onready_count": 0,
		&"signal_count": 0,
	}
	if not FileAccess.file_exists(path):
		info[&"error"] = "File not found"
		return info
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		info[&"error"] = "Cannot open file"
		return info

	var line_num := 0
	while not f.eof_reached() and line_num < _SCRIPT_HEADER_LINE_BUDGET:
		var raw: String = f.get_line()
		line_num += 1
		var stripped := raw.strip_edges()
		if stripped.is_empty() or stripped.begins_with("#"):
			continue

		if stripped.begins_with("@tool"):
			info[&"is_tool"] = true
		elif stripped.begins_with("extends "):
			if str(info[&"extends"]).is_empty():
				var rest := stripped.substr(8).strip_edges()
				var hash_idx := rest.find("#")
				if hash_idx != -1:
					rest = rest.substr(0, hash_idx).strip_edges()
				info[&"extends"] = rest.split(" ", false)[0]
		elif stripped.begins_with("class_name "):
			if str(info[&"class_name"]).is_empty():
				var rest2 := stripped.substr(11).strip_edges()
				var hash_idx2 := rest2.find("#")
				if hash_idx2 != -1:
					rest2 = rest2.substr(0, hash_idx2).strip_edges()
				info[&"class_name"] = rest2.split(" ", false)[0]

		if "@onready" in stripped:
			info[&"onready_count"] = int(info[&"onready_count"]) + 1
		if "@export" in stripped:
			info[&"export_count"] = int(info[&"export_count"]) + 1
		if stripped.begins_with("signal "):
			info[&"signal_count"] = int(info[&"signal_count"]) + 1

	f.close()
	return info

# =============================================================================
# list_dir - List files and folders in a directory
# =============================================================================
func list_dir(args: Dictionary) -> Dictionary:
	var root: String = str(args.get(&"root", "res://"))
	var include_hidden: bool = bool(args.get(&"include_hidden", false))
	var max_entries: int = int(args.get(&"max_entries", 500))

	if not root.begins_with("res://"):
		root = "res://" + root

	var dir := DirAccess.open(root)
	if dir == null:
		return {&"ok": false, &"error": "Cannot open directory: " + root}

	var files: PackedStringArray = []
	var folders: PackedStringArray = []

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		# Skip hidden files unless requested
		if not include_hidden and name.begins_with("."):
			name = dir.get_next()
			continue

		# Skip .uid files
		if name.ends_with(".uid"):
			name = dir.get_next()
			continue

		if dir.current_is_dir():
			folders.append(name)
		else:
			files.append(name)

		name = dir.get_next()
	dir.list_dir_end()

	# Sort alphabetically
	files.sort()
	folders.sort()

	var total := files.size() + folders.size()
	var truncated := false
	if total > max_entries:
		truncated = true
		var folder_share: int = mini(folders.size(), max_entries / 2)
		var file_share: int = max_entries - folder_share
		if folders.size() > folder_share:
			folders = folders.slice(0, folder_share)
		if files.size() > file_share:
			files = files.slice(0, file_share)

	return {
		&"ok": true,
		&"path": root,
		&"files": files,
		&"folders": folders,
		&"total": total,
		&"truncated": truncated,
	}

# =============================================================================
# read_file - Read contents of a file
# =============================================================================
func read_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get(&"path", ""))
	var start_line: int = int(args.get(&"start_line", 1))
	var end_line: int = int(args.get(&"end_line", 0))
	var max_bytes: int = int(args.get(&"max_bytes", DEFAULT_MAX_BYTES))
	var redact_secrets: bool = bool(args.get(&"redact_secrets", true))
	var preview: bool = bool(args.get(&"preview", false))

	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path' parameter"}

	if not path.begins_with("res://"):
		path = "res://" + path

	if not FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File not found: " + path}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {&"ok": false, &"error": "Cannot open file: " + path}

	var file_size: int = file.get_length()

	# Preview mode: head + tail only, independent of byte budget.
	if preview:
		var all_lines: PackedStringArray = []
		while not file.eof_reached():
			all_lines.append(file.get_line())
		file.close()
		var total_lines := all_lines.size()
		var head_n := int(args.get(&"preview_head", DEFAULT_PREVIEW_HEAD))
		var tail_n := int(args.get(&"preview_tail", DEFAULT_PREVIEW_TAIL))
		var preview_text: String
		var head_range: Array = []
		var tail_range: Array = []
		if total_lines <= head_n + tail_n:
			# Whole file fits — emit numbered lines so callers can still cite
			# exact locations from preview output.
			var numbered: Array = []
			for i in range(total_lines):
				numbered.append("%5d| %s" % [i + 1, all_lines[i]])
			preview_text = "\n".join(numbered)
			if total_lines > 0:
				head_range = [1, total_lines]
		else:
			var head_lines: Array = []
			for i in range(head_n):
				head_lines.append("%5d| %s" % [i + 1, all_lines[i]])
			var tail_start := total_lines - tail_n
			var tail_lines: Array = []
			for i in range(tail_start, total_lines):
				tail_lines.append("%5d| %s" % [i + 1, all_lines[i]])
			preview_text = "\n".join(head_lines) \
				+ "\n... [%d lines omitted: %d-%d] ...\n" % [total_lines - head_n - tail_n, head_n + 1, tail_start] \
				+ "\n".join(tail_lines)
			head_range = [1, head_n]
			tail_range = [tail_start + 1, total_lines]
		if redact_secrets:
			preview_text = _redact_sensitive_content(preview_text)
		var preview_result: Dictionary = {
			&"ok": true,
			&"path": path,
			&"content": preview_text,
			&"total_lines": total_lines,
			&"file_size_bytes": file_size,
			&"preview": true,
			&"line_numbers": "Each preview line is prefixed with '<line_no>| '. Use these numbers with read_file's start_line/end_line to fetch the omitted region.",
			&"hint": "Preview only. Call read_file with start_line/end_line to fetch specific regions.",
		}
		if not head_range.is_empty():
			preview_result[&"head_range"] = head_range
		if not tail_range.is_empty():
			preview_result[&"tail_range"] = tail_range
		return preview_result

	var content: String
	var line_count: int = 0
	var truncated := false
	var total_lines := 0

	# If no line range specified, read up to max_bytes
	if end_line <= 0 and start_line <= 1:
		var size := mini(max_bytes, file_size)
		content = file.get_buffer(size).get_string_from_utf8()
		line_count = content.count("\n") + 1
		if size < file_size:
			truncated = true
			content += "\n[... truncated at %d of %d bytes; use start_line/end_line or max_bytes to read more ...]" % [size, file_size]
	else:
		# Read specific line range
		var lines: Array = []
		var current_line := 0
		var total_bytes := 0

		while not file.eof_reached():
			var line := file.get_line()
			current_line += 1

			if current_line < start_line:
				continue
			if end_line > 0 and current_line > end_line:
				break

			lines.append(line)
			total_bytes += line.length() + 1  # +1 for newline

			if total_bytes > max_bytes:
				truncated = true
				break

		# Keep reading lines to count total, cheaply.
		while not file.eof_reached():
			file.get_line()
			current_line += 1
		total_lines = current_line

		content = "\n".join(lines)
		line_count = lines.size()

	file.close()

	if redact_secrets:
		content = _redact_sensitive_content(content)

	var result: Dictionary = {
		&"ok": true,
		&"path": path,
		&"content": content,
		&"line_count": line_count,
		&"file_size_bytes": file_size,
		&"truncated": truncated,
	}
	if total_lines > 0:
		result[&"total_lines"] = total_lines
	if end_line > 0:
		result[&"range"] = [start_line, end_line]

	# Attach a lightweight script header summary for .gd files (extends,
	# class_name, @tool, signal/export counts) so callers don't need a
	# follow-up parse pass to learn the structural basics.
	if path.get_extension().to_lower() == "gd":
		var meta := analyze_script_header(path)
		meta.erase(&"path")
		result[&"script_metadata"] = meta
	return result

# =============================================================================
# find_files_by_name - Locate files by filename (not contents)
# =============================================================================
func find_files_by_name(args: Dictionary) -> Dictionary:
	var name: String = str(args.get(&"name", "")).strip_edges()
	if name.is_empty():
		return {&"ok": false, &"error": "Missing 'name'"}

	var root: String = str(args.get(&"root", "res://"))
	if not root.begins_with("res://"):
		root = "res://" + root
	var exact: bool = bool(args.get(&"exact", false))
	var max_results: int = int(args.get(&"max_results", 50))
	var target := name.to_lower()

	var out: Array = []
	_find_files_recursive(root, target, exact, out, max_results, 0)
	return {
		&"ok": true,
		&"name": name,
		&"root": root,
		&"matches": out,
		&"count": out.size(),
		&"truncated": out.size() >= max_results,
	}

func _find_files_recursive(path: String, target_lower: String, exact: bool, out: Array, max_results: int, depth: int) -> void:
	if out.size() >= max_results or depth > MAX_TRAVERSAL_DEPTH:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := path.path_join(name)
		if dir.current_is_dir():
			_find_files_recursive(full, target_lower, exact, out, max_results, depth + 1)
		else:
			var lname := name.to_lower()
			var matched := lname == target_lower if exact else lname.find(target_lower) != -1
			if matched:
				out.append(full)
				if out.size() >= max_results:
					dir.list_dir_end()
					return
		name = dir.get_next()
	dir.list_dir_end()

# =============================================================================
# get_file_outline - Return top-level declarations in a .gd file with line numbers
# =============================================================================
func get_file_outline(args: Dictionary) -> Dictionary:
	var path: String = str(args.get(&"path", "")).strip_edges()
	if path.is_empty():
		return {&"ok": false, &"error": "Missing 'path'"}
	if not path.begins_with("res://"):
		path = "res://" + path
	if not FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File not found: " + path}

	# Default to top-level declarations only. Local vars/consts inside function
	# bodies were the dominant source of noise in earlier outlines (the model
	# called this out explicitly), so callers must opt in with include_locals.
	var include_locals: bool = bool(args.get(&"include_locals", false))

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {&"ok": false, &"error": "Cannot open file: " + path}
	var lines: PackedStringArray = []
	while not file.eof_reached():
		lines.append(file.get_line())
	file.close()

	var ext := path.get_extension().to_lower()
	var entries: Array = []

	if ext != "gd":
		return {&"ok": false, &"error": "Outline only supported for .gd files (got ." + ext + ")"}

	var re := RegEx.new()
	re.compile("^(\\s*)(class_name|extends|class|func|signal|const|var|@export|enum)\\b")
	for i in range(lines.size()):
		var line: String = lines[i]
		var stripped := line.strip_edges(true, false)
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		var m := re.search(line)
		if m == null:
			continue
		var indent_str := m.get_string(1)
		var indent_depth := indent_str.length()
		# Top-level only by default. Anything indented (i.e. inside a func or
		# inner class) is considered "local" and skipped unless requested.
		if not include_locals and indent_depth > 0:
			continue
		var kw := m.get_string(2)
		var sig: String = stripped
		if sig.length() > 120:
			sig = sig.substr(0, 120) + "…"
		entries.append({
			&"line": i + 1,
			&"kind": kw,
			&"depth": indent_depth,
			&"signature": sig,
		})

	# Compute end-line spans for `func` entries (and top-level `class` blocks)
	# so callers don't have to guess where to slice with read_file.
	_compute_outline_spans(entries, lines)

	return {
		&"ok": true,
		&"path": path,
		&"total_lines": lines.size(),
		&"entries": entries,
		&"count": entries.size(),
		&"include_locals": include_locals,
		&"hint": "Top-level only by default. Pass include_locals=true to surface declarations inside function bodies. Use start_line/end_line from each entry with read_file to fetch its body.",
	}

func _compute_outline_spans(entries: Array, lines: PackedStringArray) -> void:
	# Use indent of the next sibling-or-shallower entry as the end of each
	# func/class span. Cheap heuristic that handles GDScript's
	# indentation-defined blocks well enough for chat UX.
	for i in range(entries.size()):
		var entry: Dictionary = entries[i]
		var kind := str(entry.get(&"kind", ""))
		if kind != "func" and kind != "class":
			continue
		var start_line := int(entry.get(&"line", 0))
		var depth := int(entry.get(&"depth", 0))
		var end_line := lines.size()
		# Walk forward looking for the next non-blank line at the same or
		# shallower indent. The line before that is the span end.
		for j in range(start_line, lines.size()):
			var l: String = lines[j]
			var stripped := l.strip_edges()
			if stripped.is_empty() or stripped.begins_with("#"):
				continue
			var leading := 0
			while leading < l.length() and (l.substr(leading, 1) == "\t" or l.substr(leading, 1) == " "):
				leading += 1
			if leading <= depth:
				end_line = j
				break
		entry[&"end_line"] = end_line
		entry[&"line_count"] = end_line - start_line + 1

# =============================================================================
# search_project - Search for text in project files
# =============================================================================
func search_project(args: Dictionary) -> Dictionary:
	var query: String = str(args.get(&"query", ""))
	var glob_filter: String = str(args.get(&"glob", args.get(&"file_pattern", "")))
	var root: String = str(args.get(&"root", args.get(&"path", "res://")))
	var include_docs: bool = bool(args.get(&"include_docs", false))
	var max_results: int = int(args.get(&"max_results", DEFAULT_MAX_RESULTS))
	var max_per_file: int = int(args.get(&"max_per_file", DEFAULT_MAX_PER_FILE))
	var files_only: bool = bool(args.get(&"files_only", false))
	var line_chars: int = int(args.get(&"line_chars", DEFAULT_MATCH_LINE_CHARS))
	var case_sensitive: bool = bool(args.get(&"case_sensitive", false))
	var use_regex: bool = bool(args.get(&"regex", false))
	var effective_regex: bool = use_regex or _has_unescaped_alternation(query)
	var regex: RegEx = null

	if query.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'query' parameter"}

	if effective_regex:
		regex = RegEx.new()
		var compile_err := regex.compile(query)
		if compile_err != OK:
			if use_regex:
				return {&"ok": false, &"error": "Invalid regex query"}
			effective_regex = false
			regex = null

	if root.strip_edges().is_empty():
		root = "res://"
	if not root.begins_with("res://"):
		root = "res://" + root
	if root.ends_with("/") and root.length() > 6:
		root = root.substr(0, root.length() - 1)

	var search_query := query if case_sensitive else query.to_lower()
	var files := _collect_files(root, glob_filter)
	var total_matches := 0
	var grouped: Array = []  # [{file, matches: [{line, content}], count}]
	var matched_files: PackedStringArray = []

	for file_path: String in files:
		if total_matches >= max_results:
			break

		if _is_search_excluded_path(file_path, include_docs, root):
			continue

		var file := FileAccess.open(file_path, FileAccess.READ)
		if file == null:
			continue

		var content := file.get_as_text()
		file.close()

		if not effective_regex:
			var search_content := content if case_sensitive else content.to_lower()
			if search_content.find(search_query) == -1:
				continue
		elif regex.search(content) == null:
			continue

		# files_only mode: short-circuit. We already know the file matches; do
		# not scan individual lines (which would let one large file exhaust
		# max_results before any other file is considered).
		if files_only:
			matched_files.append(file_path)
			total_matches += 1
			if matched_files.size() >= max_results:
				break
			continue

		var file_matches: Array = []
		var lines := content.split("\n")
		for i: int in range(lines.size()):
			var line := lines[i]
			var matched := false
			if effective_regex:
				matched = regex.search(line) != null
			else:
				var search_line := line if case_sensitive else line.to_lower()
				matched = search_line.find(search_query) != -1

			if matched:
				if file_matches.size() < max_per_file:
					var trimmed := line.strip_edges()
					if trimmed.length() > line_chars:
						trimmed = trimmed.substr(0, line_chars) + "…"
					file_matches.append({&"line": i + 1, &"content": trimmed})
				total_matches += 1
				if total_matches >= max_results:
					break

		if not file_matches.is_empty():
			grouped.append({&"file": file_path, &"matches": file_matches})

	var result: Dictionary = {
		&"ok": true,
		&"root": root,
		&"query": query,
		&"glob": glob_filter,
		&"regex": effective_regex,
		&"truncated": total_matches >= max_results,
	}
	if files_only:
		# In files_only mode, total_matches counts matching FILES (not line hits),
		# so the AI doesn't see a confusing mismatch like "1 file but 30 matches".
		result[&"files"] = matched_files
		result[&"file_count"] = matched_files.size()
		result[&"match_count"] = matched_files.size()
		result[&"mode"] = "files_only"
	else:
		result[&"files"] = grouped
		result[&"file_count"] = grouped.size()
		result[&"match_count"] = total_matches
		result[&"mode"] = "lines"
	return result

func _is_search_excluded_path(file_path: String, include_docs: bool, root: String) -> bool:
	if not include_docs and file_path.begins_with("user://godot-docs-reference/"):
		return true
	if file_path.begins_with("res://addons/godot_mcp/") and not root.begins_with("res://addons/godot_mcp"):
		return true
	return false

func _collect_files(path: String, glob_filter: String) -> PackedStringArray:
	"""Recursively collect all searchable files."""
	var result: PackedStringArray = []
	var patterns := _expand_glob_patterns(glob_filter)
	_collect_files_recursive(path, patterns, result)
	return result

func _collect_files_recursive(path: String, patterns: PackedStringArray, out: PackedStringArray, depth: int = 0) -> void:
	if depth >= MAX_TRAVERSAL_DEPTH:
		return

	var dir := DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		# Skip hidden
		if name.begins_with("."):
			name = dir.get_next()
			continue

		var full_path := path.path_join(name)

		if dir.current_is_dir():
			_collect_files_recursive(full_path, patterns, out, depth + 1)
		else:
			var ext := "." + name.get_extension().to_lower()
			if not _SKIP_EXTENSIONS.has(ext):
				if patterns.is_empty() or _matches_any_glob(full_path, patterns):
					out.append(full_path)

		name = dir.get_next()
	dir.list_dir_end()

func _matches_any_glob(path: String, patterns: PackedStringArray) -> bool:
	for pattern in patterns:
		if _matches_glob(path, pattern):
			return true
	return false

func _matches_glob(path: String, pattern: String) -> bool:
	var normalized := pattern.strip_edges().replace("\\", "/")
	if normalized.is_empty():
		return true
	if normalized.find("/") == -1:
		normalized = "**/" + normalized

	var regex_pattern := "^"
	var i := 0
	while i < normalized.length():
		if i + 2 < normalized.length() and normalized.substr(i, 3) == "**/":
			regex_pattern += "(?:.*/)?"
			i += 3
			continue

		var c := normalized.substr(i, 1)
		if c == "*":
			if i + 1 < normalized.length() and normalized.substr(i + 1, 1) == "*":
				regex_pattern += ".*"
				i += 2
				continue
			regex_pattern += "[^/]*"
		elif c == "?":
			regex_pattern += "[^/]"
		elif c == ".":
			regex_pattern += "\\."
		elif c == "+":
			regex_pattern += "\\+"
		elif c == "(":
			regex_pattern += "\\("
		elif c == ")":
			regex_pattern += "\\)"
		elif c == "[":
			regex_pattern += "\\["
		elif c == "]":
			regex_pattern += "\\]"
		elif c == "{":
			regex_pattern += "\\{"
		elif c == "}":
			regex_pattern += "\\}"
		elif c == "^":
			regex_pattern += "\\^"
		elif c == "$":
			regex_pattern += "\\$"
		elif c == "|":
			regex_pattern += "\\|"
		else:
			regex_pattern += c
		i += 1

	regex_pattern += "$"
	var regex := RegEx.new()
	if regex.compile(regex_pattern) != OK:
		return path.find(normalized) != -1
	return regex.search(path.replace("\\", "/")) != null

func _expand_glob_patterns(glob_filter: String) -> PackedStringArray:
	var trimmed := glob_filter.strip_edges()
	if trimmed.is_empty():
		return PackedStringArray()

	var expanded := PackedStringArray()
	for raw_pattern in _split_glob_list(trimmed):
		for option in _expand_brace_pattern(raw_pattern):
			var clean := option.strip_edges()
			if clean.is_empty():
				continue
			if not expanded.has(clean):
				expanded.append(clean)

	return expanded

func _split_glob_list(glob_filter: String) -> PackedStringArray:
	var out := PackedStringArray()
	var current := ""
	var depth := 0

	for i in range(glob_filter.length()):
		var c := glob_filter.substr(i, 1)
		if c == "{":
			depth += 1
		elif c == "}" and depth > 0:
			depth -= 1

		if c == "," and depth == 0:
			var part := current.strip_edges()
			if not part.is_empty():
				out.append(part)
			current = ""
			continue

		current += c

	var tail := current.strip_edges()
	if not tail.is_empty():
		out.append(tail)

	return out

func _expand_brace_pattern(pattern: String) -> PackedStringArray:
	var start := pattern.find("{")
	if start == -1:
		return PackedStringArray([pattern])

	var depth := 0
	var end := -1
	for i in range(start, pattern.length()):
		var c := pattern.substr(i, 1)
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				end = i
				break

	if end == -1:
		return PackedStringArray([pattern])

	var prefix := pattern.substr(0, start)
	var options := pattern.substr(start + 1, end - start - 1).split(",", false)
	var suffix := pattern.substr(end + 1)
	var out := PackedStringArray()
	for option in options:
		for expanded in _expand_brace_pattern(prefix + option + suffix):
			out.append(expanded)
	return out

func _has_unescaped_alternation(query: String) -> bool:
	var escaped := false
	for i in range(query.length()):
		var c := query.substr(i, 1)
		if escaped:
			escaped = false
			continue
		if c == "\\":
			escaped = true
			continue
		if c == "|":
			return true
	return false

# =============================================================================
# create_script - Create a new GDScript file
# =============================================================================
func create_script(args: Dictionary) -> Dictionary:
	var path: String = str(args.get(&"path", ""))
	var content: String = str(args.get(&"content", ""))

	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path' parameter"}

	if not path.begins_with("res://"):
		path = "res://" + path

	# Add .gd extension if missing
	if not "." in path.get_file():
		path += ".gd"

	# Check if file already exists
	if FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File already exists: " + path}

	# Ensure parent directory exists
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return {&"ok": false, &"error": "Could not create directory: " + dir_path}

	# Write file
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {&"ok": false, &"error": "Could not create file: " + path}

	file.store_string(content)
	file.close()

	# Refresh filesystem so Godot sees the new file
	_refresh_filesystem()

	var line_array: PackedStringArray = content.split("\n")
	var result: Dictionary = {
		&"ok": true,
		&"path": path,
		&"size_bytes": content.length(),
		&"new_total_lines": line_array.size(),
		&"message": "Script created successfully"
	}
	# Bundle parse verification + script header into the response so the model
	# doesn't need a follow-up read_file/validate_script round-trip to confirm
	# its newly-created script compiles cleanly.
	if path.get_extension().to_lower() == "gd":
		var script := GDScript.new()
		script.source_code = content
		var err := script.reload()
		if err == OK:
			result[&"validation"] = {&"parsed": true}
		else:
			result[&"validation"] = {&"parsed": false, &"error_code": err}
		var meta := analyze_script_header(path)
		meta.erase(&"path")
		result[&"script_metadata"] = meta
	return result

func _refresh_filesystem() -> void:
	"""Tell Godot to rescan the filesystem."""
	if _editor_plugin != null:
		_editor_plugin.get_editor_interface().get_resource_filesystem().call_deferred("scan")
	elif Engine.is_editor_hint():
		# Fallback if no plugin reference
		var editor_interface = Engine.get_singleton("EditorInterface")
		if editor_interface:
			editor_interface.get_resource_filesystem().call_deferred("scan")

func _redact_sensitive_content(content: String) -> String:
	var out := content
	var rules := [
		{"pattern": "(?im)^(\\s*(?:provider/)?api_key\\s*=\\s*).*$", "replacement": "$1" + REDACTED_TEXT},
		{"pattern": "(?im)^(\\s*(?:api[_-]?key|token|access[_-]?token|refresh[_-]?token|password|secret)\\s*[:=]\\s*).*$", "replacement": "$1" + REDACTED_TEXT},
		{"pattern": "(?im)^(\\s*authorization\\s*[:=]\\s*bearer\\s+).*$", "replacement": "$1" + REDACTED_TEXT},
		{"pattern": "(?im)^(\\s*x-api-key\\s*[:=]\\s*).*$", "replacement": "$1" + REDACTED_TEXT},
	]

	for rule in rules:
		var regex := RegEx.new()
		var err := regex.compile(str(rule["pattern"]))
		if err != OK:
			continue
		out = regex.sub(out, str(rule["replacement"]), true)

	return out
