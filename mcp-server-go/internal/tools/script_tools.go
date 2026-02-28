package tools



var scriptTools = []ToolDef{
	{
		Name:        "edit_script",
		Description: `Apply a SMALL, SURGICAL code edit (1-10 lines) to GDScript files. Auto-applies changes. For large changes, call multiple times. ONLY for .gd files - NEVER for .tscn scene files.`,
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"edit": {Type: "object", Description: `Edit spec: {type: "snippet_replace", file: "res://path.gd", old_snippet: "old code", new_snippet: "new code", context_before: "line above", context_after: "line below"}. Keep old_snippet SMALL (1-10 lines).`},
			},
			Required: []string{"edit"},
		},
		MockFn: mockOK("Diff would be applied"),
	},
	{
		Name:        "validate_script",
		Description: "Validate a GDScript file for syntax errors using Godot's built-in parser. Call after creating or modifying scripts to ensure they are error-free.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"path": {Type: "string", Description: "Path to the GDScript file to validate (e.g., res://scripts/player.gd)"},
			},
			Required: []string{"path"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "path": args["path"], "valid": true, "errors": []any{}})
		},
	},
	{
		Name:        "create_folder",
		Description: "Create a directory (with parent directories if needed).",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"path": {Type: "string", Description: "Directory path (res://path/to/folder)"},
			},
			Required: []string{"path"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "path": args["path"], "message": "Mock: Folder would be created"})
		},
	},
	{
		Name:        "delete_file",
		Description: "Delete a file permanently. ONLY use when explicitly requested. NEVER use to \"edit\" a file.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"path":          {Type: "string", Description: "File to delete"},
				"confirm":       {Type: "boolean", Description: "Must be true to proceed"},
				"create_backup": {Type: "boolean", Description: "Create backup before deleting (default: true)"},
			},
			Required: []string{"path", "confirm"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "path": args["path"], "message": "Mock: File would be deleted"})
		},
	},
	{
		Name:        "rename_file",
		Description: "Rename or move a file, optionally updating references in other files.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"old_path":          {Type: "string", Description: "Current file path"},
				"new_path":          {Type: "string", Description: "New file path"},
				"update_references": {Type: "boolean", Description: "Update references in other files (default: true)"},
			},
			Required: []string{"old_path", "new_path"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "old_path": args["old_path"], "new_path": args["new_path"], "message": "Mock: File would be renamed"})
		},
	},
	{
		Name:        "list_scripts",
		Description: "List all GDScript files in the project with basic metadata.",
		InputSchema: &Schema{
			Type:       "object",
			Properties: map[string]*Schema{},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "scripts": []string{"res://scripts/player.gd", "res://scripts/enemy.gd"}, "count": 2})
		},
	},
}
