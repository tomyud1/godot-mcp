/**
 * Checks the visualizer's own listener. The page and the WebSocket upgrade
 * must agree on the token, so this drives a real handshake rather than only
 * the predicate — a `path` vs query-string mismatch would otherwise only show
 * up in a browser.
 */
import { describe, it, expect, afterAll, beforeAll } from 'vitest';
import { WebSocket } from 'ws';
import http from 'node:http';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { serveVisualization, stopVisualizationServer, authorizeVisualizerUpgrade } from '../visualizer-server.js';

const TOKEN = 'visualizer-test-token';
let port = 0;

/** Attempt a real upgrade against the visualizer's /ws path. */
function tryUpgrade(query: string, token?: string): Promise<boolean> {
  return new Promise((resolve) => {
    const headers: Record<string, string> = {};
    if (token) headers.Authorization = `Bearer ${token}`;
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws${query}`, { headers });
    const done = (ok: boolean) => {
      try { ws.close(); } catch { /* already closed */ }
      resolve(ok);
    };
    ws.on('open', () => done(true));
    ws.on('error', () => done(false));
    setTimeout(() => done(false), 4000);
  });
}

function get(path: string, headers: Record<string, string> = {}): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    http.get({ hostname: '127.0.0.1', port, path, headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode!, body: Buffer.concat(chunks).toString() }));
    }).on('error', reject);
  });
}

beforeAll(async () => {
  // A minimal stand-in for the bundled page: these tests are about the
  // upgrade handshake and origin policy, not the rendered graph.
  const dir = mkdtempSync(join(tmpdir(), 'godot-mcp-viz-'));
  const templatePath = join(dir, 'visualizer.html');
  writeFileSync(templatePath, '<!DOCTYPE html><html><body>project map</body></html>');

  const url = await serveVisualization(
    { scripts: [], total_scripts: 0, total_connections: 0 },
    { token: TOKEN, openBrowser: false, templatePath }
  );
  port = Number(new URL(url).port);
});

afterAll(() => {
  stopVisualizationServer();
});

describe('visualizer WebSocket authorization', () => {
  it('refuses an upgrade with no token', async () => {
    expect(await tryUpgrade('')).toBe(false);
  });

  it('refuses an upgrade with the wrong token', async () => {
    expect(await tryUpgrade('?token=deadbeef')).toBe(false);
  });

  it('accepts the correct token as a query parameter', async () => {
    // The page carries the token this way, and `path: '/ws'` must still match
    // the pathname when a query string is present.
    expect(await tryUpgrade(`?token=${TOKEN}`)).toBe(true);
  });

  it('accepts the correct token as a bearer header', async () => {
    expect(await tryUpgrade('', TOKEN)).toBe(true);
  });
});

describe('visualizer page origin policy', () => {
  it('serves the page to a local client', async () => {
    const res = await get('/');
    expect(res.status).toBe(200);
  });

  it('refuses a cross-origin page load', async () => {
    const res = await get('/', { Origin: 'https://evil.example.com' });
    expect(res.status).toBe(403);
  });

  it('allows the local origin', async () => {
    const res = await get('/', { Origin: `http://localhost:${port}` });
    expect(res.status).toBe(200);
  });
});

describe('authorizeVisualizerUpgrade', () => {
  it('matches the live session token', () => {
    expect(authorizeVisualizerUpgrade({}, `/ws?token=${TOKEN}`)).toBe(true);
    expect(authorizeVisualizerUpgrade({}, '/ws?token=wrong')).toBe(false);
    expect(authorizeVisualizerUpgrade({}, '/ws')).toBe(false);
  });
});
