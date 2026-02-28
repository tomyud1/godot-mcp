package visualizer

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"

	"github.com/coder/websocket"
	"github.com/tomyud1/godot-mcp/mcp-server-go/internal/bridge"
)

const defaultVizPort = 6510

// Server serves the project visualization and handles internal WebSocket commands.
type Server struct {
	mu         sync.Mutex
	bridge     *bridge.GodotBridge
	httpServer *http.Server
}

// New creates a new visualization server.
func New(b *bridge.GodotBridge) *Server {
	return &Server{bridge: b}
}

// Serve starts the visualization server and opens the browser.
// Returns the URL where the visualization is hosted.
func (s *Server) Serve(projectData any) (string, error) {
	s.Stop() // Close any previous instance

	dataJSON, err := json.Marshal(projectData)
	if err != nil {
		return "", fmt.Errorf("marshal project data: %w", err)
	}

	// Build the HTML page: inline CSS, reference JS modules externally
	htmlPage, err := buildHTML(dataJSON)
	if err != nil {
		return "", err
	}

	ln, err := findListener(defaultVizPort)
	if err != nil {
		return "", err
	}

	mux := http.NewServeMux()

	// Serve the assembled HTML at root
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" || r.URL.Path == "/index.html" {
			if r.Header.Get("Upgrade") == "websocket" {
				s.handleWS(w, r)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Cache-Control", "no-cache")
			w.Write([]byte(htmlPage))
			return
		}

		// Serve JS and CSS files from embedded assets
		name := strings.TrimPrefix(r.URL.Path, "/")
		data, err := assets.ReadFile("assets/" + name)
		if err != nil {
			http.NotFound(w, r)
			return
		}

		ct := "application/octet-stream"
		switch {
		case strings.HasSuffix(name, ".js"):
			ct = "text/javascript; charset=utf-8"
		case strings.HasSuffix(name, ".css"):
			ct = "text/css; charset=utf-8"
		}
		w.Header().Set("Content-Type", ct)
		w.Header().Set("Cache-Control", "no-cache")
		w.Write(data)
	})

	srv := &http.Server{Handler: mux}

	s.mu.Lock()
	s.httpServer = srv
	s.mu.Unlock()

	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("[visualizer] Server error: %v", err)
		}
	}()

	port := ln.Addr().(*net.TCPAddr).Port
	url := fmt.Sprintf("http://localhost:%d", port)
	log.Printf("[visualizer] Serving at %s", url)

	if err := openBrowser(url); err != nil {
		log.Printf("[visualizer] Could not open browser: %v", err)
	}

	return url, nil
}

// Stop shuts down the visualization server.
func (s *Server) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.httpServer != nil {
		s.httpServer.Close()
		s.httpServer = nil
		log.Printf("[visualizer] Server stopped")
	}
}

// buildHTML assembles the final HTML page:
// - Reads template.html
// - Inlines visualizer.css into <style>
// - Replaces %%SCRIPT%% with a <script type="module"> that imports main.js
// - Injects project data as a global variable
func buildHTML(projectDataJSON []byte) (string, error) {
	templateBytes, err := assets.ReadFile("assets/template.html")
	if err != nil {
		return "", fmt.Errorf("read template.html: %w", err)
	}

	cssBytes, err := assets.ReadFile("assets/visualizer.css")
	if err != nil {
		return "", fmt.Errorf("read visualizer.css: %w", err)
	}

	html := string(templateBytes)

	// Inline CSS (same as TS version)
	html = strings.Replace(html, "%%CSS%%", string(cssBytes), 1)

	// Replace the bundled script block with module imports.
	// The TS version injects a single IIFE; we instead load ES modules directly.
	// state.js exports PROJECT_DATA which reads from window.__PROJECT_DATA__.
	moduleScript := fmt.Sprintf(
		"window.__PROJECT_DATA__ = %s;\n",
		string(projectDataJSON),
	)
	moduleScript += `import './main.js';`

	html = strings.Replace(html, "%%SCRIPT%%", moduleScript, 1)

	return html, nil
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		log.Printf("[visualizer] WebSocket accept error: %v", err)
		return
	}
	defer conn.CloseNow()

	log.Printf("[visualizer] Browser connected via WebSocket")

	ctx := r.Context()
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			break
		}

		var msg struct {
			ID      string         `json:"id"`
			Command string         `json:"command"`
			Args    map[string]any `json:"args"`
		}
		if err := json.Unmarshal(data, &msg); err != nil {
			conn.Write(ctx, websocket.MessageText, mustJSON(map[string]any{"error": "invalid JSON"}))
			continue
		}

		result := s.handleInternalCommand(ctx, msg.Command, msg.Args)
		result["id"] = msg.ID

		conn.Write(ctx, websocket.MessageText, mustJSON(result))
	}

	log.Printf("[visualizer] Browser disconnected")
}

func (s *Server) handleInternalCommand(ctx context.Context, command string, args map[string]any) map[string]any {
	if s.bridge == nil {
		return map[string]any{"ok": false, "error": "Bridge not initialized"}
	}
	if !s.bridge.IsConnected() {
		return map[string]any{"ok": false, "error": "Godot is not connected"}
	}

	log.Printf("[visualizer] Internal command: %s", command)

	toolName := "visualizer._internal_" + command
	raw, err := s.bridge.InvokeTool(ctx, toolName, args)
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}

	var result map[string]any
	if err := json.Unmarshal(raw, &result); err != nil {
		return map[string]any{"ok": false, "error": "invalid response from Godot"}
	}
	result["ok"] = true
	return result
}

func findListener(start int) (net.Listener, error) {
	for port := start; port < start+100; port++ {
		ln, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
		if err == nil {
			return ln, nil
		}
	}
	return nil, fmt.Errorf("no available port found starting from %d", start)
}

func mustJSON(v any) []byte {
	data, _ := json.Marshal(v)
	return data
}
