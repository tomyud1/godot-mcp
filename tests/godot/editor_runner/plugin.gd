@tool
extends EditorPlugin
## Editor-mode runner: enabled only in the test project by run.sh. Waits for
## the editor to settle, runs the suite, prints results and exits.

func _enter_tree() -> void:
	_run.call_deferred()


func _run() -> void:
	for i in 30:
		await get_tree().process_frame
	var suite: Node = load("res://suite.gd").new()
	suite.editor_plugin = self
	get_tree().root.add_child(suite)
	var r: Dictionary = suite.run_all()
	suite.queue_free()
	print("\n[editor mode] %d passed, %d failed" % [r.passed, r.failed.size()])
	for f in r.failed:
		print("  FAIL ", f)
	get_tree().quit(0 if r.failed.is_empty() else 1)
