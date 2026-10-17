/**
 * Type definitions for the Godot MCP Server
 */

// Tool definition for MCP
export interface ToolDefinition {
  name: string;
  description: string;
  inputSchema: {
    type: 'object';
    properties: Record<string, PropertySchema>;
    required?: string[];
  };
  /**
   * Arguments that were renamed: { oldName: newName }. The old name is still
   * accepted (not advertised). The Godot plugin keeps reading the OLD name, so
   * the server translates back before forwarding; that keeps any plugin
   * version working with any server version.
   */
  renamedArgs?: Record<string, string>;
  /**
   * Alternative spellings accepted for an argument: { alternative: canonical }.
   * Unlike renamedArgs, the canonical name is what goes to the plugin.
   */
  aliases?: Record<string, string>;
  /**
   * Rewrite an older argument shape into the current one before validation
   * (e.g. edit_script's nested `edit` object). Return a string to reject.
   */
  fromLegacy?: (args: Record<string, unknown>) => Record<string, unknown> | string;
  /**
   * Rewrite validated arguments into the shape the plugin reads, after
   * renamedArgs have been mapped back to their old names.
   */
  toWire?: (args: Record<string, unknown>) => Record<string, unknown>;
  /**
   * Hidden from the tool list but still callable, so older prompts and
   * batches keep working. Responses carry a pointer to the replacement.
   */
  deprecated?: { replacement: string };
}

export interface PropertySchema {
  type?: 'string' | 'number' | 'boolean' | 'array' | 'object';
  description?: string;
  default?: unknown;
  enum?: string[];
  items?: PropertySchema;
  properties?: Record<string, PropertySchema>;
  required?: string[];
  oneOf?: PropertySchema[];
  minLength?: number;
}

// WebSocket message types (for Phase 2)
export interface ToolInvokeMessage {
  type: 'tool_invoke';
  id: string;
  tool: string;
  args: Record<string, unknown>;
}

export interface ToolResultMessage {
  type: 'tool_result';
  id: string;
  success: boolean;
  // `result` is now populated on both success and failure when the tool
  // returned a structured dict. On failure it carries details like
  // `open_in_editor`, `where`, `clamped`, … alongside the top-level
  // `error` string, so nothing is lost on the wire.
  result?: unknown;
  error?: string;
}

export interface PingMessage {
  type: 'ping';
}

export interface PongMessage {
  type: 'pong';
}

export interface GodotReadyMessage {
  type: 'godot_ready';
  project_path: string;
  // role distinguishes the editor plugin connection from the in-game runtime
  // helper. Older addons (pre-runtime support) omit this; we treat that as 'editor'.
  role?: 'editor' | 'runtime';
  started_at?: number;
  /** plugin.cfg version; sent by plugin 0.6.1+. */
  plugin_version?: string;
  godot_version?: string;
}

export interface ClientStatusMessage {
  type: 'client_status';
  count: number;
}

export interface RuntimeStatusMessage {
  type: 'runtime_status';
  connected: boolean;
}

export type WebSocketMessage =
  | ToolInvokeMessage
  | ToolResultMessage
  | PingMessage
  | PongMessage
  | GodotReadyMessage
  | ClientStatusMessage
  | RuntimeStatusMessage;

// Tool result types
export interface ListDirResult {
  files: string[];
  folders: string[];
  path: string;
}

export interface ReadFileResult {
  content: string;
  path: string;
  line_count: number;
}

export interface SearchProjectResult {
  matches: Array<{
    file: string;
    line: number;
    content: string;
  }>;
  query: string;
  total_matches: number;
}

export interface CreateScriptResult {
  success: boolean;
  path: string;
  message: string;
}
