@tool
extends SceneTree
## Exercises the structured probe/assert helpers with a real Control tree.
##
## The point of these tools is that they replace screenshots with numbers, so
## the numbers have to be right: this checks the geometry, the overlap
## detection, and the assertion verdicts against a scene built in code.

const Runtime = preload("res://addons/godot_mcp/runtime/mcp_runtime.gd")

var rt: Node
var label: Label
var button: Button
var panel: Panel
var ui_root_ref: Control

func _make_ui() -> void:
	var ui_root := Control.new()
	ui_root.name = "UI"
	ui_root_ref = ui_root

	label = Label.new()
	label.name = "Score"
	label.text = "Score: 100"
	label.position = Vector2(20, 20)
	label.size = Vector2(200, 30)
	ui_root.add_child(label)

	button = Button.new()
	button.name = "StartButton"
	button.text = "Start"
	button.position = Vector2(20, 60)
	button.size = Vector2(120, 40)
	ui_root.add_child(button)

	# Deliberately overlaps the button so the overlap detector has something
	# real to find — this is the bug a screenshot usually hides.
	panel = Panel.new()
	panel.name = "OverlappingPanel"
	panel.position = Vector2(100, 70)
	panel.size = Vector2(150, 50)
	ui_root.add_child(panel)

	# Far off-screen, to check the on_screen filter.
	var offscreen := Panel.new()
	offscreen.name = "Offscreen"
	offscreen.position = Vector2(9000, 9000)
	offscreen.size = Vector2(50, 50)
	ui_root.add_child(offscreen)

	get_root().add_child(ui_root)

var _done := false

## The tree is not wired up during _init (the root Window has no SceneTree
## yet), so the work runs on the first _process tick instead.
##
## Exit-code plumbing, verified empirically because getting it wrong makes CI
## silently green on a failing suite:
##   - quit(code) sets the process exit code; a bare quit() resets it to 0.
##   - The re-entry guard must `return true` — returning false there lets quit()
##     end the loop with 0 and discards the code.
## The body returns false so quit() is what ends the run.
func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run_checks()
	quit(1 if _failures > 0 else 0)
	return false

var _failures := 0

func _run_checks() -> void:
	rt = Runtime.new()
	rt.name = "MCPRuntime"
	# Attached so get_tree() resolves; the helpers under test only need a tree
	# and a viewport, and a headless SceneTree provides both.
	get_root().add_child(rt)
	# A headless root Window has no meaningful size, which would leave the
	# on-screen filter with nothing to compare against.
	get_root().size = Vector2i(1280, 720)
	_make_ui()

	var failed := 0

	# --- _read_text ----------------------------------------------------
	var t = rt._read_text(label)
	if t != "Score: 100":
		print("FAIL  _read_text(Label) = %s" % t); failed += 1
	else:
		print("ok    _read_text reads a Label")
	if rt._read_text(panel) != null:
		print("FAIL  _read_text on a non-text node should be null"); failed += 1
	else:
		print("ok    _read_text returns null for a Panel")

	# --- assertion verdicts ---------------------------------------------
	var cases := [
		[{"kind": "node_exists", "node_path": "UI/Score"}, true, "node_exists hit"],
		[{"kind": "node_exists", "node_path": "UI/Nope"}, false, "node_exists miss"],
		[{"kind": "node_visible", "node_path": "UI/StartButton", "visible": true}, true, "node_visible"],
		[{"kind": "node_visible", "node_path": "UI/Nope", "visible": true}, false, "node_visible missing node"],
		[{"kind": "text_matches", "node_path": "UI/Score", "text": "100"}, true, "text_matches contains"],
		[{"kind": "text_matches", "node_path": "UI/Score", "text": "999"}, false, "text_matches absent"],
		[{"kind": "text_matches", "node_path": "UI/StartButton", "text": "Start", "contains": false}, true, "text_matches exact"],
		[{"kind": "property_equals", "node_path": "UI/Score", "property": "visible", "value": true}, true, "property_equals"],
		[{"kind": "property_equals", "node_path": "UI/Score", "property": "visible", "value": false}, false, "property_equals mismatch"],
		[{"kind": "group_count", "group": "nothing_here", "equals": 0}, true, "group_count empty"],
		[{"kind": "no_errors", "max": 0}, true, "no_errors"],
		[{"kind": "bogus_kind"}, false, "unknown kind fails without crashing"],
		[{"kind": "rect_contains_point", "node_path": "UI/Score", "point": {"x": 30, "y": 25}}, true, "rect_contains_point inside"],
		[{"kind": "rect_contains_point", "node_path": "UI/Score", "point": {"x": 5000, "y": 5000}}, false, "rect_contains_point outside"],
	]
	for c in cases:
		var r = rt._run_assertion(c[0])
		var got = bool(r.get("passed", false))
		if got != c[1]:
			print("FAIL  %s: passed=%s expected=%s (%s)" % [c[2], got, c[1], r])
			failed += 1
		else:
			print("ok    %s" % c[2])

	# A failure must carry evidence, not just a boolean.
	var ev = rt._run_assertion({"kind": "text_matches", "node_path": "UI/Score", "text": "999"})
	if not ev.has("actual") or not ev.has("expected"):
		print("FAIL  failed assertion missing actual/expected: %s" % ev); failed += 1
	else:
		print("ok    failed assertion reports actual/expected")

	# Every check must evaluate, even after an earlier failure.
	var multi = rt._assert_runtime({"checks": [
		{"kind": "node_exists", "node_path": "UI/Score"},
		{"kind": "node_exists", "node_path": "UI/Nope"},
		{"kind": "node_exists", "node_path": "UI/StartButton"},
	]})
	if int(multi.get("total", 0)) != 3 or int(multi.get("passed", 0)) != 2 or int(multi.get("failed", 0)) != 1:
		print("FAIL  batch counts wrong: %s" % multi); failed += 1
	elif bool(multi.get("all_passed", true)):
		print("FAIL  all_passed should be false when one fails"); failed += 1
	else:
		print("ok    batch reports per-check counts and all_passed")

	# Empty input must be a clear error, not a crash.
	var empty = rt._assert_runtime({})
	if bool(empty.get("ok", true)):
		print("FAIL  empty checks should error"); failed += 1
	else:
		print("ok    empty checks returns a clear error")

	# --- probe_ui: the geometry has to be right ------------------------
	# The UI root is parented to the tree root, so give it a real rect first.
	ui_root_ref.size = Vector2(1280, 720)

	var probe = rt._probe_ui({"max_controls": 50})
	if not bool(probe.get("ok", false)):
		print("FAIL  probe_ui errored: %s" % probe); failed += 1
	else:
		var controls: Array = probe.get("controls", [])
		# Index by the trailing "UI/<Name>" so the test does not depend on
		# whether Godot reports an absolute or relative path here.
		var by_name := {}
		for c in controls:
			var p := str(c.get("path", ""))
			by_name[p.substr(p.rfind("UI/"))] = c

		# Off-screen controls are excluded by default — that is the point, the
		# agent asked what is on screen. include_hidden must bring them back.
		var off = by_name.get("UI/Offscreen")
		if off != null:
			print("FAIL  probe_ui included an off-screen control by default"); failed += 1
		else:
			print("ok    probe_ui excludes off-screen controls by default")

		var with_hidden = rt._probe_ui({"include_hidden": true})
		var hidden_by_name := {}
		for c in with_hidden.get("controls", []):
			var p2 := str(c.get("path", ""))
			hidden_by_name[p2.substr(p2.rfind("UI/"))] = c
		var off2 = hidden_by_name.get("UI/Offscreen")
		if off2 == null:
			print("FAIL  include_hidden did not surface the off-screen control"); failed += 1
		elif bool(off2.get("on_screen", true)):
			print("FAIL  off-screen control flagged on_screen=true"); failed += 1
		else:
			print("ok    include_hidden surfaces off-screen controls, flagged not-on-screen")

		# Rects must be exact, not approximate — that is the whole point.
		var sc = by_name.get("UI/Score")
		if sc == null:
			print("FAIL  probe_ui missed the Score label (saw %s)" % by_name.keys()); failed += 1
		else:
			var r: Dictionary = sc.get("rect", {})
			if absf(float(r.get("x", -1)) - 20.0) > 0.5 or absf(float(r.get("width", -1)) - 200.0) > 0.5:
				print("FAIL  probe_ui rect is wrong: %s" % r); failed += 1
			else:
				print("ok    probe_ui reports exact rects")

		# The overlap between StartButton and OverlappingPanel is the bug a
		# screenshot usually hides. This is what makes the probe worth having.
		var overlaps: Array = probe.get("overlaps", [])
		var found_overlap := false
		for o in overlaps:
			var pair := "%s|%s" % [o.get("a", ""), o.get("b", "")]
			if pair.find("StartButton") != -1 and pair.find("OverlappingPanel") != -1:
				found_overlap = true
		if not found_overlap:
			print("FAIL  probe_ui missed the StartButton/OverlappingPanel overlap (got %s)" % overlaps); failed += 1
		else:
			print("ok    probe_ui detects overlapping Controls")

		# max_controls must be honoured, not just accepted.
		var capped = rt._probe_ui({"max_controls": 2})
		if (capped.get("controls", []) as Array).size() > 2:
			print("FAIL  max_controls not honoured: %s" % (capped.get("controls", []) as Array).size()); failed += 1
		else:
			print("ok    probe_ui honours max_controls")

	print("\n%d failures" % failed)
	# Assign at the END, not at declaration: GDScript ints are value types, so
	# copying here would capture 0 and the suite could never fail CI.
	_failures = failed
