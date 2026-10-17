extends SceneTree
## Game-mode runner. Usage: tests/godot/run.sh

var _ran := false

# Run on the first frame so the root is inside the tree.
func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	var suite: Node = load("res://suite.gd").new()
	root.add_child(suite)
	var r: Dictionary = suite.run_all()
	suite.queue_free()
	print("\n[game mode] %d passed, %d failed" % [r.passed, r.failed.size()])
	for f in r.failed:
		print("  FAIL ", f)
	quit(0 if r.failed.is_empty() else 1)
	return false
