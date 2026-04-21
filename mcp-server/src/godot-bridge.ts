/**
 * GodotBridge - WebSocket server for communication with Godot.
 *
 * Two kinds of connections are supported:
 *   - editor   : the addon running inside the Godot editor process
 *   - runtime  : an MCPRuntime autoload running inside the user's launched game
 *
 * The first hello message (godot_ready) carries a `role` field. We accept
 * exactly one of each role at a time. Tool calls are routed by name:
 *   - RUNTIME_ONLY_TOOLS                       → runtime connection
 *   - list_signal_connections w/ source=runtime → runtime connection
 *   - everything else                           → editor connection
 */

import { WebSocketServer, WebSocket } from 'ws';
import { randomUUID } from 'crypto';
import type {
  ToolInvokeMessage,
  ToolResultMessage,
  WebSocketMessage,
} from './types.js';

const DEFAULT_PORT = 6505;
const DEFAULT_TIMEOUT = 30000;
const PING_INTERVAL = 10000;

// Tools that are ALWAYS handled by the runtime helper (the in-game autoload).
// list_signal_connections is conditionally routed (see routeIsRuntime()).
export const RUNTIME_ONLY_TOOLS = new Set<string>([
  'take_screenshot',
  'send_input',
  'query_runtime_node',
  'get_runtime_log',
]);

interface PendingRequest {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
  toolName: string;
  startTime: number;
  target: 'editor' | 'runtime';
}

interface GodotInfo {
  projectPath?: string;
  connectedAt: Date;
  role: 'editor' | 'runtime';
}

type ConnectionCallback = (connected: boolean, info?: GodotInfo) => void;
type RuntimeStatusCallback = (connected: boolean) => void;

interface ConnSlot {
  ws: WebSocket;
  info: GodotInfo;
}

export class GodotBridge {
  private wss: WebSocketServer | null = null;
  private _listening = false;
  private editor: ConnSlot | null = null;
  private runtime: ConnSlot | null = null;
  private pendingRequests: Map<string, PendingRequest> = new Map();
  private pingInterval: NodeJS.Timeout | null = null;
  private connectionCallbacks: Set<ConnectionCallback> = new Set();
  private runtimeStatusCallbacks: Set<RuntimeStatusCallback> = new Set();

  private port: number;
  private timeout: number;

  constructor(port: number = DEFAULT_PORT, timeout: number = DEFAULT_TIMEOUT) {
    this.port = port;
    this.timeout = timeout;
  }

  start(): Promise<void> {
    return new Promise((resolve, reject) => {
      try {
        this.wss = new WebSocketServer({ host: '127.0.0.1', port: this.port });

        this.wss.on('connection', (ws) => this.handleConnection(ws));
        this.wss.on('error', (error) => {
          this.log('error', `WebSocket server error: ${error.message}`);
          reject(error);
        });
        this.wss.on('listening', () => {
          this._listening = true;
          this.log('info', `WebSocket server listening on port ${this.port}`);
          resolve();
        });
      } catch (error) {
        reject(error);
      }
    });
  }

  stop(): void {
    this._listening = false;

    if (this.pingInterval) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }

    for (const [, pending] of this.pendingRequests) {
      clearTimeout(pending.timeout);
      pending.reject(new Error('Server shutting down'));
    }
    this.pendingRequests.clear();

    this.editor?.ws.close();
    this.editor = null;
    this.runtime?.ws.close();
    this.runtime = null;

    if (this.wss) {
      this.wss.close();
      this.wss = null;
    }

    this.log('info', 'WebSocket server stopped');
  }

  // --------------------------------------------------------------------------
  // Routing
  // --------------------------------------------------------------------------

  /**
   * Decide whether a tool invocation should be sent to the runtime connection.
   * For list_signal_connections we look at args.source to allow either editor
   * (scene_file) or runtime routing.
   */
  routeIsRuntime(toolName: string, args: Record<string, unknown> | undefined): boolean {
    if (RUNTIME_ONLY_TOOLS.has(toolName)) return true;
    if (toolName === 'list_signal_connections' && args && (args as Record<string, unknown>).source === 'runtime') return true;
    return false;
  }

  // --------------------------------------------------------------------------
  // Connection handling
  // --------------------------------------------------------------------------

  private handleConnection(ws: WebSocket): void {
    // Default every new connection to the editor slot immediately so clients
    // that don't send a godot_ready message (legacy plugins, test harnesses)
    // still count as connected. If the very first message is godot_ready with
    // role="runtime", we transfer the socket to the runtime slot instead.
    let assignedRole: 'editor' | 'runtime' | null = null;

    if (!this.editor) {
      this.editor = { ws, info: { connectedAt: new Date(), role: 'editor' } };
      assignedRole = 'editor';
      this.startPingLoop();
      this.notifyConnectionChange(true, this.editor.info);
    } else {
      // Editor slot is taken — this might become the runtime slot via
      // godot_ready. Otherwise we close it below.
      assignedRole = null;
    }

    ws.on('message', (data) => {
      let message: WebSocketMessage;
      try {
        message = JSON.parse(data.toString()) as WebSocketMessage;
      } catch (err) {
        this.log('error', `Failed to parse message: ${err}`);
        return;
      }

      if (message.type === 'godot_ready') {
        const desiredRole: 'editor' | 'runtime' = (message.role === 'runtime') ? 'runtime' : 'editor';

        if (desiredRole === 'runtime') {
          if (this.runtime && this.runtime.ws !== ws) {
            this.log('warn', 'Rejecting runtime connection - runtime already connected');
            ws.close(4001, 'Another Godot runtime is already connected');
            return;
          }
          // If we defaulted this socket to editor, release that slot.
          if (assignedRole === 'editor' && this.editor?.ws === ws) {
            this.editor = null;
            this.notifyConnectionChange(false);
          }
          this.runtime = { ws, info: { connectedAt: new Date(), projectPath: message.project_path, role: 'runtime' } };
          assignedRole = 'runtime';
          this.log('info', `Godot runtime connected (project=${message.project_path})`);
          this.sendRuntimeStatusToEditor();
          this.notifyRuntimeStatus(true);
          return;
        }

        // desiredRole === 'editor'
        if (this.editor && this.editor.ws !== ws) {
          this.log('warn', 'Rejecting editor connection - editor already connected');
          ws.close(4000, 'Another Godot editor is already connected');
          return;
        }
        if (!this.editor) {
          this.editor = { ws, info: { connectedAt: new Date(), projectPath: message.project_path, role: 'editor' } };
          assignedRole = 'editor';
          this.startPingLoop();
          this.notifyConnectionChange(true, this.editor.info);
        } else {
          this.editor.info.projectPath = message.project_path;
        }
        this.log('info', `Godot editor ready (project=${message.project_path})`);
        this.sendRuntimeStatusToEditor();
        return;
      }

      if (assignedRole === null) {
        // Never got a seat and never sent godot_ready. Close.
        ws.close(4000, 'Another Godot editor is already connected');
        return;
      }

      this.handleMessage(message, assignedRole);
    });

    ws.on('close', (code, reason) => {
      if (assignedRole === 'editor' && this.editor?.ws === ws) {
        this.log('info', `Editor disconnected: ${code} ${reason.toString()}`);
        this.editor = null;
        this.failPending('editor', new Error('Godot disconnected'));
        this.notifyConnectionChange(false);
        if (!this.runtime && this.pingInterval) {
          clearInterval(this.pingInterval);
          this.pingInterval = null;
        }
      } else if (assignedRole === 'runtime' && this.runtime?.ws === ws) {
        this.log('info', `Runtime disconnected: ${code} ${reason.toString()}`);
        this.runtime = null;
        this.failPending('runtime', new Error('Godot runtime disconnected'));
        this.sendRuntimeStatusToEditor();
        this.notifyRuntimeStatus(false);
      }
    });

    ws.on('error', (error) => {
      this.log('error', `WebSocket error: ${error.message}`);
    });
  }

  private startPingLoop(): void {
    if (this.pingInterval) return;
    this.pingInterval = setInterval(() => {
      this.sendTo(this.editor?.ws, { type: 'ping' });
      this.sendTo(this.runtime?.ws, { type: 'ping' });
    }, PING_INTERVAL);
  }

  private failPending(target: 'editor' | 'runtime', err: Error): void {
    for (const [id, pending] of this.pendingRequests) {
      if (pending.target === target) {
        clearTimeout(pending.timeout);
        pending.reject(err);
        this.pendingRequests.delete(id);
      }
    }
  }

  private handleMessage(message: WebSocketMessage, role: 'editor' | 'runtime'): void {
    switch (message.type) {
      case 'tool_result':
        this.handleToolResult(message);
        break;
      case 'pong':
        break;
      case 'godot_ready':
        // Already handled at the role-assignment step above; no-op for repeats.
        break;
      default:
        this.log('warn', `Unknown message type from ${role}: ${(message as { type: string }).type}`);
    }
  }

  private handleToolResult(message: ToolResultMessage): void {
    const pending = this.pendingRequests.get(message.id);
    if (!pending) {
      this.log('warn', `Received result for unknown request: ${message.id}`);
      return;
    }
    clearTimeout(pending.timeout);
    this.pendingRequests.delete(message.id);
    const duration = Date.now() - pending.startTime;
    this.log('debug', `Tool ${pending.toolName} completed in ${duration}ms (${pending.target})`);
    if (message.success) {
      pending.resolve(message.result);
    } else {
      // Surface structured error details (open_in_editor, where, clamped, …)
      // to the MCP layer instead of collapsing the response into just the
      // error string. Callers can inspect `error.details` for the original
      // dict the tool returned.
      const err = new Error(message.error || 'Tool execution failed') as Error & {
        details?: unknown;
      };
      if (message.result !== undefined && message.result !== null) {
        err.details = message.result;
      }
      pending.reject(err);
    }
  }

  // --------------------------------------------------------------------------
  // Tool invocation
  // --------------------------------------------------------------------------

  async invokeTool(toolName: string, args: Record<string, unknown>): Promise<unknown> {
    const target: 'editor' | 'runtime' = this.routeIsRuntime(toolName, args) ? 'runtime' : 'editor';
    const slot = target === 'editor' ? this.editor : this.runtime;
    if (!slot || slot.ws.readyState !== WebSocket.OPEN) {
      if (target === 'runtime') {
        throw new Error(
          `Runtime helper is not connected. Tool '${toolName}' requires the game to be running with the MCPRuntime autoload registered. ` +
          `Call run_scene with wait_for_runtime=true, or enable the godot_mcp plugin so MCPRuntime is auto-registered.`
        );
      }
      throw new Error('Godot is not connected');
    }

    const id = randomUUID();
    const startTime = Date.now();

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingRequests.delete(id);
        reject(new Error(`Tool ${toolName} timed out after ${this.timeout}ms (${target})`));
      }, this.timeout);

      this.pendingRequests.set(id, { resolve, reject, timeout, toolName, startTime, target });

      const message: ToolInvokeMessage = {
        type: 'tool_invoke',
        id,
        tool: toolName,
        args,
      };
      this.sendTo(slot.ws, message);
      this.log('debug', `Invoking tool: ${toolName} (${id}) on ${target}`);
    });
  }

  /** Notify the editor of the current AI client count. */
  sendClientStatus(count: number): void {
    this.sendTo(this.editor?.ws, { type: 'client_status', count });
  }

  /** Push the current runtime helper status to the editor connection. */
  private sendRuntimeStatusToEditor(): void {
    this.sendTo(this.editor?.ws, { type: 'runtime_status', connected: !!this.runtime });
  }

  private sendTo(ws: WebSocket | undefined, message: WebSocketMessage | ToolInvokeMessage): void {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(message));
    }
  }

  // --------------------------------------------------------------------------
  // Status / observers
  // --------------------------------------------------------------------------

  isListening(): boolean { return this._listening; }
  isConnected(): boolean { return this.editor?.ws.readyState === WebSocket.OPEN; }
  isRuntimeConnected(): boolean { return this.runtime?.ws.readyState === WebSocket.OPEN; }

  getStatus(): {
    connected: boolean;
    runtimeConnected: boolean;
    projectPath?: string;
    connectedAt?: Date;
    pendingRequests: number;
    port: number;
  } {
    return {
      connected: this.isConnected(),
      runtimeConnected: this.isRuntimeConnected(),
      projectPath: this.editor?.info.projectPath,
      connectedAt: this.editor?.info.connectedAt,
      pendingRequests: this.pendingRequests.size,
      port: this.port,
    };
  }

  onConnectionChange(callback: ConnectionCallback): void {
    this.connectionCallbacks.add(callback);
  }
  offConnectionChange(callback: ConnectionCallback): void {
    this.connectionCallbacks.delete(callback);
  }

  onRuntimeStatusChange(callback: RuntimeStatusCallback): void {
    this.runtimeStatusCallbacks.add(callback);
  }

  private notifyConnectionChange(connected: boolean, info?: GodotInfo): void {
    for (const cb of this.connectionCallbacks) {
      try { cb(connected, info); } catch (err) { this.log('error', `Connection callback error: ${err}`); }
    }
  }

  private notifyRuntimeStatus(connected: boolean): void {
    for (const cb of this.runtimeStatusCallbacks) {
      try { cb(connected); } catch (err) { this.log('error', `Runtime status callback error: ${err}`); }
    }
  }

  private log(level: 'debug' | 'info' | 'warn' | 'error', message: string): void {
    const timestamp = new Date().toISOString();
    console.error(`[${timestamp}] [GodotBridge] [${level.toUpperCase()}] ${message}`);
  }
}

let defaultBridge: GodotBridge | null = null;
export function getDefaultBridge(): GodotBridge {
  if (!defaultBridge) defaultBridge = new GodotBridge();
  return defaultBridge;
}
export function createBridge(port?: number, timeout?: number): GodotBridge {
  return new GodotBridge(port, timeout);
}
