@tool
extends Node
class_name DocsTools

const DOCS_ROOT := "res://addons/godot_mcp/godot-docs-reference"
const ONLINE_DOCS_URL := "https://docs.godotengine.org/en/stable/classes/"
const XML_BASE_URL := "https://raw.githubusercontent.com/godotengine/godot/master/doc/classes/"
const DEFAULT_MAX_RESULTS := 8

# =============================================================================
# godot_class_doc  —  Tier 2: targeted class reference from Godot's XML source
# =============================================================================

func godot_class_doc(args: Dictionary) -> Dictionary:
	var class_name_str: String = str(args.get("class_name", "")).strip_edges()
	if class_name_str.is_empty():
		return {"ok": false, "error": "Missing 'class_name'"}

	var section: String = str(args.get("section", "brief")).to_lower()
	var name_filter: String = str(args.get("filter", "")).to_lower()
	var with_desc: bool = bool(args.get("with_description", true))

	var valid_sections := ["brief", "description", "methods", "properties", "signals", "constants", "all"]
	if section not in valid_sections:
		return {"ok": false, "error": "Invalid section '%s'. Use: %s" % [section, ", ".join(valid_sections)]}

	# Fetch the XML from GitHub
	var url := XML_BASE_URL + class_name_str + ".xml"
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "HTTP request failed for class '%s'" % class_name_str}

	var response = await http.request_completed
	http.queue_free()

	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		if response[1] == 404:
			return {"ok": false, "error": "Class '%s' not found in Godot docs. Check the class name." % class_name_str}
		return {"ok": false, "error": "Failed to fetch docs. HTTP %d" % response[1]}

	var xml_text: String = (response[3] as PackedByteArray).get_string_from_utf8()
	return _parse_class_xml(xml_text, class_name_str, section, name_filter, with_desc)


func _parse_class_xml(xml_text: String, class_name_str: String, section: String, name_filter: String, with_desc: bool) -> Dictionary:
	var result: Dictionary = {"ok": true, "class": class_name_str}
	result["url"] = ONLINE_DOCS_URL + "class_" + class_name_str.to_lower() + ".html"

	# Simple tag-based parsing (more reliable than XMLParser for this structure)
	var want_brief := section == "brief" or section == "all"
	var want_desc := section == "description" or section == "all"
	var want_methods := section == "methods" or section == "all"
	var want_props := section == "properties" or section == "all"
	var want_signals := section == "signals" or section == "all"
	var want_constants := section == "constants" or section == "all"

	# Extract inherits
	var inherits_match := RegEx.new()
	inherits_match.compile('inherits="([^"]*)"')
	var inh := inherits_match.search(xml_text)
	if inh:
		result["inherits"] = inh.get_string(1)

	if want_brief:
		result["brief"] = _extract_tag_content(xml_text, "brief_description")

	if want_desc:
		result["description"] = _extract_tag_content(xml_text, "description")

	if want_methods:
		result["methods"] = _extract_methods(xml_text, name_filter, with_desc)

	if want_props:
		result["properties"] = _extract_members(xml_text, name_filter, with_desc)

	if want_signals:
		result["signals"] = _extract_signals(xml_text, name_filter, with_desc)

	if want_constants:
		result["constants"] = _extract_constants(xml_text, name_filter)

	# For "all" section, add counts instead of potentially huge data
	if section == "all" and not name_filter.is_empty():
		# Already filtered, counts are implicit in array sizes
		pass

	return result


func _extract_tag_content(xml_text: String, tag: String) -> String:
	var open := "<%s>" % tag
	var close := "</%s>" % tag
	var start := xml_text.find(open)
	if start == -1:
		return ""
	start += open.length()
	var end := xml_text.find(close, start)
	if end == -1:
		return ""
	return _strip_bbcode(xml_text.substr(start, end - start).strip_edges())


func _extract_methods(xml_text: String, name_filter: String, with_desc: bool) -> Array:
	var methods_start := xml_text.find("<methods>")
	var methods_end := xml_text.find("</methods>")
	if methods_start == -1 or methods_end == -1:
		return []
	var methods_block := xml_text.substr(methods_start, methods_end - methods_start)

	var results: Array = []
	var method_re := RegEx.new()
	method_re.compile('<method name="([^"]*)"[^>]*>')
	var matches := method_re.search_all(methods_block)

	for m in matches:
		var mname: String = m.get_string(1)
		if not name_filter.is_empty() and mname.to_lower().find(name_filter) == -1:
			continue

		# Find this method's full block
		var block_start: int = m.get_start()
		var block_end: int = methods_block.find("</method>", block_start)
		if block_end == -1:
			continue
		var block: String = methods_block.substr(block_start, block_end - block_start)

		var entry: Dictionary = {"name": mname}

		# Return type
		var ret_re := RegEx.new()
		ret_re.compile('<return type="([^"]*)"')
		var ret := ret_re.search(block)
		if ret:
			entry["return"] = ret.get_string(1)

		# Parameters
		var param_re := RegEx.new()
		param_re.compile('<param index="\\d+" name="([^"]*)" type="([^"]*)"(?:\\s+default="([^"]*)")?')
		var params := param_re.search_all(block)
		if not params.is_empty():
			var args: Array = []
			for p in params:
				var arg: Dictionary = {"name": p.get_string(1), "type": p.get_string(2)}
				var def_val := p.get_string(3)
				if not def_val.is_empty():
					arg["default"] = def_val
				args.append(arg)
			entry["args"] = args

		# Description
		if with_desc:
			var desc := _extract_tag_content(block, "description")
			if not desc.is_empty():
				entry["description"] = desc

		results.append(entry)
		if results.size() >= 30:
			break

	return results


func _extract_members(xml_text: String, name_filter: String, with_desc: bool) -> Array:
	var members_start := xml_text.find("<members>")
	var members_end := xml_text.find("</members>")
	if members_start == -1 or members_end == -1:
		return []
	var members_block := xml_text.substr(members_start, members_end - members_start)

	var results: Array = []
	var member_re := RegEx.new()
	member_re.compile('<member name="([^"]*)" type="([^"]*)"[^>]*>')
	var matches := member_re.search_all(members_block)

	for m in matches:
		var mname: String = m.get_string(1)
		if not name_filter.is_empty() and mname.to_lower().find(name_filter) == -1:
			continue

		var entry: Dictionary = {"name": mname, "type": m.get_string(2)}

		# Extract default value
		var full_tag := members_block.substr(m.get_start(), m.get_end() - m.get_start())
		var def_re := RegEx.new()
		def_re.compile('default="([^"]*)"')
		var def_match := def_re.search(full_tag)
		if def_match:
			entry["default"] = def_match.get_string(1)

		# Description (text content between <member ...> and </member> or next <member)
		if with_desc:
			var content_start: int = m.get_end()
			var content_end: int = members_block.find("</member>", content_start)
			if content_end == -1:
				content_end = members_block.find("<member ", content_start)
			if content_end != -1:
				var desc := _strip_bbcode(members_block.substr(content_start, content_end - content_start).strip_edges())
				if not desc.is_empty():
					entry["description"] = desc

		results.append(entry)
		if results.size() >= 40:
			break

	return results


func _extract_signals(xml_text: String, name_filter: String, with_desc: bool) -> Array:
	var signals_start := xml_text.find("<signals>")
	var signals_end := xml_text.find("</signals>")
	if signals_start == -1 or signals_end == -1:
		return []
	var signals_block := xml_text.substr(signals_start, signals_end - signals_start)

	var results: Array = []
	var signal_re := RegEx.new()
	signal_re.compile('<signal name="([^"]*)">')
	var matches := signal_re.search_all(signals_block)

	for m in matches:
		var sname: String = m.get_string(1)
		if not name_filter.is_empty() and sname.to_lower().find(name_filter) == -1:
			continue

		var block_start: int = m.get_start()
		var block_end: int = signals_block.find("</signal>", block_start)
		if block_end == -1:
			continue
		var block: String = signals_block.substr(block_start, block_end - block_start)

		var entry: Dictionary = {"name": sname}

		# Parameters
		var param_re := RegEx.new()
		param_re.compile('<param index="\\d+" name="([^"]*)" type="([^"]*)"')
		var params := param_re.search_all(block)
		if not params.is_empty():
			var args: Array = []
			for p in params:
				args.append({"name": p.get_string(1), "type": p.get_string(2)})
			entry["args"] = args

		if with_desc:
			var desc := _extract_tag_content(block, "description")
			if not desc.is_empty():
				entry["description"] = desc

		results.append(entry)

	return results


func _extract_constants(xml_text: String, name_filter: String) -> Array:
	var constants_start := xml_text.find("<constants>")
	var constants_end := xml_text.find("</constants>")
	if constants_start == -1 or constants_end == -1:
		return []
	var constants_block := xml_text.substr(constants_start, constants_end - constants_start)

	var results: Array = []
	var const_re := RegEx.new()
	const_re.compile('<constant name="([^"]*)" value="([^"]*)"(?:\\s+enum="([^"]*)")?')
	var matches := const_re.search_all(constants_block)

	for m in matches:
		var cname: String = m.get_string(1)
		if not name_filter.is_empty() and cname.to_lower().find(name_filter) == -1:
			continue
		var entry: Dictionary = {"name": cname, "value": m.get_string(2)}
		var enum_name := m.get_string(3)
		if not enum_name.is_empty():
			entry["enum"] = enum_name
		results.append(entry)
		if results.size() >= 50:
			break

	return results


func _strip_bbcode(text: String) -> String:
	if text.is_empty():
		return text
	# Strip code example blocks entirely (very bulky, rarely useful in context)
	var codeblock_re := RegEx.new()
	codeblock_re.compile("\\[codeblocks\\][\\s\\S]*?\\[/codeblocks\\]")
	text = codeblock_re.sub(text, "", true)
	# [code]x[/code] → `x`
	var code_re := RegEx.new()
	code_re.compile("\\[code\\](.*?)\\[/code\\]")
	text = code_re.sub(text, "`$1`", true)
	# [method name] → name()
	var method_re := RegEx.new()
	method_re.compile("\\[method ([^\\]]+)\\]")
	text = method_re.sub(text, "$1()", true)
	# [member name] → name
	var member_re := RegEx.new()
	member_re.compile("\\[member ([^\\]]+)\\]")
	text = member_re.sub(text, "$1", true)
	# [param x] → x
	var param_re := RegEx.new()
	param_re.compile("\\[param ([^\\]]+)\\]")
	text = param_re.sub(text, "$1", true)
	# [signal name] → name
	var signal_re := RegEx.new()
	signal_re.compile("\\[signal ([^\\]]+)\\]")
	text = signal_re.sub(text, "$1", true)
	# [constant name] → name
	var constant_re := RegEx.new()
	constant_re.compile("\\[constant ([^\\]]+)\\]")
	text = constant_re.sub(text, "$1", true)
	# [enum name] → name
	var enum_re := RegEx.new()
	enum_re.compile("\\[enum ([^\\]]+)\\]")
	text = enum_re.sub(text, "$1", true)
	# [ClassName] → ClassName
	var class_re := RegEx.new()
	class_re.compile("\\[([A-Z][A-Za-z0-9_]+)\\]")
	text = class_re.sub(text, "$1", true)
	# [b]...[/b], [i]...[/i], [url]...[/url] → strip tags
	var tag_re := RegEx.new()
	tag_re.compile("\\[/?(?:b|i|url|center|br|codeblock|gdscript|csharp)\\]")
	text = tag_re.sub(text, "", true)
	# [url=...]text[/url] → text
	var url_re := RegEx.new()
	url_re.compile("\\[url=[^\\]]*\\]")
	text = url_re.sub(text, "", true)
	# Collapse multiple newlines
	var nl_re := RegEx.new()
	nl_re.compile("\\n{3,}")
	text = nl_re.sub(text, "\n\n", true)
	return text.strip_edges()


# =============================================================================
# search_godot_docs  —  Tier 3: full-text search for tutorials & guides
# =============================================================================

func search_godot_docs(args: Dictionary) -> Dictionary:
	var query: String = str(args.get("query", "")).strip_edges()
	var use_regex: bool = bool(args.get("regex", false))
	var force_online: bool = bool(args.get("force_online", false))
	var max_results: int = int(args.get("max_results", DEFAULT_MAX_RESULTS))
	if query.is_empty():
		return {"ok": false, "error": "Missing query"}

	var has_local_docs = false
	var root_dir = ProjectSettings.globalize_path(DOCS_ROOT)
	if DirAccess.dir_exists_absolute(root_dir):
		var dir = DirAccess.open(root_dir)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if not file_name.begins_with(".") and not file_name.ends_with(".zip"):
					has_local_docs = true
					break
				file_name = dir.get_next()
			dir.list_dir_end()

	if force_online or not has_local_docs:
		var search_url = "https://docs.godotengine.org/_/api/v2/search/?q=" + query.uri_encode() + "&project=godot&version=stable&language=en"
		var http = HTTPRequest.new()
		add_child(http)
		var err = http.request(search_url)
		if err != OK:
			http.queue_free()
			return {"ok": false, "error": "Failed to connect to Godot docs API."}

		var response = await http.request_completed
		http.queue_free()

		if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
			return {"ok": false, "error": "Failed to fetch online docs. HTTP Code: " + str(response[1])}

		var body_str = (response[3] as PackedByteArray).get_string_from_utf8()
		var json = JSON.parse_string(body_str)
		if not json is Dictionary or not json.has("results"):
			return {"ok": false, "error": "Invalid JSON response from ReadTheDocs."}

		var hits: Array = []
		var seen_paths: Dictionary = {}
		var results = json.get("results", [])
		for page in results:
			if hits.size() >= max_results:
				break
			var title: String = page.get("title", "")
			var path: String = page.get("path", "")
			# Deduplicate: one entry per page, pick the best block
			if seen_paths.has(path):
				continue
			seen_paths[path] = true
			var best_snippet := ""
			for block in page.get("blocks", []):
				var content: String = block.get("content", "")
				if content.length() > best_snippet.length():
					best_snippet = content
			hits.append({
				"title": title,
				"url": "https://docs.godotengine.org" + path,
				"snippet": best_snippet.left(250),
			})

		return {
			"ok": true,
			"query": query,
			"source": "online",
			"matches": hits,
			"count": hits.size(),
			"truncated": hits.size() >= max_results
		}

	var matcher: RegEx = null
	if use_regex:
		matcher = RegEx.new()
		var err := matcher.compile(query)
		if err != OK:
			return {"ok": false, "error": "Invalid regex query"}

	var files: PackedStringArray = []
	_collect_doc_files(DOCS_ROOT, files)

	var hits: Array = []
	for path: String in files:
		if hits.size() >= max_results:
			break
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var line_index := 0
		while not file.eof_reached() and hits.size() < max_results:
			var line := file.get_line()
			line_index += 1
			if _line_matches(line, query, use_regex, matcher):
				hits.append({
					"file": path,
					"line": line_index,
					"snippet": line.strip_edges(),
				})
		file.close()

	return {
		"ok": true,
		"query": query,
		"matches": hits,
		"count": hits.size(),
		"truncated": hits.size() >= max_results,
	}

func _line_matches(line: String, query: String, use_regex: bool, matcher: RegEx) -> bool:
	if use_regex:
		return matcher.search(line) != null
	return line.to_lower().find(query.to_lower()) != -1

func _collect_doc_files(path: String, out: PackedStringArray) -> void:
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
			_collect_doc_files(full, out)
		else:
			if name.ends_with(".rst") or name.ends_with(".md") or name.ends_with(".txt"):
				out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
