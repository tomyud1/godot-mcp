/**
 * LSP TCP Transport Layer
 *
 * Implements MessageReader / MessageWriter over a raw TCP socket using the
 * standard LSP framing: Content-Length: N\r\n\r\n + JSON body.
 *
 * Designed to connect to Godot's built-in Language Server Protocol server.
 */
import * as net from 'net';
import type { MessageReader, MessageWriter, DataCallback, PartialMessageInfo, Event, Disposable, Message } from 'vscode-jsonrpc';

// ---------------------------------------------------------------------------
// Simple Event emitter (compatible with vscode-jsonrpc Event<T>)
// ---------------------------------------------------------------------------

type Listener<T> = (e: T) => void;

function createEvent<T>(): { event: Event<T>; fire: (e: T) => void; dispose: () => void } {
  const listeners: Array<[Listener<T>, unknown, Disposable[]?]> = [];
  const event: Event<T> = (listener: Listener<T>, _thisArgs?: unknown, _disposables?: Disposable[]) => {
    listeners.push([listener, _thisArgs, _disposables]);
    return { dispose: () => { /* no-op */ } };
  };
  const fire = (e: T) => {
    for (const [listener] of listeners) {
      try { listener(e); } catch { /* swallow */ }
    }
  };
  const dispose = () => { listeners.length = 0; };
  return { event, fire, dispose };
}

export class LspMessageReader implements MessageReader {
  private _socket: net.Socket;
  private _buffer: Buffer = Buffer.alloc(0);
  private _callback: DataCallback | null = null;
  private _disposed = false;

  // Saved handler refs: we use named callbacks + socket.off() instead of
  // socket.removeAllListeners() so externally-added error sinks (e.g. the
  // permanent error swallow in createLspTransport) survive dispose().
  private _onDataHandler: (chunk: Buffer) => void;
  private _onErrorHandler: (err: Error) => void;
  private _onCloseHandler: () => void;

  private _onErrorEvent = createEvent<Error>();
  private _onCloseEvent = createEvent<void>();
  private _onPartialMessageEvent = createEvent<PartialMessageInfo>();

  constructor(socket: net.Socket) {
    this._socket = socket;
    this._onDataHandler = (chunk: Buffer) => this._onData(chunk);
    this._onErrorHandler = (err: Error) => this._onErrorEvent.fire(err);
    this._onCloseHandler = () => this._onCloseEvent.fire(undefined as void);
    this._socket.on('data', this._onDataHandler);
    this._socket.on('error', this._onErrorHandler);
    this._socket.on('close', this._onCloseHandler);
  }

  get onError(): Event<Error> { return this._onErrorEvent.event; }
  get onClose(): Event<void> { return this._onCloseEvent.event; }
  get onPartialMessage(): Event<PartialMessageInfo> { return this._onPartialMessageEvent.event; }

  listen(callback: DataCallback): Disposable {
    this._callback = callback;
    return { dispose: () => { this._callback = null; } };
  }

  dispose(): void {
    if (this._disposed) return;
    this._disposed = true;
    this._callback = null;
    this._socket.off('data', this._onDataHandler);
    this._socket.off('error', this._onErrorHandler);
    this._socket.off('close', this._onCloseHandler);
    this._buffer = Buffer.alloc(0);
    this._onErrorEvent.dispose();
    this._onCloseEvent.dispose();
    this._onPartialMessageEvent.dispose();
  }

  // --- internal framing parser ---

  private _onData(chunk: Buffer): void {
    this._buffer = Buffer.concat([this._buffer, chunk]);
    this._tryParseMessages();
  }

  private _tryParseMessages(): void {
    while (true) {
      const header = 'Content-Length: ';
      const headerIdx = this._buffer.indexOf(header, 0, 'utf-8');
      if (headerIdx === -1) return;

      const bodySep = this._buffer.indexOf('\r\n\r\n', headerIdx, 'utf-8');
      if (bodySep === -1) return;

      const lenStart = headerIdx + header.length;
      const lenStr = this._buffer.subarray(lenStart, bodySep).toString('utf-8').trim();
      const contentLen = parseInt(lenStr, 10);
      if (isNaN(contentLen)) {
        this._onErrorEvent.fire(new Error(`Invalid Content-Length in LSP frame: "${lenStr}"`));
        return;
      }

      const bodyStart = bodySep + 4;
      if (this._buffer.length < bodyStart + contentLen) return;

      const body = this._buffer.subarray(bodyStart, bodyStart + contentLen);
      const msg = body.toString('utf-8');
      this._buffer = this._buffer.subarray(bodyStart + contentLen);

      // Parse JSON and pass as Message
      const parsed = JSON.parse(msg) as Message;
      this._callback?.(parsed);
    }
  }
}

export class LspMessageWriter implements MessageWriter {
  private _socket: net.Socket;
  private _disposed = false;

  private _onErrorHandler: (err: Error) => void;
  private _onCloseHandler: () => void;

  private _onErrorEvent = createEvent<[Error, Message | undefined, number | undefined]>();
  private _onCloseEvent = createEvent<void>();

  constructor(socket: net.Socket) {
    this._socket = socket;
    this._onErrorHandler = (err: Error) => this._onErrorEvent.fire([err, undefined, undefined]);
    this._onCloseHandler = () => this._onCloseEvent.fire(undefined as void);
    this._socket.on('error', this._onErrorHandler);
    this._socket.on('close', this._onCloseHandler);
  }

  get onError(): Event<[Error, Message | undefined, number | undefined]> { return this._onErrorEvent.event; }
  get onClose(): Event<void> { return this._onCloseEvent.event; }

  async write(msg: unknown): Promise<void> {
    const json = JSON.stringify(msg);
    const contentLen = Buffer.byteLength(json, 'utf-8');
    const header = `Content-Length: ${contentLen}\r\n\r\n`;
    const frame = Buffer.concat([
      Buffer.from(header, 'utf-8'),
      Buffer.from(json, 'utf-8'),
    ]);

    return new Promise<void>((resolve, reject) => {
      this._socket.write(frame, (err?: Error | null) => {
        if (err) {
          this._onErrorEvent.fire([err, undefined, undefined]);
          reject(err);
        } else {
          resolve();
        }
      });
    });
  }

  end(): void { this._socket.end(); }

  dispose(): void {
    if (this._disposed) return;
    this._disposed = true;
    this._socket.off('error', this._onErrorHandler);
    this._socket.off('close', this._onCloseHandler);
    this._onErrorEvent.dispose();
    this._onCloseEvent.dispose();
  }

  /** Compute byte length for end-of-message detection. */
  getWriteByteCount?(msg: unknown): number {
    const json = JSON.stringify(msg);
    return Buffer.byteLength(json, 'utf-8');
  }
}

// ---------------------------------------------------------------------------
// createLspTransport
// ---------------------------------------------------------------------------

/**
 * Create an LSP transport pair (reader + writer) for the given port.
 *
 * IMPORTANT: the socket is created but NOT connected here. The caller must
 * call `socket.connect({ host, port })` AFTER wiring up `connect` / `error`
 * event listeners on the socket. This avoids a race condition where the
 * connection completes before the listeners are registered.
 */
export function createLspTransport(): {
  reader: LspMessageReader;
  writer: LspMessageWriter;
  socket: net.Socket;
} {
  const socket = new net.Socket();
  socket.setNoDelay(true);

  // Permanent error sink — installed BEFORE LspMessageReader /
  // LspMessageWriter add their own listeners.  This ensures that
  // NO error event on the socket can ever become an uncaught
  // exception, even after dispose() cleans up the transport layer.
  socket.on('error', () => { /* swallowed */ });

  return {
    reader: new LspMessageReader(socket),
    writer: new LspMessageWriter(socket),
    socket,
  };
}
