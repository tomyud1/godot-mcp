/**
 * The token file is the root of trust for two of the three local listeners,
 * and its create-or-adopt logic is what keeps a primary and its proxies
 * agreeing on one secret. It runs in a genuinely racy context — several MCP
 * servers can start simultaneously — so it is worth pinning down directly
 * rather than relying on the end-to-end tests, which only ever exercise the
 * happy path.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, existsSync, readFileSync, statSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { resolveTokenFromFile, createEphemeralToken, hasBrowserOrigin, isAuthorized } from '../auth.js';

let dir: string;
let tokenPath: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'godot-mcp-auth-'));
  tokenPath = join(dir, 'nested', 'auth-token');
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe('resolveTokenFromFile', () => {
  it('creates the file and its parent directory on first use', () => {
    const token = resolveTokenFromFile(tokenPath);
    expect(token).toBeTruthy();
    expect(existsSync(tokenPath)).toBe(true);
    expect(readFileSync(tokenPath, 'utf8')).toBe(token);
  });

  it('creates the token file readable only by its owner', () => {
    // Skip on platforms where POSIX modes are not meaningful.
    if (process.platform === 'win32') return;
    resolveTokenFromFile(tokenPath);
    const mode = statSync(tokenPath).mode & 0o777;
    expect(mode).toBe(0o600);
  });

  it('returns the same token on a second call, so restarts agree', () => {
    const first = resolveTokenFromFile(tokenPath);
    const second = resolveTokenFromFile(tokenPath);
    expect(second).toBe(first);
  });

  it('adopts a token left by a previous run rather than replacing it', () => {
    // Two servers racing: the loser must use the winner's secret, or the
    // primary and its proxies would disagree and every call would 401.
    mkdirSync(join(dir, 'nested'), { recursive: true });
    writeFileSync(tokenPath, 'pre-existing-token');
    expect(resolveTokenFromFile(tokenPath)).toBe('pre-existing-token');
  });

  it('replaces an empty token file rather than adopting an empty secret', () => {
    mkdirSync(join(dir, 'nested'), { recursive: true });
    writeFileSync(tokenPath, '');
    const token = resolveTokenFromFile(tokenPath);
    expect(token).toBeTruthy();
    expect(token).not.toBe('');
  });

  it('generates a distinct token per file', () => {
    const otherPath = join(dir, 'nested', 'other-token');
    expect(resolveTokenFromFile(tokenPath)).not.toBe(resolveTokenFromFile(otherPath));
  });

  it('returns null when the token cannot be persisted, so callers fail closed', () => {
    // A path whose parent is a regular file cannot be created.
    const blocker = join(dir, 'blocker');
    writeFileSync(blocker, 'x');
    expect(resolveTokenFromFile(join(blocker, 'auth-token'))).toBeNull();
  });
});

describe('createEphemeralToken', () => {
  it('produces a different value each time', () => {
    expect(createEphemeralToken()).not.toBe(createEphemeralToken());
  });

  it('produces a long enough secret', () => {
    expect(createEphemeralToken().length).toBeGreaterThanOrEqual(32);
  });
});

describe('isAuthorized', () => {
  const TOKEN = 'a'.repeat(64);

  it('accepts a correct bearer header', () => {
    expect(isAuthorized({ authorization: `Bearer ${TOKEN}` }, TOKEN)).toBe(true);
  });

  it('is case-insensitive about the scheme', () => {
    expect(isAuthorized({ authorization: `bearer ${TOKEN}` }, TOKEN)).toBe(true);
  });

  it('rejects a wrong token', () => {
    expect(isAuthorized({ authorization: 'Bearer nope' }, TOKEN)).toBe(false);
  });

  it('rejects a token of a different length without throwing', () => {
    expect(isAuthorized({ authorization: 'Bearer short' }, TOKEN)).toBe(false);
  });

  it('rejects a missing header', () => {
    expect(isAuthorized({}, TOKEN)).toBe(false);
    expect(isAuthorized({ authorization: 'Bearer ' }, TOKEN)).toBe(false);
    expect(isAuthorized({ authorization: TOKEN }, TOKEN)).toBe(false);
  });

  it('accepts the token as a query parameter, for WebSocket upgrades', () => {
    expect(isAuthorized({}, TOKEN, `/ws?token=${TOKEN}`)).toBe(true);
  });

  it('rejects a wrong query token', () => {
    expect(isAuthorized({}, TOKEN, '/ws?token=nope')).toBe(false);
  });

  it('rejects when neither header nor query carries it', () => {
    expect(isAuthorized({}, TOKEN, '/ws')).toBe(false);
  });
});

describe('hasBrowserOrigin', () => {
  it('detects a browser handshake', () => {
    expect(hasBrowserOrigin({ origin: 'https://evil.example.com' })).toBe(true);
    expect(hasBrowserOrigin({ Origin: 'null' })).toBe(true);
  });

  it('treats a Godot handshake as non-browser', () => {
    // WebSocketPeer sends no Origin header at all.
    expect(hasBrowserOrigin({})).toBe(false);
    expect(hasBrowserOrigin({ host: '127.0.0.1:6505' })).toBe(false);
  });
});
