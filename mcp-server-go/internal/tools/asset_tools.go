package tools



var assetTools = []ToolDef{
	{
		Name:        "generate_2d_asset",
		Description: "Generate a 2D sprite/texture from SVG code and save as PNG. Use for custom visuals (characters, objects, backgrounds, UI). Returns resource_path and dimensions.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"svg_code":  {Type: "string", Description: "Complete SVG code string with <svg> tags including width/height."},
				"filename":  {Type: "string", Description: `Filename for the asset (saved as .png). Example: "player_sprite.png"`},
				"save_path": {Type: "string", Description: "Godot resource path to save (default: res://assets/generated/)"},
			},
			Required: []string{"svg_code", "filename"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{
				"ok":            true,
				"resource_path": "res://assets/generated/" + str(args["filename"]),
				"dimensions":    map[string]any{"width": 64, "height": 64},
			})
		},
	},
}
