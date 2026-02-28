package tools



var visualizerTools = []ToolDef{
	{
		Name:        "map_project",
		Description: "Crawl the entire Godot project and build an interactive visual map of all scripts showing their structure (variables, functions, signals), connections (extends, preloads, signal connections), and descriptions. Opens an interactive browser-based visualization.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"root":            {Type: "string", Description: "Root path to start crawling from (default: res://)"},
				"include_addons": {Type: "boolean", Description: "Whether to include scripts in the addons/ folder (default: false)"},
			},
		},
		MockFn: func(args map[string]any) any {
			return map[string]any{
				"project_map": map[string]any{
					"nodes": []map[string]any{
						{
							"path": "res://scripts/player.gd", "filename": "player.gd", "folder": "res://scripts",
							"class_name": "Player", "extends": "CharacterBody2D",
							"description": "Handles player movement and input", "line_count": 85,
							"variables": []map[string]any{{"name": "speed", "exported": true}, {"name": "jump_force", "exported": true}},
							"functions": []map[string]any{{"name": "_ready", "params": ""}, {"name": "_physics_process", "params": "delta: float"}},
							"signals": []string{"health_changed", "died"}, "preloads": []string{"res://scenes/bullet.tscn"}, "connections": []any{},
						},
						{
							"path": "res://scripts/enemy.gd", "filename": "enemy.gd", "folder": "res://scripts",
							"class_name": "Enemy", "extends": "CharacterBody2D",
							"description": "Base enemy AI with patrol and chase behavior", "line_count": 120,
							"variables": []map[string]any{{"name": "patrol_speed", "exported": true}},
							"functions": []map[string]any{{"name": "_ready", "params": ""}, {"name": "_physics_process", "params": "delta: float"}},
							"signals": []string{"enemy_defeated"}, "preloads": []any{},
							"connections": []map[string]any{{"signal": "body_entered", "line": 15}},
						},
					},
					"edges":             []map[string]any{{"from": "res://scripts/player.gd", "to": "res://scenes/bullet.tscn", "type": "preload"}},
					"total_scripts":     2,
					"total_connections": 1,
				},
				"message": "Mock project map generated. Connect Godot for real data.",
			}
		},
	},
}
