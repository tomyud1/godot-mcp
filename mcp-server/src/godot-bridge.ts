/**
 * GodotBridge - WebSocket server for communication with Godot plugin
 *
 * Handles:
 * - WebSocket server on configurable port (default 6505)
 * - Connection management with Godot plugin
 * - Tool invocation requests and response tracking
 * - Timeouts and error handling
 * - Ping/pong keepalive
 */

import { WebSocketServer, WebSocket } from 'ws';
import { randomUUID } from 'crypto';
import type {
  ToolInvokeMessage,
  ToolResultMessage,
  WebSocketMessage
} from './types.js';

// Configuration
const DEFAULT_PORT = 6505;
const DEFAULT_TIMEOUT = 30000; // 30 seconds
const PING_INTERVAL = 10000; // 10 seconds

interface PendingRequest {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
  toolName: string;
  startTime: number;
}

interface GodotInfo {
  projectPath?: string;
  connectedAt: Date;
}

type ConnectionCallback = (connected: boolean, info?: GodotInfo) => void;

export class GodotBridge {
  private wss: WebSocketServer | null = null;
  private godotConnection: WebSocket | null = null;
  private godotInfo: GodotInfo | null = null;
  private pendingRequests: Map<string, PendingRequest> = new Map();
  private pingInterval: NodeJS.Timeout | null = null;
  private connectionCallbacks: Set<ConnectionCallback> = new Set();

  private port: number;
  private timeout: number;

  constructor(port: number = DEFAULT_PORT, timeout: number = DEFAULT_TIMEOUT) {
    this.port = port;
    this.timeout = timeout;
  }

  /**
   * Start the WebSocket server
   */
  start(): Promise<void> {
    return new Promise((resolve, reject) => {
      try {
        this.wss = new WebSocketServer({ port: this.port });

        this.wss.on('connection', (ws, req) => {
          this.handleConnection(ws, req);
        });

        this.wss.on('error', (error) => {
          this.log('error', `WebSocket server error: ${error.message}`);
          reject(error);
        });

        this.wss.on('listening', () => {
          this.log('info', `WebSocket server listening on port ${this.port}`);
          resolve();
        });

      } catch (error) {
        reject(error);
      }
    });
  }

  /**
   * Stop the WebSocket server
   */
  stop(): void {
    if (this.pingInterval) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }

    // Reject all pending requests
    for (const [id, pending] of this.pendingRequests) {
      clearTimeout(pending.timeout);
      pending.reject(new Error('Server shutting down'));
    }
    this.pendingRequests.clear();

    // Close Godot connection
    if (this.godotConnection) {
      this.godotConnection.close();
      this.godotConnection = null;
    }

    // Close server
    if (this.wss) {
      this.wss.close();
      this.wss = null;
    }

    this.log('info', 'WebSocket server stopped');
  }

  /**
   * Handle new WebSocket connection
   */
  private handleConnection(ws: WebSocket, req: unknown): void {
    // Only allow one Godot connection at a time
    if (this.godotConnection) {
      this.log('warn', 'Rejecting connection - Godot already connected');
      ws.close(4000, 'Another Godot instance is already connected');
      return;
    }

    this.godotConnection = ws;
    this.godotInfo = { connectedAt: new Date() };
    this.log('info', 'Godot plugin connected');

    // Set up ping interval for keepalive
    this.pingInterval = setInterval(() => {
      if (this.godotConnection?.readyState === WebSocket.OPEN) {
        this.sendMessage({ type: 'ping' });
      }
    }, PING_INTERVAL);

    // Handle messages
    ws.on('message', (data) => {
      try {
        const message = JSON.parse(data.toString()) as WebSocketMessage;
        this.handleMessage(message);
      } catch (error) {
        this.log('error', `Failed to parse message: ${error}`);
      }
    });

    // Handle close
    ws.on('close', (code, reason) => {
      this.log('info', `Godot disconnected: ${code} - ${reason.toString()}`);
      this.handleDisconnection();
    });

    // Handle errors
    ws.on('error', (error) => {
      this.log('error', `WebSocket error: ${error.message}`);
    });

    // Notify listeners
    this.notifyConnectionChange(true);
  }

  /**
   * Handle Godot disconnection
   */
  private handleDisconnection(): void {
    if (this.pingInterval) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }

    this.godotConnection = null;
    const info = this.godotInfo;
    this.godotInfo = null;

    // Reject all pending requests
    for (const [id, pending] of this.pendingRequests) {
      clearTimeout(pending.timeout);
      pending.reject(new Error('Godot disconnected'));
    }
    this.pendingRequests.clear();

    // Notify listeners
    this.notifyConnectionChange(false, info || undefined);
  }

  /**
   * Handle incoming WebSocket message
   */
  private handleMessage(message: WebSocketMessage): void {
    switch (message.type) {
      case 'tool_result':
        this.handleToolResult(message);
        break;

      case 'pong':
        // Keepalive response - nothing to do
        break;

      case 'godot_ready':
        if (this.godotInfo) {
          this.godotInfo.projectPath = message.project_path;
          this.log('info', `Godot project: ${message.project_path}`);
        }
        break;

      default:
        this.log('warn', `Unknown message type: ${(message as { type: string }).type}`);
    }
  }

  /**
   * Handle tool result from Godot
   */
  private handleToolResult(message: ToolResultMessage): void {
    const pending = this.pendingRequests.get(message.id);

    if (!pending) {
      this.log('warn', `Received result for unknown request: ${message.id}`);
      return;
    }

    clearTimeout(pending.timeout);
    this.pendingRequests.delete(message.id);

    const duration = Date.now() - pending.startTime;
    this.log('debug', `Tool ${pending.toolName} completed in ${duration}ms`);

    if (message.success) {
      pending.resolve(message.result);
    } else {
      pending.reject(new Error(message.error || 'Tool execution failed'));
    }
  }

  /**
   * Invoke a tool on the Godot plugin
   */
  async invokeTool(toolName: string, args: Record<string, unknown>): Promise<unknown> {
    if (!this.isConnected()) {
      throw new Error('Godot is not connected');
    }

    const id = randomUUID();
    const startTime = Date.now();

    return new Promise((resolve, reject) => {
      // Set up timeout
      const timeout = setTimeout(() => {
        this.pendingRequests.delete(id);
        reject(new Error(`Tool ${toolName} timed out after ${this.timeout}ms`));
      }, this.timeout);

      // Store pending request
      this.pendingRequests.set(id, {
        resolve,
        reject,
        timeout,
        toolName,
        startTime
      });

      // Send invocation request
      const message: ToolInvokeMessage = {
        type: 'tool_invoke',
        id,
        tool: toolName,
        args
      };

      this.sendMessage(message);
      this.log('debug', `Invoking tool: ${toolName} (${id})`);
    });
  }

  /**
   * Send a message to Godot
   */
  private sendMessage(message: WebSocketMessage | ToolInvokeMessage): void {
    if (this.godotConnection?.readyState === WebSocket.OPEN) {
      this.godotConnection.send(JSON.stringify(message));
    }
  }

  /**
   * Check if Godot is connected
   */
  isConnected(): boolean {
    return this.godotConnection?.readyState === WebSocket.OPEN;
  }

  /**
   * Get connection status info
   */
  getStatus(): {
    connected: boolean;
    projectPath?: string;
    connectedAt?: Date;
    pendingRequests: number;
    port: number;
  } {
    return {
      connected: this.isConnected(),
      projectPath: this.godotInfo?.projectPath,
      connectedAt: this.godotInfo?.connectedAt,
      pendingRequests: this.pendingRequests.size,
      port: this.port
    };
  }

  /**
   * Register a callback for connection changes
   */
  onConnectionChange(callback: ConnectionCallback): void {
    this.connectionCallbacks.add(callback);
  }

  /**
   * Remove a connection change callback
   */
  offConnectionChange(callback: ConnectionCallback): void {
    this.connectionCallbacks.delete(callback);
  }

  /**
   * Notify all listeners of connection change
   */
  private notifyConnectionChange(connected: boolean, info?: GodotInfo): void {
    for (const callback of this.connectionCallbacks) {
      try {
        callback(connected, info);
      } catch (error) {
        this.log('error', `Connection callback error: ${error}`);
      }
    }
  }

  /**
   * Log a message (to stderr, since stdout is for MCP)
   */
  private log(level: 'debug' | 'info' | 'warn' | 'error', message: string): void {
    const timestamp = new Date().toISOString();
    console.error(`[${timestamp}] [GodotBridge] [${level.toUpperCase()}] ${message}`);
  }
}

// Export singleton instance for convenience
let defaultBridge: GodotBridge | null = null;

export function getDefaultBridge(): GodotBridge {
  if (!defaultBridge) {
    defaultBridge = new GodotBridge();
  }
  return defaultBridge;
}

export function createBridge(port?: number, timeout?: number): GodotBridge {
  return new GodotBridge(port, timeout);
}
