/**
 * Reproduces the handshake probes a strict MCP client performs.
 *
 * Codex probes `resources/templates/list` on startup. Because we advertise the
 * `resources` capability, that probe is legitimate — and answering it with
 * -32601 made Codex display the server as "failed" even though all 86 tools
 * loaded fine. These tests drive the real request handlers so the same
 * regression cannot come back quietly.
 */
import { describe, it, expect, afterEach } from 'vitest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ListResourcesRequestSchema,
  ListResourceTemplatesRequestSchema,
  ReadResourceRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { registerResources, GUIDES } from '../resources.js';
import { allTools, advertisedTools } from '../tools/index.js';
import { deriveAnnotations, builtinToolAnnotations, requiresUserInteraction } from '../tools/annotations.js';
import { withStructuredContentForTest } from '../result-normalize.js';

let client: Client | null = null;

afterEach(async () => {
  await client?.close();
  client = null;
});

async function connect(): Promise<Client> {
  const server = new Server(
    { name: 'godot-mcp-server', version: 'test' },
    { capabilities: { tools: {}, resources: {} } }
  );

  registerResources(server);
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
      { name: 'get_godot_status', description: 'status', inputSchema: { type: 'object', properties: {} }, annotations: builtinToolAnnotations('get_godot_status') },
      { name: 'get_guide', description: 'guide', inputSchema: { type: 'object', properties: {} }, annotations: builtinToolAnnotations('get_guide') },
      ...advertisedTools.map((t) => ({
        name: t.name,
        description: t.description,
        inputSchema: t.inputSchema,
        annotations: deriveAnnotations(t),
        ...(requiresUserInteraction(t.name) ? { _meta: { 'anthropic/requiresUserInteraction': true } } : {}),
      })),
    ],
  }));
  server.setRequestHandler(CallToolRequestSchema, async (req) =>
    withStructuredContentForTest({
      content: [{ type: 'text', text: JSON.stringify({ ok: true, tool: req.params.name }) }],
    })
  );

  const [c, s] = InMemoryTransport.createLinkedPair();
  const sc = new Client({ name: 'strict-client', version: '1' });
  await Promise.all([sc.connect(c), server.connect(s)]);
  client = sc;
  return sc;
}

describe('handshake probes strict clients perform', () => {
  it('answers resources/templates/list instead of -32601', async () => {
    // This is the exact call that made Codex show the server as failed.
    const c = await connect();
    const result = await c.listResourceTemplates();
    expect(result.resourceTemplates).toEqual([]);
  });

  it('answers resources/list with the guides', async () => {
    const c = await connect();
    const result = await c.listResources();
    expect(result.resources).toHaveLength(GUIDES.length);
    expect(result.resources.every((r) => r.uri.startsWith('godot-mcp://'))).toBe(true);
  });

  it('reads a guide by uri', async () => {
    const c = await connect();
    const result = await c.readResource({ uri: GUIDES[0].uri });
    const first = result.contents[0] as { text: string };
    expect(first.text.length).toBeGreaterThan(0);
  });

  it('lists every advertised tool with annotations', async () => {
    const c = await connect();
    const result = await c.listTools();
    // 84 advertised tools + the two injected builtins.
    expect(result.tools.length).toBe(advertisedTools.length + 2);
    for (const tool of result.tools) {
      expect(tool.annotations, `${tool.name} needs annotations`).toBeDefined();
      expect(typeof tool.annotations!.readOnlyHint).toBe('boolean');
    }
  });

  it('flags destructive tools so the client can gate them', async () => {
    const c = await connect();
    const result = await c.listTools();
    const del = result.tools.find((t) => t.name === 'delete_file');
    expect(del?.annotations?.destructiveHint).toBe(true);
    const read = result.tools.find((t) => t.name === 'read_file');
    expect(read?.annotations?.readOnlyHint).toBe(true);
  });

  it('omits hidden aliases from the advertised list', async () => {
    const c = await connect();
    const result = await c.listTools();
    const names = result.tools.map((t) => t.name);
    expect(names).not.toContain('modify_node_property');
    expect(names).toContain('set_scene_node_property');
  });

  it('returns structuredContent on a tool call', async () => {
    const c = await connect();
    const result = await c.callTool({ name: 'read_file', arguments: {} });
    expect(result.structuredContent).toMatchObject({ ok: true, tool: 'read_file' });
  });
});
