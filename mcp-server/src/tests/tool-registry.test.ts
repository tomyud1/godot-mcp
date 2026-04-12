import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, it, expect } from 'vitest';
import { allTools, toolExists } from '../tools/index.js';

function getExecutorToolNames(): Set<string> {
  const testDir = path.dirname(fileURLToPath(import.meta.url));
  const executorPath = path.resolve(testDir, '../../../addons/godot_mcp/tool_executor.gd');
  const source = readFileSync(executorPath, 'utf8');
  const toolNames = [...source.matchAll(/&"([^"]+)": \[_[a-z_]+, &"[^"]+"\]/g)]
    .map(match => match[1])
    .filter(name => !name.startsWith('visualizer._internal_'));

  return new Set(toolNames);
}

describe('Tool registry', () => {
  it('exports a non-empty list of tools', () => {
    expect(allTools.length).toBeGreaterThan(0);
  });

  it('every tool has name, description, and inputSchema', () => {
    for (const tool of allTools) {
      expect(typeof tool.name).toBe('string');
      expect(tool.name.length).toBeGreaterThan(0);
      expect(typeof tool.description).toBe('string');
      expect(tool.description.length).toBeGreaterThan(0);
      expect(tool.inputSchema.type).toBe('object');
      expect(tool.inputSchema.properties).toBeDefined();
    }
  });

  it('tool names are unique', () => {
    const names = allTools.map((t) => t.name);
    expect(new Set(names).size).toBe(names.length);
  });

  it('toolExists returns true for known tools', () => {
    const firstTool = allTools[0].name;
    expect(toolExists(firstTool)).toBe(true);
  });

  it('toolExists returns false for unknown tools', () => {
    expect(toolExists('definitely_not_a_tool_xyz')).toBe(false);
  });

  it('includes mesh and material tools in the advertised MCP registry', () => {
    expect(toolExists('set_mesh')).toBe(true);
    expect(toolExists('set_material')).toBe(true);
  });

  it('includes new 3D spatial workflow tools in the advertised MCP registry', () => {
    expect(toolExists('get_node_spatial_info')).toBe(true);
    expect(toolExists('measure_node_distance')).toBe(true);
    expect(toolExists('snap_node_to_grid')).toBe(true);
    expect(toolExists('place_node_relative')).toBe(true);
  });

  it('every advertised MCP tool is registered in the Godot executor map', () => {
    const executorTools = getExecutorToolNames();
    const missing = allTools
      .map(tool => tool.name)
      .filter(name => !executorTools.has(name));

    expect(missing).toEqual([]);
  });
});
