/**
 * The fail-closed rule for the primary's HTTP bridge.
 *
 * `/tool` can drive the Godot editor, so a primary that starts without a
 * usable token is an open door to every local process. `startPrimary` is not
 * importable in isolation, so the decision is extracted to requireAuthToken()
 * and pinned down here.
 */
import { describe, it, expect, afterEach, vi } from 'vitest';

const ORIGINAL_ENV = process.env.GODOT_MCP_TOKEN;
const ORIGINAL_HOME = process.env.HOME;

afterEach(() => {
  if (ORIGINAL_ENV === undefined) delete process.env.GODOT_MCP_TOKEN;
  else process.env.GODOT_MCP_TOKEN = ORIGINAL_ENV;
  if (ORIGINAL_HOME === undefined) delete process.env.HOME;
  else process.env.HOME = ORIGINAL_HOME;
  vi.resetModules();
});

type Decision = { ok: true; token: string } | { ok: false; reason: string };

/**
 * Load a fresh copy of the module so its token cache starts empty; the decision
 * depends on the environment at call time, not at import time.
 */
async function freshRequireAuthToken(): Promise<() => Decision> {
  vi.resetModules();
  const mod = await import('../index.js');
  return mod.requireAuthToken as () => Decision;
}

describe('requireAuthToken', () => {
  it('fails closed when no token can be established', async () => {
    // Point HOME at a path that cannot hold a token file, and clear the env
    // override, so resolution genuinely fails.
    const requireAuthToken = await freshRequireAuthToken();
    delete process.env.GODOT_MCP_TOKEN;
    process.env.HOME = '/dev/null/nope';

    const result = requireAuthToken();
    expect(result.ok).toBe(false);
  });

  it('explains how to fix it when it refuses', async () => {
    const requireAuthToken = await freshRequireAuthToken();
    delete process.env.GODOT_MCP_TOKEN;
    process.env.HOME = '/dev/null/nope';

    const result = requireAuthToken();
    expect(result.ok).toBe(false);
    if (result.ok) throw new Error('expected a refusal');
    // The message is read by a human staring at a dead server; it must say
    // what to do, not just that something went wrong.
    expect(result.reason).toMatch(/GODOT_MCP_TOKEN/);
    expect(result.reason).toMatch(/home directory/i);
  });

  it('never returns an empty token, which would leave auth effectively off', async () => {
    const requireAuthToken = await freshRequireAuthToken();
    delete process.env.GODOT_MCP_TOKEN;
    process.env.HOME = '/dev/null/nope';

    const result = requireAuthToken();
    if (result.ok) throw new Error('expected a refusal');
    expect('token' in result).toBe(false);
  });

  it('accepts an explicitly configured token', async () => {
    const requireAuthToken = await freshRequireAuthToken();
    process.env.GODOT_MCP_TOKEN = 'configured-token-value';

    const result = requireAuthToken();
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error('expected success');
    expect(result.token).toBe('configured-token-value');
  });

  it('does not pass an undefined token through on success', async () => {
    const requireAuthToken = await freshRequireAuthToken();
    process.env.GODOT_MCP_TOKEN = 'another-token';

    const result = requireAuthToken();
    if (!result.ok) throw new Error('expected success');
    expect(typeof result.token).toBe('string');
    expect(result.token.length).toBeGreaterThan(0);
  });
});
