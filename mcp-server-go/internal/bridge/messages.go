package bridge

import "encoding/json"

// IncomingMessage is the envelope for all messages from Godot.
type IncomingMessage struct {
	Type        string          `json:"type"`
	ID          string          `json:"id,omitempty"`
	Success     *bool           `json:"success,omitempty"`
	Result      json.RawMessage `json:"result,omitempty"`
	Error       string          `json:"error,omitempty"`
	ProjectPath string          `json:"project_path,omitempty"`
}

// ToolInvokeMessage is sent to Godot to execute a tool.
type ToolInvokeMessage struct {
	Type string         `json:"type"`
	ID   string         `json:"id"`
	Tool string         `json:"tool"`
	Args map[string]any `json:"args"`
}

// PingMessage is sent to Godot as a keepalive.
type PingMessage struct {
	Type string `json:"type"`
}
