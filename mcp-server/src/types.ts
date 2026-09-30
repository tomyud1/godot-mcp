/**
 * Type definitions for the Godot MCP Server
 */

// ---------------------------------------------------------------------------
// MCP content blocks
// ---------------------------------------------------------------------------

export interface TextContentBlock {
  type: 'text';
  text: string;
  [key: string]: unknown;
}

/**
 * An inline image. Per the MCP tools spec this is the only form a model can
 * actually perceive — base64 inside a JSON string is just text to it.
 */
export interface ImageContentBlock {
  type: 'image';
  /** base64-encoded image bytes */
  data: string;
  mimeType: string;
  [key: string]: unknown;
}

export type ContentBlock = TextContentBlock | ImageContentBlock;

/** A tool result as it travels over the wire. */
export interface ToolCallResult {
  content: ContentBlock[];
  /**
   * Machine-readable form of the same result, per the MCP tools spec. Clients
   * that understand it can consume fields without parsing the text block.
   */
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
}

/**
 * Behavioural hints for clients, per the MCP tools specification.
 *
 * Clients use these to decide whether to auto-approve a call, warn the user,
 * or run it without a confirmation prompt. `readOnlyHint` means the tool does
 * not modify the project; `destructiveHint` means it may delete or overwrite
 * in a way that is not trivially reversible; `idempotentHint` means repeating
 * the call with identical arguments has no additional effect.
 *
 * These are hints, not guarantees — clients are told to treat annotations from
 * untrusted servers as advisory. They are still worth getting right: they are
 * the only machine-readable signal an agent has about blast radius.
 */
export interface ToolAnnotations {
  /** Human-readable name for UIs that show a title alongside the tool name. */
  title?: string;
  readOnlyHint?: boolean;
  destructiveHint?: boolean;
  idempotentHint?: boolean;
  /**
   * True when the tool interacts with external entities beyond the project
   * (a filesystem outside res://, the network, another process).
   */
  openWorldHint?: boolean;
}

// Tool definition for MCP
export interface ToolDefinition {
  name: string;
  description: string;
  inputSchema: {
    type: 'object';
    properties: Record<string, PropertySchema>;
    required?: string[];
  };
  annotations?: ToolAnnotations;
  /**
   * Dispatchable but not advertised in `tools/list`.
   *
   * Used for duplicate spellings of a tool that already has a canonical name.
   * Keeping them callable means existing agents and habits keep working, while
   * the model no longer has to choose between two names that do exactly the
   * same thing — and we stop paying context for the ambiguity.
   */
  hidden?: boolean;
  /**
   * Per-tool override of the derived annotation set. Used for tools whose
   * name prefix would otherwise give the wrong answer (e.g. a `validate_`
   * tool that writes, or a `get_` tool with side effects).
   */
  annotationOverrides?: Partial<ToolAnnotations>;
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
