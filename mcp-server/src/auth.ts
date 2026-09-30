/**
 * Shared-secret authentication for the local HTTP / WebSocket surfaces.
 *
 * Why this exists
 * ---------------
 * The server exposes three localhost listeners that can drive the Godot
 * editor: the bridge WebSocket (6505), the primary HTTP API (6506) that
 * proxies forward tool calls through, and the visualizer (6510). Any local
 * process — including a webpage that a browser is tricked into opening a
 * WebSocket against — could otherwise call arbitrary editor tools.
 *
 * The MCP spec's security guidance is explicit that local servers should
 * require an authorization token when they must use a non-stdio transport.
 *
 * Token resolution order
 * ----------------------
 *   1. `GODOT_MCP_TOKEN` environment variable (useful for CI / containers)
 *   2. A per-user token file, created on first use with 0600 permissions
 *
 * The file is deliberately stable across restarts so that a primary and its
 * proxy instances agree without any out-of-band handshake.
 */

import { randomBytes, timingSafeEqual } from 'node:crypto';
import { chmodSync, mkdirSync, readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

const TOKEN_BYTES = 32;
const DIR_NAME = '.godot-mcp';
const FILE_NAME = 'auth-token';

/** Lazily resolved so tests can override the environment before first use. */
let cached: string | null = null;

function tokenFilePath(): string {
  return join(homedir(), DIR_NAME, FILE_NAME);
}

/**
 * Create the token file exclusively (`wx`) so that two servers racing to
 * become primary cannot each write a different token — the loser re-reads
 * the winner's value instead.
 */
function createTokenFile(path: string, dir: string): string {
  const token = randomBytes(TOKEN_BYTES).toString('hex');
  try {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  } catch {
    // Directory may already exist, or be unwritable. Write will surface it.
  }

  try {
    writeFileSync(path, token, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
    return token;
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === 'EEXIST') {
      // Another process won the race — adopt its token so every client of the
      // same primary agrees on one secret.
      return readFileSync(path, 'utf8').trim();
    }
    throw err;
  }
}

/**
 * Resolve the token from disk, creating it on first use.
 *
 * Split out from getAuthToken() so it can be exercised against a temp path
 * without touching the real token file or the module-level cache. Returns null
 * only if the token could not be persisted, in which case callers must fail
 * closed rather than run unauthenticated.
 */
export function resolveTokenFromFile(path: string): string | null {
  const dir = dirname(path);

  if (existsSync(path)) {
    try {
      const existing = readFileSync(path, 'utf8').trim();
      if (existing) return existing;
      // Empty or whitespace-only: no usable secret. It must be replaced —
      // createTokenFile uses the `wx` flag, so leaving the stub in place would
      // hit EEXIST and hand back the same empty value forever.
      unlinkSync(path);
    } catch {
      // Unreadable or unremovable — fall through and let the create surface it.
    }
  }

  try {
    return createTokenFile(path, dir);
  } catch (err) {
    console.error(`[auth] Could not persist a token at ${path}: ${(err as Error).message}`);
    return null;
  }
}

/**
 * Resolve the shared token, creating it on first use.
 * Returns null only if the token could not be persisted, in which case
 * callers should fail closed rather than run unauthenticated.
 */
export function getAuthToken(): string | null {
  if (cached) return cached;

  const fromEnv = process.env.GODOT_MCP_TOKEN?.trim();
  if (fromEnv) {
    cached = fromEnv;
    return cached;
  }

  const path = tokenFilePath();
  const resolved = resolveTokenFromFile(path);
  if (resolved) {
    cached = resolved;
    // Best-effort hardening: the file is created 0600 via the mode option,
    // but an existing file with looser permissions is tightened here.
    try {
      chmodSync(path, 0o600);
    } catch {
      // Non-fatal.
    }
  }
  return cached;
}

/** Mint an independent, in-memory token (used for the visualizer session). */
export function createEphemeralToken(): string {
  return randomBytes(TOKEN_BYTES).toString('hex');
}

/** Constant-time string comparison that tolerates length mismatches. */
function tokensMatch(a: string | undefined | null, b: string | undefined | null): boolean {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const bufA = Buffer.from(a, 'utf8');
  const bufB = Buffer.from(b, 'utf8');
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}

/**
 * Extract a bearer token from an incoming request.
 * Accepts `Authorization: Bearer <token>` and, for the WebSocket upgrade
 * only, a `?token=` query parameter (browsers cannot set custom headers on
 * a WebSocket handshake).
 */
function extractToken(headers: Record<string, unknown>, url?: string): string | null {
  const auth = headers['authorization'] ?? headers['Authorization'];
  if (typeof auth === 'string') {
    const match = /^Bearer\s+(.+)$/i.exec(auth.trim());
    if (match) return match[1].trim();
  }

  if (url) {
    const queryStart = url.indexOf('?');
    if (queryStart !== -1) {
      const params = new URLSearchParams(url.slice(queryStart + 1));
      const token = params.get('token');
      if (token) return token;
    }
  }

  return null;
}

/** True when the header value is a `Bearer <expected>` match. */
export function isAuthorized(headers: Record<string, unknown>, expected: string, url?: string): boolean {
  return tokensMatch(extractToken(headers, url), expected);
}

/**
 * A WebSocket handshake carrying an `Origin` header is coming from a browser.
 * Godot's `WebSocketPeer` never sends one. This is the defence that stops a
 * hostile web page from driving the editor through the bridge, and it needs
 * no coordinated change in the addon (so older AssetLib installs keep
 * working).
 */
export function hasBrowserOrigin(headers: Record<string, unknown>): boolean {
  const origin = headers['origin'] ?? headers['Origin'];
  return typeof origin === 'string' && origin.length > 0;
}
