package tools



var projectTools = []ToolDef{
	{
		Name:        "get_project_settings",
		Description: "Concise project settings summary: main_scene, window size/stretch, physics tick rate, and render basics.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"include_render":  {Type: "boolean", Description: "Include render settings"},
				"include_physics": {Type: "boolean", Description: "Include physics settings"},
			},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{
				"ok":       true,
				"settings": map[string]any{"main_scene": "res://scenes/main.tscn", "window": map[string]any{"width": 1152, "height": 648}},
			})
		},
	},
	{
		Name:        "get_input_map",
		Description: "Return the InputMap: action names mapped to events (keys, mouse, gamepad).",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"include_deadzones": {Type: "boolean", Description: "Include axis values/deadzones for joypad motion"},
			},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{
				"ok":      true,
				"actions": map[string]any{"ui_accept": []string{"Enter", "Space"}, "ui_cancel": []string{"Escape"}, "move_left": []string{"A", "Left"}},
			})
		},
	},
	{
		Name:        "get_collision_layers",
		Description: "Return named 2D/3D physics collision layers from ProjectSettings.",
		InputSchema: &Schema{
			Type:       "object",
			Properties: map[string]*Schema{},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{
				"ok":        true,
				"layers_2d": map[string]any{"1": "Player", "2": "Enemies", "3": "World"},
			})
		},
	},
	{
		Name:        "get_node_properties",
		Description: "Get available properties for a Godot node type. Use this to discover what properties exist on a node type (e.g., anchors_preset for Control, position for Node2D).",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"node_type": {Type: "string", Description: `Node class name (e.g., "Sprite2D", "Control", "Label", "Button")`},
			},
			Required: []string{"node_type"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{
				"ok":         true,
				"node_type":  args["node_type"],
				"properties": []string{"position", "rotation", "scale", "visible", "modulate"},
			})
		},
	},
	{
		Name:        "get_console_log",
		Description: "Return the latest lines from the Godot editor output log.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"max_lines": {Type: "number", Description: "Maximum number of lines to include (default: 50)"},
			},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{
				"ok":    true,
				"lines": []string{"[Godot] Project loaded", "[Godot] Scene ready"},
			})
		},
	},
	{
		Name:        "get_errors",
		Description: "Get errors and warnings from the Godot editor log with file paths, line numbers, and severity. Returns the most recent errors first.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"max_errors":       {Type: "number", Description: "Maximum number of errors to return (default: 50)"},
				"include_warnings": {Type: "boolean", Description: "Include warnings in addition to errors (default: true)"},
			},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "errors": []any{}, "count": 0})
		},
	},
	{
		Name:        "clear_console_log",
		Description: "Mark the current position in the Godot editor log. Subsequent get_console_log and get_errors calls will only return output after this point.",
		InputSchema: &Schema{
			Type:       "object",
			Properties: map[string]*Schema{},
		},
		MockFn: mockOK("Console would be cleared"),
	},
	{
		Name:        "open_in_godot",
		Description: "Open a file in the Godot editor at a specific line (side-effect only).",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"path": {Type: "string", Description: "res:// path to open"},
				"line": {Type: "number", Description: "1-based line number"},
			},
			Required: []string{"path"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "message": "Mock: Would open " + str(args["path"])})
		},
	},
	{
		Name:        "scene_tree_dump",
		Description: "Dump the scene tree of the scene currently open in the Godot editor (node names, types, and attached scripts).",
		InputSchema: &Schema{
			Type:       "object",
			Properties: map[string]*Schema{},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{
				"ok":   true,
				"tree": "Root (Node2D)\n  Player (CharacterBody2D)\n    Sprite2D\n    CollisionShape2D",
			})
		},
	},
}
