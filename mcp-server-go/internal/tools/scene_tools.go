package tools



var sceneTools = []ToolDef{
	{
		Name:        "create_scene",
		Description: "Create a new Godot scene (.tscn) file with nodes. Use this to create player scenes, UI screens, game objects, etc.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"scene_path":     {Type: "string", Description: "Scene file path (e.g., res://Scenes/player.tscn)"},
				"root_node_name": {Type: "string", Description: "Name of root node (default: derived from filename)"},
				"root_node_type": {Type: "string", Description: "Type of root node (e.g., Node2D, CharacterBody2D, Control, Node3D). REQUIRED."},
				"nodes": {
					Type:        "array",
					Items:       &Schema{Type: "object", Description: "A node: {name, type, properties, script, children}"},
					Description: "Array of child nodes to add. Each node: {name, type, properties, script, children}.",
				},
				"attach_script": {Type: "string", Description: "Optional script path to attach to root node (res://path/to/script.gd)"},
			},
			Required: []string{"scene_path", "root_node_type"},
		},
		MockFn: mockOK("Scene would be created"),
	},
	{
		Name:        "read_scene",
		Description: "Read and parse a scene file to get its full node structure and properties. Use this to understand a scene before editing.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"scene_path":         {Type: "string", Description: "Path to the scene file (res://path/to/scene.tscn)"},
				"include_properties": {Type: "boolean", Description: "Include node properties in the output (default: false)"},
			},
			Required: []string{"scene_path"},
		},
		MockFn: func(args map[string]any) any {
			return map[string]any{
				"ok":         true,
				"scene_path": args["scene_path"],
				"root":       map[string]any{"name": "Root", "type": "Node2D", "children": []map[string]any{{"name": "Sprite2D", "type": "Sprite2D"}}},
				"_mock":      true,
				"_note":      "Connect Godot for real results.",
			}
		},
	},
	{
		Name:        "add_node",
		Description: "Add a single node to an existing scene file.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"scene_path":  {Type: "string", Description: "Path to the scene file (res://path/to/scene.tscn)"},
				"node_name":   {Type: "string", Description: "Name for the new node"},
				"node_type":   {Type: "string", Description: "Type of node (e.g., Sprite2D, Camera2D, RigidBody2D, CollisionShape2D)"},
				"parent_path": {Type: "string", Description: "Path to parent node (. for root, or relative path like Sprite2D)"},
				"properties":  {Type: "object", Description: "Optional dictionary of properties to set on the node"},
			},
			Required: []string{"scene_path", "node_name", "node_type"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "message": "Mock: Would add " + str(args["node_type"]) + " named " + str(args["node_name"])})
		},
	},
	{
		Name:        "remove_node",
		Description: "Remove a node from an existing scene file.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"scene_path": {Type: "string", Description: "Path to the scene file"},
				"node_path":  {Type: "string", Description: "Path to the node to remove (cannot be root, use relative path)"},
			},
			Required: []string{"scene_path", "node_path"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "message": "Mock: Would remove node at " + str(args["node_path"])})
		},
	},
	{
		Name:        "modify_node_property",
		Description: "Modify a property on a node in a .tscn scene file. ALWAYS use this tool to modify properties in scene files - NEVER edit .tscn files directly. Use this to change positions, colors, sizes, visibility, etc.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"scene_path":    {Type: "string", Description: "Path to the .tscn scene file"},
				"node_path":     {Type: "string", Description: `Path to the node (. for root, or relative path like "Sprite2D")`},
				"property_name": {Type: "string", Description: "Name of the property to modify (position, scale, rotation, modulate, visible, etc.)"},
				"value":         {Type: "object", Description: "New value. For Vector2/Vector3/Color, use {type: \"Vector2\", x: 100, y: 200}. For primitives, use directly."},
			},
			Required: []string{"scene_path", "property_name", "value"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "message": "Mock: Would set " + str(args["property_name"]) + " on " + str(args["node_path"])})
		},
	},
	{
		Name:        "rename_node",
		Description: "Rename a node in a scene.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"scene_path": {Type: "string", Description: "Path to the scene file"},
				"node_path":  {Type: "string", Description: "Path to the node to rename"},
				"new_name":   {Type: "string", Description: "New name for the node"},
			},
			Required: []string{"scene_path", "node_path", "new_name"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "message": "Mock: Would rename " + str(args["node_path"]) + " to " + str(args["new_name"])})
		},
	},
	{
		Name:        "move_node",
		Description: "Move a node to a different parent in a scene and optionally control its position among siblings.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"scene_path":      {Type: "string", Description: "Path to the scene file"},
				"node_path":       {Type: "string", Description: "Path to the node to move"},
				"new_parent_path": {Type: "string", Description: "Path to the new parent node (. for root)"},
				"sibling_index":   {Type: "number", Description: "Optional position among siblings (0 = first child). Omit or -1 to append."},
			},
			Required: []string{"scene_path", "node_path", "new_parent_path"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "message": "Mock: Would move " + str(args["node_path"]) + " to " + str(args["new_parent_path"])})
		},
	},
	{
		Name:        "attach_script",
		Description: "Attach or change a script on a node in a scene.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"scene_path":  {Type: "string", Description: "Path to the scene file"},
				"node_path":   {Type: "string", Description: "Path to the node (. for root, or relative path)"},
				"script_path": {Type: "string", Description: "Path to the script file (res://path/to/script.gd)"},
			},
			Required: []string{"scene_path", "script_path"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "message": "Mock: Would attach " + str(args["script_path"])})
		},
	},
	{
		Name:        "detach_script",
		Description: "Remove a script from a node in a scene.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"scene_path": {Type: "string", Description: "Path to the scene file"},
				"node_path":  {Type: "string", Description: "Path to the node (. for root)"},
			},
			Required: []string{"scene_path", "node_path"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "message": "Mock: Would detach script from " + str(args["node_path"])})
		},
	},
	{
		Name:        "set_collision_shape",
		Description: "Create and assign a collision shape resource to a CollisionShape2D or CollisionShape3D node. Supports: CircleShape2D, RectangleShape2D, CapsuleShape2D, SphereShape3D, BoxShape3D, etc.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"scene_path":   {Type: "string", Description: "Path to the .tscn scene file"},
				"node_path":    {Type: "string", Description: "Path to the CollisionShape2D/3D node"},
				"shape_type":   {Type: "string", Description: "Shape type: CircleShape2D, RectangleShape2D, CapsuleShape2D, SphereShape3D, BoxShape3D, etc."},
				"shape_params": {Type: "object", Description: "Shape parameters: {radius: 32} for circles, {size: {x: 64, y: 64}} for rectangles, etc."},
			},
			Required: []string{"scene_path", "shape_type"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "message": "Mock: Would set " + str(args["shape_type"]) + " shape"})
		},
	},
	{
		Name:        "set_sprite_texture",
		Description: "Assign a texture to a Sprite2D/Sprite3D/TextureRect node. Use after generate_2d_asset or to load existing images.",
		InputSchema: &Schema{
			Type: "object",
			Properties: map[string]*Schema{
				"scene_path":     {Type: "string", Description: "Path to the .tscn scene file"},
				"node_path":      {Type: "string", Description: "Path to the Sprite2D/Sprite3D/TextureRect node"},
				"texture_type":   {Type: "string", Description: `Texture type: "ImageTexture", "PlaceholderTexture2D", "GradientTexture2D", "NoiseTexture2D"`},
				"texture_params": {Type: "object", Description: `Texture parameters. ImageTexture: {path: "res://assets/sprite.png"}. PlaceholderTexture2D: {size: {x: 64, y: 64}}.`},
			},
			Required: []string{"scene_path", "texture_type"},
		},
		MockFn: func(args map[string]any) any {
			return mockNote(map[string]any{"ok": true, "message": "Mock: Would set " + str(args["texture_type"]) + " texture"})
		},
	},
}

func mockOK(msg string) func(map[string]any) any {
	return func(args map[string]any) any {
		return mockNote(map[string]any{"ok": true, "message": "Mock: " + msg})
	}
}

func mockNote(m map[string]any) map[string]any {
	m["_mock"] = true
	m["_note"] = "Connect Godot for real results."
	return m
}
