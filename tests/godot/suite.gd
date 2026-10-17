extends Node
## Test suite for the godot_mcp plugin: property writing, scene tools and the
## runtime helper. Runs in two modes (see run.sh):
##   game mode    run_tests.gd    (scripts are real instances)
##   editor mode  editor_runner/  (inside the editor: placeholder scripts,
##                                 real EditorPlugin, filesystem rescans)

const PW = preload("res://addons/godot_mcp/utils/property_writer.gd")
const TMP := "res://_tmp"
const ICON := "res://fixtures/icon.png"
const SHARED_MAT := "res://fixtures/shared_material.tres"
const PLAYER_GD := "res://fixtures/player.gd"

var editor_plugin: EditorPlugin = null  # set by the editor runner
var _passed := 0
var _failed: Array = []
var st: Node  # SceneTools


## Runs every test_* method. Returns {passed, failed: [labels]}.
func run_all() -> Dictionary:
	DirAccess.make_dir_recursive_absolute(TMP)
	st = load("res://addons/godot_mcp/tools/scene_tools.gd").new()
	add_child(st)
	if editor_plugin != null:
		st.set_editor_plugin(editor_plugin)
	for m in get_method_list():
		var n := str(m.name)
		if n.begins_with("test_"):
			call(n)
	st.queue_free()
	_cleanup(TMP)
	return {"passed": _passed, "failed": _failed}


# --- helpers -----------------------------------------------------------------

func check(cond: bool, label: String, detail: Variant = "") -> void:
	if cond:
		_passed += 1
	else:
		_failed.append("%s %s" % [label, str(detail)])


func has_error(r: Dictionary, needle: String) -> bool:
	var parts: Array = [str(r.get("error", ""))]
	parts.append_array(r.get("errors", []))
	parts.append_array(r.get("validation_errors", []))
	return "\n".join(parts).contains(needle)


func load_fresh(path: String) -> Node:
	var packed: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	return packed.instantiate() if packed else null


func make_scene(name: String, root_type: String, nodes: Array = []) -> String:
	var path := "%s/%s.tscn" % [TMP, name]
	var r: Dictionary = st.create_scene({"scene_path": path, "root_node_type": root_type, "nodes": nodes})
	check(r.ok, "make_scene %s" % name, r)
	return path


func _cleanup(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	for d in dir.get_directories():
		_cleanup(path + "/" + d)
	DirAccess.remove_absolute(path)


# --- PropertyWriter: resources -----------------------------------------------

func test_texture_from_path_string() -> void:
	var s := Sprite2D.new()
	var r := PW.write(s, {"texture": ICON})
	check(r.ok and s.texture is Texture2D, "texture from path string", r)
	s.free()


func test_texture_resource_dict_and_alias_key() -> void:
	var s := Sprite2D.new()
	var r := PW.write(s, {"texture": {"type": "Resource", "path": ICON}})
	check(r.ok and s.texture is Texture2D, "texture from {type:Resource,path}", r)
	var s2 := Sprite2D.new()
	r = PW.write(s2, {"texture": {"type": "Texture2D", "path": ICON}})
	check(r.ok and s2.texture is Texture2D, "texture from {type:Texture2D,path}", r)
	s.free()
	s2.free()


func test_inline_resources() -> void:
	var s := Sprite2D.new()
	var r := PW.write(s, {"texture": {"type": "GradientTexture2D", "width": 16, "height": 8}})
	check(r.ok and s.texture is GradientTexture2D and s.texture.get_width() == 16, "inline GradientTexture2D", r)
	var c := CollisionShape2D.new()
	r = PW.write(c, {"shape": {"type": "RectangleShape2D", "size": {"x": 10, "y": 20}}})
	check(r.ok and c.shape is RectangleShape2D and c.shape.size == Vector2(10, 20), "inline RectangleShape2D", r)
	s.free()
	c.free()


func test_resource_class_mismatch() -> void:
	var m := MeshInstance3D.new()
	var r := PW.write(m, {"mesh": ICON})
	check(not r.ok and has_error(r, "expects Mesh"), "png into mesh is rejected", r)
	check(m.mesh == null, "nothing written on mismatch")
	r = PW.write(m, {"mesh": {"type": "RectangleShape2D"}})
	check(not r.ok and has_error(r, "expects Mesh"), "wrong inline class rejected", r)
	var c := CollisionShape2D.new()
	r = PW.write(c, {"shape": {"type": "Shape2D"}})
	check(not r.ok and has_error(r, "abstract"), "abstract class explained", r)
	c.free()
	r = PW.write(m, {"mesh": "res://fixtures/missing.png"})
	check(not r.ok and has_error(r, "no resource at"), "missing file explained", r)
	m.free()


func test_unknown_property_suggests() -> void:
	var s := Sprite2D.new()
	var r := PW.write(s, {"texure": ICON, "position": {"x": 1, "y": 2}})
	check(not r.ok and has_error(r, "did you mean 'texture'"), "unknown property suggests", r)
	check(s.position == Vector2.ZERO, "no partial write when one key is bad")
	s.free()


func test_inline_resource_bad_nested_key() -> void:
	var c := CollisionShape2D.new()
	var r := PW.write(c, {"shape": {"type": "RectangleShape2D", "extents": {"x": 1, "y": 1}}})
	check(not r.ok and has_error(r, "properties.shape.extents"), "nested key error is path-pointed", r)
	c.free()


# --- PropertyWriter: type-directed decoding ----------------------------------

func test_string_property_keeps_res_path() -> void:
	var b := CharacterBody2D.new()
	b.set_script(load(PLAYER_GD))
	var r := PW.write(b, {"next_level": "res://levels/level2.tscn", "speed": 250})
	check(r.ok and b.get("next_level") == "res://levels/level2.tscn", "String prop keeps res:// text", r)
	check(is_equal_approx(b.get("speed"), 250.0), "script export float", b.get("speed"))
	b.free()


func test_enum_by_name_and_int_checks() -> void:
	var s := Sprite2D.new()
	var r := PW.write(s, {"texture_filter": "Nearest"})
	check(r.ok and s.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "enum by label", r)
	r = PW.write(s, {"texture_filter": "TEXTURE_FILTER_LINEAR"})
	check(r.ok and s.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR, "enum by constant name", r)
	r = PW.write(s, {"texture_filter": "Blurry"})
	check(not r.ok and has_error(r, "Valid:"), "bad enum lists options", r)
	r = PW.write(s, {"hframes": 1.5})
	check(not r.ok and has_error(r, "expects an integer"), "non-integral int rejected", r)
	r = PW.write(s, {"hframes": 4.0})
	check(r.ok and s.hframes == 4, "integral float accepted for int", r)
	s.free()


func test_struct_strictness() -> void:
	var n := Node3D.new()
	var r := PW.write(n, {"position": {"x": 1, "y": 2}})
	check(not r.ok and has_error(r, "missing 'z'"), "Vector3 missing z", r)
	r = PW.write(n, {"position": {"type": "Vector2", "x": 1, "y": 2, "z": 3}})
	check(not r.ok and has_error(r, "expects Vector3"), "wrong discriminator", r)
	r = PW.write(n, {"position": [1, 2, 3]})
	check(r.ok and n.position == Vector3(1, 2, 3), "Vector3 from array", r)
	var c := ColorRect.new()
	r = PW.write(c, {"color": "#ff0000"})
	check(r.ok and c.color.is_equal_approx(Color.RED), "Color from hex", r)
	r = PW.write(c, {"color": "blue"})
	check(r.ok and c.color.is_equal_approx(Color.BLUE), "Color from name", r)
	r = PW.write(c, {"color": "not-a-color"})
	check(not r.ok, "bad color rejected", r)
	n.free()
	c.free()


func test_label_text_from_number() -> void:
	var l := Label.new()
	var r := PW.write(l, {"text": 5})
	check(r.ok and l.text == "5", "JSON 5 -> \"5\" not \"5.0\"", l.text)
	l.free()


func test_property_order() -> void:
	var s := Sprite2D.new()
	var r := PW.write(s, {"frame": 3, "hframes": 4})
	check(r.ok and s.frame == 3, "frame applied after hframes", r)
	s.free()


func test_typed_array_of_resources() -> void:
	var b := CharacterBody2D.new()
	b.set_script(load(PLAYER_GD))
	var r := PW.write(b, {"items": [ICON, {"type": "GradientTexture2D"}]})
	var items: Array = b.get("items")
	check(r.ok and items.size() == 2 and items[0] is Texture2D and items.is_typed(), "typed Array[Texture2D]", r)
	r = PW.write(b, {"items": [{"type": "BoxMesh"}]})
	check(not r.ok and has_error(r, "items[0]"), "wrong element class pointed at index", r)
	b.free()


func test_setter_adjusted_and_ignored() -> void:
	# Game mode only: in the editor, non-@tool scripts are placeholders
	# (setters don't run) and the runtime helper only exists in a running game.
	if editor_plugin != null:
		return
	var b := CharacterBody2D.new()
	b.set_script(load(PLAYER_GD))
	var r := PW.write(b, {"clamped": 50})
	check(r.ok and r.adjusted.size() == 1 and b.get("clamped") == 10, "clamping setter reported as adjusted", r)
	r = PW.write(b, {"locked": 7})
	check(not r.ok and has_error(r, "ignored the write"), "ignoring setter is an error", r)
	b.free()


func test_node_reference_explained() -> void:
	var b := CharacterBody2D.new()
	b.set_script(load(PLAYER_GD))
	var r := PW.write(b, {"target": "Enemy"})
	check(not r.ok and has_error(r, "references a node"), "node references explained", r)
	b.free()


func test_colon_paths() -> void:
	var m := MeshInstance3D.new()
	var r := PW.write(m, {
		"material_override:albedo_color": {"r": 1, "g": 0, "b": 0},
		"material_override": {"type": "StandardMaterial3D"},
	})
	check(r.ok and m.material_override is StandardMaterial3D and m.material_override.albedo_color.is_equal_approx(Color.RED),
		"colon path into a resource assigned in the same call", r)
	r = PW.write(m, {"material_override:metallic": 0.5})
	check(r.ok and is_equal_approx(m.material_override.metallic, 0.5), "colon path into existing resource", r)
	var m2 := MeshInstance3D.new()
	r = PW.write(m2, {"material_override": SHARED_MAT})
	check(r.ok, "assign shared material file", r)
	r = PW.write(m2, {"material_override:albedo_color": "red"})
	check(not r.ok and has_error(r, "shared resource file"), "editing a shared .tres via colon path refused", r)
	r = PW.write(m2, {"mesh:size": {"x": 1, "y": 1, "z": 1}})
	check(not r.ok and has_error(r, "not a resource"), "colon path through null explained", r)
	m.free()
	m2.free()


func test_decode_call_args() -> void:
	var s := Sprite2D.new()
	var d := PW.decode_call_args(s, "set_texture", [ICON])
	check(d.errors.is_empty() and d.args[0] is Texture2D, "set_texture arg decoded by signature", d)
	d = PW.decode_call_args(s, "set", ["texture", {"type": "Resource", "path": ICON}])
	check(d.errors.is_empty() and d.args[1] is Texture2D, "set(prop, value) decoded by property type", d)
	d = PW.decode_call_args(s, "set", ["texure", ICON])
	check(not d.errors.is_empty() and "\n".join(d.errors).contains("did you mean"), "set() with bad property name", d)
	d = PW.decode_call_args(s, "set_position", [{"x": 1}])
	check(not d.errors.is_empty(), "bad Vector2 arg rejected", d)
	s.free()


# --- Scene tools ---------------------------------------------------------------

func test_create_scene_with_texture_and_shape() -> void:
	var path := make_scene("level", "Node2D", [
		{"name": "Hero", "type": "Sprite2D", "properties": {"texture": ICON, "position": {"x": 5, "y": 6}}},
		{"name": "Body", "type": "StaticBody2D", "children": [
			{"name": "Col", "type": "CollisionShape2D", "properties": {"shape": {"type": "CircleShape2D", "radius": 12}}},
		]},
	])
	var root := load_fresh(path)
	check(root != null and root.name == "Level", "root name derived from file name", root.name if root else null)
	check(root.get_node("Hero").texture is Texture2D, "texture persisted to .tscn (feedback #1)")
	check(root.get_node("Body/Col").shape is CircleShape2D and is_equal_approx(root.get_node("Body/Col").shape.radius, 12.0), "inline shape persisted")
	root.free()


func test_create_scene_rejects_everything_up_front() -> void:
	var path := "%s/bad.tscn" % TMP
	var r: Dictionary = st.create_scene({"scene_path": path, "root_node_type": "Node2D", "nodes": [
		{"name": "A", "type": "Sprite2D", "properties": {"texture": "res://nope.png"}},
		{"name": "B", "type": "Sprit2D"},
		{"name": "C", "type": "Node2D", "parent": "A"},
	]})
	check(not r.ok and r.validation_errors.size() == 3, "all three problems reported at once", r)
	check(not FileAccess.file_exists(path), "no file written on failure")
	check(has_error(r, "did you mean 'Sprite2D'"), "class name suggestion", r)


func test_add_node_children_and_unknown_key() -> void:
	var path := make_scene("add", "Node2D")
	var r: Dictionary = st.add_node({"scene_path": path, "node_name": "Light", "node_type": "PointLight2D",
		"properties": {"texture": ICON, "energy": 2}, "children": [{"name": "Glow", "type": "Sprite2D", "properties": {"texture": ICON}}]})
	check(r.ok and r.node_path == "Light", "add_node with texture + children", r)
	var root := load_fresh(path)
	check(root.get_node("Light").texture is Texture2D and root.get_node("Light/Glow").texture is Texture2D, "light texture persisted")
	root.free()
	r = st.add_node({"scene_path": path, "node_name": "X", "node_type": "Node2D", "children": [{"name": "Y", "type": "Node2D", "parent_path": "."}]})
	check(not r.ok and has_error(r, "unknown key 'parent_path'"), "unknown child key", r)


func test_set_node_properties_saves_only_when_all_ok() -> void:
	var path := make_scene("props", "Node2D", [{"name": "S", "type": "Sprite2D"}])
	var r: Dictionary = st.set_node_properties({"scene_path": path, "node_path": "S", "properties": {"position": {"x": 3, "y": 4}, "texture": "res://nope.png"}})
	check(not r.ok, "bad texture fails the call", r)
	var root := load_fresh(path)
	check(root.get_node("S").position == Vector2.ZERO, "nothing saved when one property fails")
	root.free()
	r = st.set_node_properties({"scene_path": path, "node_path": "S", "properties": {"position": {"x": 3, "y": 4}, "texture": ICON, "material": {"type": "CanvasItemMaterial"}, "material:blend_mode": "Add"}})
	check(r.ok, "texture + inline material + colon path", r)
	root = load_fresh(path)
	check(root.get_node("S").material.blend_mode == CanvasItemMaterial.BLEND_MODE_ADD, "colon path persisted")
	root.free()


func test_legacy_resource_tools() -> void:
	var path := make_scene("legacy", "Node3D", [
		{"name": "Mesh", "type": "MeshInstance3D"},
		{"name": "Col", "type": "CollisionShape3D"},
		{"name": "Light", "type": "OmniLight3D"},
		{"name": "Plain", "type": "Node3D"},
	])
	var r: Dictionary = st.set_mesh({"scene_path": path, "node_path": "Mesh", "mesh_type": "BoxMesh", "mesh_params": {"size": {"x": 2, "y": 2, "z": 2}}})
	check(r.ok, "set_mesh BoxMesh", r)
	r = st.set_material({"scene_path": path, "node_path": "Mesh", "material_type": "StandardMaterial3D", "material_params": {"albedo_color": {"r": 0, "g": 0, "b": 1}, "emission": {"r": 1, "g": 1, "b": 0}, "emission_energy": 2}})
	check(r.ok and str(r.message).contains("material_override"), "set_material legacy params", r)
	r = st.set_collision_shape({"scene_path": path, "node_path": "Col", "shape_type": "SphereShape3D", "shape_params": {"radius": 3}})
	check(r.ok, "set_collision_shape", r)
	r = st.set_collision_shape({"scene_path": path, "node_path": "Col", "shape_type": "BoxShape3D", "shape_params": {"extents": {"x": 1, "y": 1, "z": 1}}})
	check(not r.ok and has_error(r, "extents"), "set_collision_shape rejects unknown shape param", r)
	r = st.set_sprite_texture({"scene_path": path, "node_path": "Light", "texture_type": "FromPath", "texture_params": {"path": ICON}})
	check(not r.ok and has_error(r, "'texture' is not a property of Light"), "set_sprite_texture on a node without texture errors", r)
	r = st.set_resource_property({"scene_path": path, "node_path": "Col", "resource_path": "shape", "property_name": "radius", "value": 4})
	check(r.ok, "set_resource_property via colon path", r)
	r = st.modify_node_property({"scene_path": path, "node_path": "Plain", "property_name": "position", "value": {"type": "Vector3", "x": 1, "y": 2, "z": 3}})
	check(r.ok and r.new_value.x == 1.0, "modify_node_property", r)
	var root := load_fresh(path)
	var mat: StandardMaterial3D = root.get_node("Mesh").material_override
	check(mat.emission_enabled and is_equal_approx(mat.emission_energy_multiplier, 2.0), "legacy emission params mapped")
	check(is_equal_approx(root.get_node("Col").shape.radius, 4.0), "resource property persisted")
	root.free()
	var path2 := make_scene("light2d", "Node2D", [{"name": "L", "type": "PointLight2D"}])
	r = st.set_sprite_texture({"scene_path": path2, "node_path": "L", "texture_type": "GradientTexture2D", "texture_params": {}})
	check(r.ok and r.width == 64, "set_sprite_texture works on PointLight2D", r)


func test_set_node_properties_on_resource_file() -> void:
	var path := "%s/mat.tres" % TMP
	ResourceSaver.save(StandardMaterial3D.new(), path)
	var r: Dictionary = st.set_node_properties({"scene_path": path, "properties": {"albedo_color": "red", "metallic": 0.25}})
	check(r.ok, "set_node_properties on a .tres file", r)
	var mat: StandardMaterial3D = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	check(mat.albedo_color.is_equal_approx(Color.RED) and is_equal_approx(mat.metallic, 0.25), ".tres edit persisted")
	r = st.set_node_properties({"scene_path": path, "properties": {"albedo_colour": "red"}})
	check(not r.ok and has_error(r, "did you mean 'albedo_color'"), ".tres bad property", r)


func test_call_method_editor_mode_resource_arg() -> void:
	var path := make_scene("call", "Node2D", [{"name": "S", "type": "Sprite2D"}])
	var r: Dictionary = st.call_method({"scene_path": path, "node_path": "S", "method": "set_texture", "args": [ICON]})
	check(r.ok, "call_method set_texture with path", r)
	r = st.call_method({"scene_path": path, "node_path": "S", "method": "set", "args": ["modulate", "red"]})
	check(r.ok, "call_method set(prop, value)", r)
	var root := load_fresh(path)
	check(root.get_node("S").texture is Texture2D and root.get_node("S").modulate.is_equal_approx(Color.RED), "call_method changes persisted (feedback #2)")
	root.free()
	r = st.call_method({"scene_path": path, "node_path": "S", "method": "set_texture", "args": [{"type": "BoxMesh"}]})
	check(not r.ok and has_error(r, "expects Texture2D"), "call_method wrong arg type rejected", r)


func test_instance_scene_properties() -> void:
	var child := make_scene("enemy", "Node2D")
	var parent := make_scene("world", "Node2D")
	var r: Dictionary = st.instance_scene({"scene_path": parent, "instance_path": child, "properties": {"position": {"x": 9, "y": 9}}})
	check(r.ok, "instance_scene with properties", r)
	r = st.instance_scene({"scene_path": parent, "instance_path": child, "properties": {"positon": {"x": 9, "y": 9}}})
	check(not r.ok and has_error(r, "did you mean 'position'"), "instance_scene bad property", r)


# --- Runtime helper ------------------------------------------------------------

func test_runtime_query_and_input() -> void:
	# Game mode only: in the editor, non-@tool scripts are placeholders
	# (setters don't run) and the runtime helper only exists in a running game.
	if editor_plugin != null:
		return
	var rt: Node = load("res://runtime_harness.gd").new()
	add_child(rt)
	var hud := Label.new()
	hud.name = "HUD"
	hud.set_script(load("res://fixtures/hud.gd"))
	hud.text = "Score: 7"
	add_child(hud)

	var q: Dictionary = rt._query_runtime_node({"node_path": str(hud.get_path())})
	check(q.ok and q.mode == "changed" and q.properties.get("text") == "Score: 7", "changed mode includes Label text", q)
	check(q.properties.get("score") == 7, "changed mode includes script vars", q)
	q = rt._query_runtime_node({"node_path": str(hud.get_path()), "properties": ["txt"]})
	check(not q.ok and str(q.error).contains("did you mean 'text'"), "unknown query property suggests", q)
	q = rt._query_runtime_node({"node_path": str(hud.get_path()), "properties": ["text", "theme_override_colors/font_color"]})
	check(q.ok and q.properties.text == "Score: 7", "explicit properties", q)

	var i: Dictionary = rt._send_input({"event": {"type": "key", "key": "Spcae"}})
	check(not i.ok and str(i.error).contains("unknown key name"), "bad key name rejected", i)
	i = rt._send_input({"event": {"type": "action", "action": "no_such_action"}})
	check(not i.ok and str(i.error).contains("no input action"), "unknown action rejected", i)
	i = rt._send_input({"event": {"type": "key", "key": "Space", "presed": true}})
	check(not i.ok and str(i.error).contains("unknown key 'presed'"), "unknown event field rejected", i)
	i = rt._send_input({"event": {"type": "key", "key": "space"}})
	check(i.ok, "valid key event (case-insensitive)", i)

	var c: Dictionary = rt._call_method({"node_path": str(hud.get_path()), "method": "set", "args": ["text", 42], "confirm": true})
	check(c.ok and hud.text == "42", "runtime call_method decodes set()", c)
	hud.free()
	rt.free()
