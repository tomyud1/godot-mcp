package tools

// Schema is a minimal JSON Schema representation that marshals
// to valid JSON Schema for the MCP protocol.
type Schema struct {
	Type        string             `json:"type"`
	Description string             `json:"description,omitempty"`
	Properties  map[string]*Schema `json:"properties,omitempty"`
	Required    []string           `json:"required,omitempty"`
	Items       *Schema            `json:"items,omitempty"`
}

// ToolDef pairs a tool's MCP metadata with its mock response generator.
type ToolDef struct {
	Name        string
	Description string
	InputSchema *Schema
	MockFn      func(args map[string]any) any
}
