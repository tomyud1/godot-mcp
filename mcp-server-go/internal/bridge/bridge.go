package bridge

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

const (
	DefaultPort    = 6505
	DefaultTimeout = 30 * time.Second
	pingInterval   = 10 * time.Second
)

var nextID atomic.Int64

// GodotInfo holds metadata about the connected Godot instance.
type GodotInfo struct {
	ProjectPath string
	ConnectedAt time.Time
}

// Status is the connection status snapshot.
type Status struct {
	Connected       bool       `json:"connected"`
	ProjectPath     string     `json:"project_path,omitempty"`
	ConnectedAt     *time.Time `json:"connected_at,omitempty"`
	PendingRequests int        `json:"pending_requests"`
	Port            int        `json:"port"`
}

type invokeResult struct {
	Data json.RawMessage
	Err  error
}

type pendingRequest struct {
	ch       chan invokeResult
	toolName string
	start    time.Time
}

type connectionCallback func(connected bool, info *GodotInfo)

// GodotBridge manages the WebSocket connection to the Godot plugin.
type GodotBridge struct {
	port    int
	timeout time.Duration

	mu         sync.Mutex
	conn       *websocket.Conn
	info       *GodotInfo
	pending    map[string]*pendingRequest
	callbacks  []connectionCallback
	httpServer *http.Server
	cancelRead context.CancelFunc
}

// New creates a new GodotBridge.
func New(port int, timeout time.Duration) *GodotBridge {
	return &GodotBridge{
		port:    port,
		timeout: timeout,
		pending: make(map[string]*pendingRequest),
	}
}

// Start begins listening for Godot WebSocket connections.
func (b *GodotBridge) Start(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		b.handleUpgrade(ctx, w, r)
	})

	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", b.port))
	if err != nil {
		return fmt.Errorf("listen on port %d: %w", b.port, err)
	}

	b.httpServer = &http.Server{Handler: mux}

	go func() {
		if err := b.httpServer.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("[GodotBridge] HTTP server error: %v", err)
		}
	}()

	return nil
}

// Stop shuts down the bridge and rejects all pending requests.
func (b *GodotBridge) Stop() {
	b.mu.Lock()
	defer b.mu.Unlock()

	for id, p := range b.pending {
		p.ch <- invokeResult{Err: fmt.Errorf("server shutting down")}
		delete(b.pending, id)
	}

	if b.cancelRead != nil {
		b.cancelRead()
		b.cancelRead = nil
	}

	if b.conn != nil {
		b.conn.Close(websocket.StatusGoingAway, "server shutting down")
		b.conn = nil
	}

	if b.httpServer != nil {
		b.httpServer.Close()
		b.httpServer = nil
	}

	log.Printf("[GodotBridge] Stopped")
}

// IsConnected returns true if Godot is connected.
func (b *GodotBridge) IsConnected() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.conn != nil
}

// GetStatus returns a snapshot of the connection status.
func (b *GodotBridge) GetStatus() Status {
	b.mu.Lock()
	defer b.mu.Unlock()
	s := Status{
		Connected:       b.conn != nil,
		PendingRequests: len(b.pending),
		Port:            b.port,
	}
	if b.info != nil {
		s.ProjectPath = b.info.ProjectPath
		t := b.info.ConnectedAt
		s.ConnectedAt = &t
	}
	return s
}

// OnConnectionChange registers a callback for connection state changes.
func (b *GodotBridge) OnConnectionChange(fn connectionCallback) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.callbacks = append(b.callbacks, fn)
}

// InvokeTool sends a tool invocation to Godot and waits for the result.
func (b *GodotBridge) InvokeTool(ctx context.Context, toolName string, args map[string]any) (json.RawMessage, error) {
	id := strconv.FormatInt(nextID.Add(1), 10)
	ch := make(chan invokeResult, 1)

	b.mu.Lock()
	conn := b.conn
	if conn == nil {
		b.mu.Unlock()
		return nil, fmt.Errorf("Godot is not connected")
	}
	b.pending[id] = &pendingRequest{ch: ch, toolName: toolName, start: time.Now()}
	b.mu.Unlock()

	msg := ToolInvokeMessage{
		Type: "tool_invoke",
		ID:   id,
		Tool: toolName,
		Args: args,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		b.mu.Lock()
		delete(b.pending, id)
		b.mu.Unlock()
		return nil, fmt.Errorf("marshal invoke message: %w", err)
	}

	timeoutCtx, cancel := context.WithTimeout(ctx, b.timeout)
	defer cancel()

	if err := conn.Write(timeoutCtx, websocket.MessageText, data); err != nil {
		b.mu.Lock()
		delete(b.pending, id)
		b.mu.Unlock()
		return nil, fmt.Errorf("send to Godot: %w", err)
	}

	log.Printf("[GodotBridge] Invoking tool: %s (%s)", toolName, id)

	select {
	case result := <-ch:
		return result.Data, result.Err
	case <-timeoutCtx.Done():
		b.mu.Lock()
		delete(b.pending, id)
		b.mu.Unlock()
		return nil, fmt.Errorf("tool %s timed out after %s", toolName, b.timeout)
	}
}

func (b *GodotBridge) handleUpgrade(ctx context.Context, w http.ResponseWriter, r *http.Request) {
	b.mu.Lock()
	hasConn := b.conn != nil
	b.mu.Unlock()

	if hasConn {
		log.Printf("[GodotBridge] Rejecting connection - Godot already connected")
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		conn.Close(websocket.StatusCode(4000), "Another Godot instance is already connected")
		return
	}

	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		log.Printf("[GodotBridge] WebSocket accept error: %v", err)
		return
	}

	// Increase read limit for large tool results
	conn.SetReadLimit(10 * 1024 * 1024) // 10 MB

	readCtx, cancelRead := context.WithCancel(ctx)

	b.mu.Lock()
	b.conn = conn
	b.info = &GodotInfo{ConnectedAt: time.Now()}
	b.cancelRead = cancelRead
	b.mu.Unlock()

	log.Printf("[GodotBridge] Godot connected")
	b.notifyConnectionChange(true)

	// Start ping goroutine
	go b.pingLoop(readCtx, conn)

	// Read loop (blocks until disconnect)
	b.readLoop(readCtx, conn)

	// Cleanup on disconnect
	b.handleDisconnect()
}

func (b *GodotBridge) readLoop(ctx context.Context, conn *websocket.Conn) {
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("[GodotBridge] Read error: %v", err)
			}
			return
		}

		var msg IncomingMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			log.Printf("[GodotBridge] Failed to parse message: %v", err)
			continue
		}

		b.handleMessage(msg)
	}
}

func (b *GodotBridge) handleMessage(msg IncomingMessage) {
	switch msg.Type {
	case "tool_result":
		b.handleToolResult(msg)
	case "pong":
		// Keepalive response - nothing to do
	case "godot_ready":
		b.mu.Lock()
		if b.info != nil {
			b.info.ProjectPath = msg.ProjectPath
			log.Printf("[GodotBridge] Godot project: %s", msg.ProjectPath)
		}
		b.mu.Unlock()
	default:
		log.Printf("[GodotBridge] Unknown message type: %s", msg.Type)
	}
}

func (b *GodotBridge) handleToolResult(msg IncomingMessage) {
	b.mu.Lock()
	p, ok := b.pending[msg.ID]
	if ok {
		delete(b.pending, msg.ID)
	}
	b.mu.Unlock()

	if !ok {
		log.Printf("[GodotBridge] Received result for unknown request: %s", msg.ID)
		return
	}

	duration := time.Since(p.start)
	log.Printf("[GodotBridge] Tool %s completed in %dms", p.toolName, duration.Milliseconds())

	if msg.Success != nil && *msg.Success {
		p.ch <- invokeResult{Data: msg.Result}
	} else {
		errMsg := msg.Error
		if errMsg == "" {
			errMsg = "Tool execution failed"
		}
		p.ch <- invokeResult{Err: fmt.Errorf("%s", errMsg)}
	}
}

func (b *GodotBridge) handleDisconnect() {
	b.mu.Lock()
	info := b.info

	// Reject all pending requests
	for id, p := range b.pending {
		p.ch <- invokeResult{Err: fmt.Errorf("Godot disconnected")}
		delete(b.pending, id)
	}

	if b.cancelRead != nil {
		b.cancelRead()
		b.cancelRead = nil
	}

	b.conn = nil
	b.info = nil
	b.mu.Unlock()

	log.Printf("[GodotBridge] Godot disconnected")
	b.notifyConnectionChange(false, info)
}

func (b *GodotBridge) pingLoop(ctx context.Context, conn *websocket.Conn) {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()

	ping, _ := json.Marshal(PingMessage{Type: "ping"})

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := conn.Write(ctx, websocket.MessageText, ping); err != nil {
				return
			}
		}
	}
}

func (b *GodotBridge) notifyConnectionChange(connected bool, info ...*GodotInfo) {
	b.mu.Lock()
	cbs := make([]connectionCallback, len(b.callbacks))
	copy(cbs, b.callbacks)
	b.mu.Unlock()

	var gi *GodotInfo
	if len(info) > 0 {
		gi = info[0]
	}

	for _, cb := range cbs {
		func() {
			defer func() {
				if r := recover(); r != nil {
					log.Printf("[GodotBridge] Connection callback panic: %v", r)
				}
			}()
			cb(connected, gi)
		}()
	}
}
