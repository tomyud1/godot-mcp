package tools

var AllTools []ToolDef

var toolIndex map[string]*ToolDef

func init() {
	AllTools = append(AllTools, fileTools...)
	AllTools = append(AllTools, sceneTools...)
	AllTools = append(AllTools, scriptTools...)
	AllTools = append(AllTools, projectTools...)
	AllTools = append(AllTools, assetTools...)
	AllTools = append(AllTools, visualizerTools...)

	toolIndex = make(map[string]*ToolDef, len(AllTools))
	for i := range AllTools {
		toolIndex[AllTools[i].Name] = &AllTools[i]
	}
}

// Exists returns true if a tool with the given name is registered.
func Exists(name string) bool {
	_, ok := toolIndex[name]
	return ok
}

// Get returns the tool definition for the given name, or nil.
func Get(name string) *ToolDef {
	return toolIndex[name]
}

// GetMockResponse returns the mock response for a tool.
func GetMockResponse(name string, args map[string]any) any {
	td := toolIndex[name]
	if td == nil {
		return map[string]any{"error": "Unknown tool: " + name}
	}
	return td.MockFn(args)
}
