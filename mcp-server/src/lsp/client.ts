/**
 * LspClient — high-level Godot LSP client over TCP.
 *
 * Connects to Godot's built-in Language Server Protocol server (default
 * port 6005, configurable via GODOT_MCP_LSP_PORT env var) and exposes a
 * focused set of LSP features as simple async methods.
 *
 * Usage:
 *   const client = new LspClient(6005);
 *   client.setProjectRoot('D:/my-project');  // set once Godot connects
 *   await client.connect();
 *   const diags = await client.getDiagnostics('res://scripts/player.gd');
 *   await client.disconnect();
 */

import { type Logger } from 'vscode-jsonrpc';
import {
  createProtocolConnection,
  type ProtocolConnection,
  InitializeRequest,
  InitializedNotification,
  DidOpenTextDocumentNotification,
  DidCloseTextDocumentNotification,
  DefinitionRequest,
  ReferencesRequest,
  HoverRequest,
  DocumentSymbolRequest,
  PublishDiagnosticsNotification,
  type Diagnostic,
  type Location,
  type LocationLink,
  type Definition,
  type Hover,
  type DocumentSymbol,
  type SymbolKind,
} from 'vscode-languageserver-protocol';
import * as fs from 'fs';
import * as path from 'path';
import { createLspTransport, type LspMessageReader, type LspMessageWriter } from './transport.js';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const DEFAULT_LSP_PORT = 6005;
const DIAGNOSTICS_TIMEOUT_MS = 5_000;
const CONNECTION_TIMEOUT_MS = 10_000;

// ---------------------------------------------------------------------------
// LspClient
// ---------------------------------------------------------------------------

export class LspClient {
  private _port: number;
  private _projectRoot: string = '';
  private _connection: ProtocolConnection | null = null;
  private _reader: LspMessageReader | null = null;
  private _writer: LspMessageWriter | null = null;
  private _connected: boolean = false;

  /** Cached diagnostics keyed by file:// URI. */
  private _diagnosticsCache = new Map<string, Diagnostic[]>();
  /** Suppress per-document diagnostic log unless a validation is in progress. */
  private _pendingValidationLog = false;

  constructor(port: number = DEFAULT_LSP_PORT) {
    this._port = port;
  }

  // -- lifecycle ------------------------------------------------------------

  get connected(): boolean {
    return this._connected;
  }

  /** Provide the filesystem root so res:// paths can be resolved to file:// URIs. */
  setProjectRoot(root: string): void {
    this._projectRoot = root.replace(/\\/g, '/').replace(/\/$/, '');
  }

  /**
   * Open a TCP connection to Godot LSP and complete the initialize handshake.
   * Returns true on success, or throws if the connection / handshake fails.
   */
  async connect(): Promise<boolean> {
    if (this._connected) return true;

    // Abort stale resources from a previous connection to prevent
    // event interference with the new socket.
    if (this._connection) {
      try { this._connection.dispose(); } catch { /* ignore */ }
      this._connection = null;
    }
    this._reader = null;
    this._writer = null;

    const { reader, writer, socket } = createLspTransport();
    // createLspTransport already installed a permanent error sink on
    // the socket — no need to add another one here.

    const logger: Logger = {
      error: (msg: string) => console.error(`[LspClient] ${msg}`),
      warn: (msg: string) => console.warn(`[LspClient] ${msg}`),
      info: (msg: string) => console.error(`[LspClient] ${msg}`),
      log: (_msg: string) => { /* quiet */ },
    };

    const connection = createProtocolConnection(reader, writer, logger);
    // Don't assign this._connection / this._reader / this._writer yet —
    // wait until the handshake succeeds so the internal state stays clean
    // if the transport dies mid-handshake.

    // Listen for diagnostics notifications and cache them.
    // IMPORTANT: Godot LSP on Windows percent-encodes special characters
    // in file:// URIs (e.g. D%3A for D:).  We decode the URI so it
    // matches the unencoded key we use for lookups.
    connection.onNotification(PublishDiagnosticsNotification.type, (params) => {
      const rawUri = params.uri;
      const uri = decodeURIComponent(rawUri);
      this._diagnosticsCache.set(uri, params.diagnostics);
      if (this._pendingValidationLog) {
        console.error(`[LspClient]   diagnostics: ${params.diagnostics.length} item(s)`);
        this._pendingValidationLog = false;
      }
      if (params.diagnostics.length > 0) {
        // Also index by res:// for callers that use res:// paths
        const resUri = this._uriToResUri(uri);
        if (resUri && resUri !== uri) {
          this._diagnosticsCache.set(resUri, params.diagnostics);
        }
      }
    });

    connection.listen();

    // Transport-lost callback — mark disconnected so the retry loop in
    // index.ts can attempt a fresh connect.  This fires during normal
    // reconnect cycles as well as unexpected disconnects.
    connection.onClose(() => {
      this._connected = false;
    });

    // ---- Wire up TCP events BEFORE connect() to avoid race condition ----
    console.error(`[LspClient] Connecting to Godot LSP at 127.0.0.1:${this._port}...`);

    const connectPromise = new Promise<void>((resolve, reject) => {
      if (socket.readyState === 'open') {
        resolve();
        return;
      }

      // Prevent double-resolve — exactly one of connect/error/close will fire.
      let settled = false;
      const done = (fn: () => void) => { if (!settled) { settled = true; fn(); } };

      const timeout = setTimeout(
        () => done(() => reject(new Error(`LSP TCP connection timeout (port ${this._port})`))),
        CONNECTION_TIMEOUT_MS,
      );

      socket.once('connect', () => done(() => { clearTimeout(timeout); resolve(); }));
      socket.once('error', (err: Error) => done(() => { clearTimeout(timeout); reject(err); }));
      socket.once('close', () => done(() => { clearTimeout(timeout); reject(new Error('Socket closed before connection')); }));
    });

    // Now initiate the connection — all listeners are in place
    socket.connect({ host: '127.0.0.1', port: this._port });

    await connectPromise;
    console.error(`[LspClient] TCP connected, starting LSP initialize handshake...`);

      // ---- LSP initialize handshake ----
    try {
      const result = await connection.sendRequest(InitializeRequest.type, {
        processId: process.pid,
        rootUri: this._projectRoot ? this._toFileUri('res://') : null,
        capabilities: {
          textDocument: {
            definition: { dynamicRegistration: false },
            references: { dynamicRegistration: false },
            hover: { dynamicRegistration: false, contentFormat: ['markdown', 'plaintext'] },
            documentSymbol: { dynamicRegistration: false, hierarchicalDocumentSymbolSupport: true },
          },
        },
        workspaceFolders: this._projectRoot
          ? [{ uri: this._toFileUri('res://'), name: path.basename(this._projectRoot) }]
          : null,
      });

      console.error(`[LspClient] Initialized — Godot LSP: ${result.serverInfo?.name ?? 'unknown'} ${result.serverInfo?.version ?? ''}`);

      await connection.sendNotification(InitializedNotification.type, {});

      this._connection = connection;
      this._reader = reader;
      this._writer = writer;
      this._connected = true;
      return true;
    } catch (err) {
      console.error(`[LspClient] Initialize failed: ${err instanceof Error ? err.message : String(err)}`);
      try { connection.dispose(); } catch { /* ignore */ }
      // _connection was never assigned, so no need to null it.
      // _diagnosticsCache might have stale entries from publishDiagnostics
      // notifications that arrived during the brief didOpen window.
      this._diagnosticsCache.clear();
      throw err;
    }
  }

  /** Gracefully shut down the LSP connection. Idempotent. */
  async disconnect(): Promise<void> {
    const conn = this._connection;
    this._connection = null;
    this._reader = null;
    this._writer = null;
    this._connected = false;
    if (conn) {
      try { conn.dispose(); } catch { /* ignore */ }
    }
    this._diagnosticsCache.clear();
  }

  // -- public API -----------------------------------------------------------

  /**
   * Validate a GDScript file by opening it in the LSP server and waiting for
   * `textDocument/publishDiagnostics`.  Returns zero or more diagnostics.
   */
  async getDiagnostics(filePath: string): Promise<Diagnostic[]> {
    this._ensureConnected();
    const uri = this._toFileUri(filePath);

    // Purge stale cache for this URI (and the alternate res:// key)
    this._diagnosticsCache.delete(uri);
    const resUri = this._uriToResUri(uri);
    if (resUri) this._diagnosticsCache.delete(resUri);

    // Read file content from disk
    const content = this._readFileContent(filePath);

    console.error(`[LspClient] validate ${filePath}`);
    this._pendingValidationLog = true;

    // Send didOpen to trigger analysis
    await this._connection!.sendNotification(DidOpenTextDocumentNotification.type, {
      textDocument: {
        uri,
        languageId: 'gdscript',
        version: 1,
        text: content,
      },
    });

    // Godot LSP publishes diagnostics asynchronously in potentially
    // multiple rounds — we poll with a settle window (300 ms + 200 ms
    // quiet period) to avoid catching an intermediate empty batch.
    const result = await this._waitForDiagnostics(uri);

    // Clean up — close the document on the server side
    try {
      await this._connection!.sendNotification(DidCloseTextDocumentNotification.type, {
        textDocument: { uri },
      });
    } catch {
      // best-effort
    }

    return result;
  }

  /** Go to the definition of the symbol at the given position. */
  async gotoDefinition(
    filePath: string, line: number, character: number,
  ): Promise<Definition | null> {
    this._ensureConnected();
    const uri = this._toFileUri(filePath);
    await this._openDocument(uri, filePath);
    const result = await this._connection!.sendRequest(DefinitionRequest.type, {
      textDocument: { uri }, position: { line, character },
    });
    await this._closeDocument(uri);
    return (result as Definition | null) ?? null;
  }

  /** Find all references to the symbol at the given position. */
  async findReferences(
    filePath: string,
    line: number,
    character: number,
    includeDeclaration: boolean = true,
  ): Promise<Location[]> {
    this._ensureConnected();
    const uri = this._toFileUri(filePath);

    await this._openDocument(uri, filePath);

    const result = await this._connection!.sendRequest(ReferencesRequest.type, {
      textDocument: { uri },
      position: { line, character },
      context: { includeDeclaration },
    });

    await this._closeDocument(uri);
    return result ?? [];
  }

  /** Get hover information for the symbol at the given position. */
  async getHover(
    filePath: string,
    line: number,
    character: number,
  ): Promise<Hover | null> {
    this._ensureConnected();
    const uri = this._toFileUri(filePath);

    await this._openDocument(uri, filePath);

    const result = await this._connection!.sendRequest(HoverRequest.type, {
      textDocument: { uri },
      position: { line, character },
    });

    await this._closeDocument(uri);
    return result ?? null;
  }

  /** List all symbols in the given document (hierarchical). */
  async getDocumentSymbols(filePath: string): Promise<DocumentSymbol[]> {
    this._ensureConnected();
    const uri = this._toFileUri(filePath);

    await this._openDocument(uri, filePath);

    const result = await this._connection!.sendRequest(DocumentSymbolRequest.type, {
      textDocument: { uri },
    });

    await this._closeDocument(uri);
    return (result ?? []) as DocumentSymbol[];
  }

  // -- private helpers ------------------------------------------------------

  private _ensureConnected(): void {
    if (!this._connected || !this._connection) {
      throw new Error(
        'Godot Language Server is not available. ' +
        'Enable it in Godot: Editor Settings → Network → Language Server → Enable. ' +
        'Then restart the MCP server.',
      );
    }
  }

  /** Convert a res:// (or relative) path to a file:// URI using the project root. */
  private _toFileUri(godotPath: string): string {
    const normalized = godotPath.replace(/\\/g, '/');

    if (normalized.startsWith('res://')) {
      if (!this._projectRoot) {
        throw new Error(
          'Cannot resolve res:// paths — project root is unknown. ' +
          'Wait for Godot editor to connect before using LSP tools.',
        );
      }
      const relPath = normalized.slice('res://'.length);
      const absPath = path.join(this._projectRoot, relPath).replace(/\\/g, '/');
      return `file:///${absPath}`;
    }

    if (/^[A-Za-z]:/.test(normalized)) {
      return `file:///${normalized}`;
    }

    // Assume it's already a file:// URI
    return normalized;
  }

  /** Read file content from the filesystem. */
  private _readFileContent(filePath: string): string {
    const uri = this._toFileUri(filePath);

    // Strip file:// prefix to get the filesystem path
    let fsPath = uri;
    if (fsPath.startsWith('file:///')) {
      fsPath = fsPath.slice('file:///'.length);
      // On Windows, the path is like "D:/path/to/file"
      // No need to strip leading / since we already consumed file:///
    }

    if (!fs.existsSync(fsPath)) {
      throw new Error(`File not found on disk: ${fsPath}`);
    }
    return fs.readFileSync(fsPath, 'utf-8');
  }

  /** Open a document so the LSP server knows about it. */
  private async _openDocument(uri: string, filePath: string): Promise<void> {
    const content = this._readFileContent(filePath);
    await this._connection!.sendNotification(DidOpenTextDocumentNotification.type, {
      textDocument: {
        uri,
        languageId: 'gdscript',
        version: 1,
        text: content,
      },
    });
    // Give the server a moment to parse the document
    await new Promise(resolve => setTimeout(resolve, 100));
  }

  private async _closeDocument(uri: string): Promise<void> {
    try {
      await this._connection!.sendNotification(DidCloseTextDocumentNotification.type, {
        textDocument: { uri },
      });
    } catch {
      // best-effort
    }
  }

  /**
   * Poll the diagnostics cache until a stable result is available.
   *
   * Godot LSP may publish diagnostics in multiple rounds (e.g. an empty
   * batch first, then the real errors after parsing completes).  We wait
   * at least 300 ms, then require a 200 ms quiet window before returning.
   */
  private async _waitForDiagnostics(uri: string): Promise<Diagnostic[]> {
    const start = Date.now();
    let lastCount = -1;

    while (Date.now() - start < DIAGNOSTICS_TIMEOUT_MS) {
      // Check both the file:// URI and the res:// fallback
      let cached = this._diagnosticsCache.get(uri);
      if (cached === undefined) {
        const resUri = this._uriToResUri(uri);
        if (resUri) cached = this._diagnosticsCache.get(resUri);
      }

      const currentCount = cached !== undefined ? cached.length : -1;
      const elapsed = Date.now() - start;

      // We have a result — require a settle period to make sure Godot
      // isn't about to send a more complete batch.
      if (cached !== undefined && elapsed >= 300) {
        // Wait 200 ms more to see if the count changes
        await new Promise(resolve => setTimeout(resolve, 200));
        const recheck = this._diagnosticsCache.get(uri)
          ?? (() => { const r = this._uriToResUri(uri); return r ? this._diagnosticsCache.get(r) : undefined; })();
        const recheckCount = recheck !== undefined ? recheck.length : -1;

        if (recheckCount === currentCount) {
          return cached;
        }
        // Count changed — Godot is still publishing, keep polling
        lastCount = recheckCount;
        continue;
      }

      if (cached !== undefined) {
        lastCount = currentCount;
      }

      await new Promise(resolve => setTimeout(resolve, 100));
    }

    // Timeout — return whatever we have
    return this._diagnosticsCache.get(uri)
      ?? (() => { const r = this._uriToResUri(uri); return r ? this._diagnosticsCache.get(r) : undefined; })()
      ?? [];
  }

  /**
   * If `uri` is a file:// URI inside the project root, return the
   * equivalent res:// URI.  Godot LSP sometimes publishes diagnostics
   * with res:// URIs internally.
   */
  private _uriToResUri(uri: string): string | null {
    if (!this._projectRoot) return null;
    if (!uri.startsWith('file:///')) return null;

    // Normalize for comparison: lowercase drive letter, strip file:///
    const absPath = uri.slice('file:///'.length).replace(/\\/g, '/');
    const root = this._projectRoot.replace(/\\/g, '/');

    // Case-insensitive prefix match (Windows drive letters)
    if (absPath.toLowerCase().startsWith(root.toLowerCase())) {
      const relPath = absPath.slice(root.length).replace(/^\//, '');
      return `res://${relPath}`;
    }
    return null;
  }

  // -- symbol kind helpers --------------------------------------------------

  /** Convert a SymbolKind number to a human-readable label. */
  static symbolKindToString(kind: SymbolKind): string {
    const labels: Record<number, string> = {
      1: 'file', 2: 'module', 3: 'namespace', 4: 'package', 5: 'class',
      6: 'method', 7: 'property', 8: 'field', 9: 'constructor', 10: 'enum',
      11: 'interface', 12: 'function', 13: 'variable', 14: 'constant',
      15: 'string', 16: 'number', 17: 'boolean', 18: 'array', 19: 'object',
      20: 'key', 21: 'null', 22: 'enum member', 23: 'struct', 24: 'event',
      25: 'operator', 26: 'type parameter',
    };
    return labels[kind] ?? `kind-${kind}`;
  }
}
