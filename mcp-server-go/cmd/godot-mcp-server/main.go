package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/tomyud1/godot-mcp/mcp-server-go/internal/bridge"
	"github.com/tomyud1/godot-mcp/mcp-server-go/internal/mcpserver"
	"github.com/tomyud1/godot-mcp/mcp-server-go/internal/tools"
	"github.com/tomyud1/godot-mcp/mcp-server-go/internal/visualizer"
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(0)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	log.Printf("[godot-mcp-server] Starting...")

	// Create Godot bridge
	b := bridge.New(bridge.DefaultPort, bridge.DefaultTimeout)

	// Create visualizer server
	viz := visualizer.New(b)

	// Start WebSocket server for Godot communication
	if err := b.Start(ctx); err != nil {
		log.Printf("[godot-mcp-server] Failed to start WebSocket server: %v", err)
		log.Printf("[godot-mcp-server] Continuing in mock-only mode")
	} else {
		log.Printf("[godot-mcp-server] WebSocket server listening on port %d", bridge.DefaultPort)
	}

	// Log connection changes
	b.OnConnectionChange(func(connected bool, info *bridge.GodotInfo) {
		if connected {
			log.Printf("[godot-mcp-server] Godot connected")
		} else {
			log.Printf("[godot-mcp-server] Godot disconnected")
		}
	})

	log.Printf("[godot-mcp-server] Available tools: %d", len(tools.AllTools)+1)
	log.Printf("[godot-mcp-server] Mode: mock (waiting for Godot connection)")

	// Create and run MCP server on stdio
	srv := mcpserver.New(b, viz)
	if err := srv.Run(ctx, &mcp.StdioTransport{}); err != nil {
		log.Printf("[godot-mcp-server] Fatal error: %v", err)
		os.Exit(1)
	}

	// Cleanup
	viz.Stop()
	b.Stop()
}
