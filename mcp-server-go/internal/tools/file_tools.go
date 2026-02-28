package tools



var fileTools = []ToolDef{
	{
		Name:        "list_dir",
		Description: "List files and folders under a Godot project path (e.g., res://). Returns arrays of files and folders in the specified directory.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"root": {
					Type:        "string",
					Description: "Starting path like res://addons/ai_assistant or res://",
				},
			},
			Required: []string{"root"},
		},
		MockFn: func(args map[string]any) any {
			root, _ := args["root"].(string)
			if root == "" {
				root = "res://"
			}
			return map[string]any{
				"path":    root,
				"files":   []string{"project.godot", "icon.svg", "default_env.tres"},
				"folders": []string{"scenes", "scripts", "assets", "addons"},
				"_mock":   true,
				"_note":   "This is mock data. Connect Godot for real results.",
			}
		},
	},
	{
		Name:        "read_file",
		Description: "Read a text file from the Godot project, optionally a specific line range. Useful for reading GDScript files, scene files, or any text-based content.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"path": {
					Type:        "string",
					Description: "res:// path to the file (e.g., res://scripts/player.gd)",
				},
				"start_line": {
					Type:        "number",
					Description: "1-based inclusive start line (optional)",
				},
				"end_line": {
					Type:        "number",
					Description: "Inclusive end line; 0 or missing means to end of file (optional)",
				},
			},
			Required: []string{"path"},
		},
		MockFn: func(args map[string]any) any {
			return map[string]any{
				"path":       args["path"],
				"content":    "# Mock file content\n# Connect Godot to read actual file contents\nextends Node\n\nfunc _ready():\n    print(\"Hello from mock!\")",
				"line_count": 5,
				"_mock":      true,
			}
		},
	},
	{
		Name:        "search_project",
		Description: "Search the Godot project for a substring and return file hits with line numbers. Useful for finding usages of functions, variables, or any text pattern.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"query": {
					Type:        "string",
					Description: "Case-insensitive substring to find",
				},
				"glob": {
					Type:        "string",
					Description: "Optional glob filter like **/*.gd to search only GDScript files",
				},
			},
			Required: []string{"query"},
		},
		MockFn: func(args map[string]any) any {
			query, _ := args["query"].(string)
			return map[string]any{
				"query": query,
				"matches": []map[string]any{
					{"file": "res://scripts/player.gd", "line": 10, "content": "    # Mock match for \"" + query + "\""},
					{"file": "res://scripts/enemy.gd", "line": 25, "content": "    # Another mock match for \"" + query + "\""},
				},
				"total_matches": 2,
				"_mock":         true,
			}
		},
	},
	{
		Name:        "create_script",
		Description: "Create a NEW GDScript file (.gd) that does not exist yet. Use this for creating new scripts, NOT for editing existing files (use edit_script for edits).",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"path": {
					Type:        "string",
					Description: "Script file path (res://scripts/player.gd) - must not exist yet",
				},
				"content": {
					Type:        "string",
					Description: "Full GDScript content to write to the file",
				},
			},
			Required: []string{"path", "content"},
		},
		MockFn: func(args map[string]any) any {
			return map[string]any{
				"success": true,
				"path":    args["path"],
				"message": "Mock: Would create script at " + str(args["path"]) + ". Connect Godot to actually create the file.",
				"_mock":   true,
			}
		},
	},
}

func str(v any) string {
	s, _ := v.(string)
	return s
}
