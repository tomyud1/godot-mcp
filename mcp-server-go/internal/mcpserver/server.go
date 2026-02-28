package mcpserver

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/tomyud1/godot-mcp/mcp-server-go/internal/bridge"
	"github.com/tomyud1/godot-mcp/mcp-server-go/internal/tools"
	"github.com/tomyud1/godot-mcp/mcp-server-go/internal/visualizer"
)

const (
	serverName    = "godot-mcp-server"
	serverVersion = "0.3.0"
)

// New creates and configures the MCP server with all tools registered.
func New(b *bridge.GodotBridge, viz *visualizer.Server) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{
		Name:    serverName,
		Version: serverVersion,
	}, nil)

	// Register dynamic status tool
	server.AddTool(
		&mcp.Tool{
			Name:        "get_godot_status",
			Description: "Check if Godot editor is connected to the MCP server. Use this before attempting Godot operations to see if you'll get real or mock data.",
			InputSchema: emptyObjectSchema(),
		},
		statusHandler(b),
	)

	// Register all tools with a generic handler that routes to Godot or returns mocks
	for i := range tools.AllTools {
		td := &tools.AllTools[i]
		server.AddTool(
			&mcp.Tool{
				Name:        td.Name,
				Description: td.Description,
				InputSchema: td.InputSchema,
			},
			toolHandler(b, viz, td),
		)
	}

	return server
}

type statusResponse struct {
	Connected       bool   `json:"connected"`
	ServerVersion   string `json:"server_version"`
	WebSocketPort   int    `json:"websocket_port"`
	Mode            string `json:"mode"`
	ProjectPath     string `json:"project_path"`
	ConnectedAt     string `json:"connected_at,omitempty"`
	PendingRequests int    `json:"pending_requests"`
	Message         string `json:"message"`
}

func statusHandler(b *bridge.GodotBridge) mcp.ToolHandler {
	return func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		status := b.GetStatus()
		mode := "mock"
		msg := "Godot is not connected. Tools will return mock data. Open a Godot project with the MCP plugin enabled to connect."
		if status.Connected {
			mode = "live"
			msg = "Godot is connected"
			if status.ProjectPath != "" {
				msg += fmt.Sprintf(" (%s)", status.ProjectPath)
			}
			msg += ". Tools will execute in the Godot editor."
		}

		result := statusResponse{
			Connected:       status.Connected,
			ServerVersion:   serverVersion,
			WebSocketPort:   status.Port,
			Mode:            mode,
			ProjectPath:     status.ProjectPath,
			PendingRequests: status.PendingRequests,
			Message:         msg,
		}
		if status.ConnectedAt != nil {
			result.ConnectedAt = status.ConnectedAt.Format("2006-01-02T15:04:05.000Z")
		}

		return textResult(result)
	}
}

func toolHandler(b *bridge.GodotBridge, viz *visualizer.Server, td *tools.ToolDef) mcp.ToolHandler {
	return func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var args map[string]any
		if req.Params.Arguments != nil {
			if err := json.Unmarshal(req.Params.Arguments, &args); err != nil {
				args = make(map[string]any)
			}
		} else {
			args = make(map[string]any)
		}

		var result any

		raw, err := b.InvokeTool(ctx, td.Name, args)
		if err != nil {
			if !b.IsConnected() {
				// Godot not connected — fall back to mock
				result = td.MockFn(args)
			} else {
				return errorResult(td.Name, args, err, "live")
			}
		} else {
			if err := json.Unmarshal(raw, &result); err != nil {
				result = string(raw)
			}
		}

		// Post-processing for map_project
		if td.Name == "map_project" {
			result = handleMapProject(viz, result)
		}

		return textResult(result)
	}
}

func handleMapProject(viz *visualizer.Server, result any) any {
	m, ok := result.(map[string]any)
	if !ok {
		return result
	}
	projectMap, ok := m["project_map"]
	if !ok {
		return result
	}

	url, err := viz.Serve(projectMap)
	if err != nil {
		log.Printf("[mcpserver] Visualization failed: %v", err)
		return result
	}

	m["visualization_url"] = url
	return m
}

func textResult(v any) (*mcp.CallToolResult, error) {
	data, err := json.Marshal(v)
	if err != nil {
		return nil, fmt.Errorf("marshal result: %w", err)
	}
	return &mcp.CallToolResult{
		Content: []mcp.Content{
			&mcp.TextContent{Text: string(data)},
		},
	}, nil
}

func errorResult(toolName string, args map[string]any, err error, mode string) (*mcp.CallToolResult, error) {
	data, _ := json.Marshal(map[string]any{
		"error": err.Error(),
		"tool":  toolName,
		"args":  args,
		"mode":  mode,
		"hint":  "The tool call was sent to Godot but failed. Check Godot editor for details.",
	})
	return &mcp.CallToolResult{
		Content: []mcp.Content{
			&mcp.TextContent{Text: string(data)},
		},
		IsError: true,
	}, nil
}

func emptyObjectSchema() *tools.Schema {
	return &tools.Schema{
		Type:       "object",
		Properties: map[string]*tools.Schema{},
	}
}
