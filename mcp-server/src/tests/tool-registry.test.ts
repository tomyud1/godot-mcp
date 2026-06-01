import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, it, expect } from 'vitest';
import { allTools, toolExists } from '../tools/index.js';
import { RUNTIME_ONLY_TOOLS } from '../godot-bridge.js';

function getExecutorToolNames(): Set<string> {
  const testDir = path.dirname(fileURLToPath(import.meta.url));
  const executorPath = path.resolve(testDir, '../../../addons/godot_mcp/tool_executor.gd');
  const source = readFileSync(executorPath, 'utf8');
  const toolNames = [...source.matchAll(/&"([^"]+)": \[_[a-z_]+, &"[^"]+"\]/g)]
    .map(match => match[1])
    .filter(name => !name.startsWith('visualizer._internal_'));

  return new Set(toolNames);
}

function getRuntimeToolNames(): Set<string> {
  const testDir = path.dirname(fileURLToPath(import.meta.url));
  const runtimePath = path.resolve(testDir, '../../../addons/godot_mcp/runtime/mcp_runtime.gd');
  const source = readFileSync(runtimePath, 'utf8');
  const toolNames = [...source.matchAll(/"([a-z_]+)":\s*\n\s*return _[a-z_]+\(/g)]
    .map(match => match[1]);
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
    expect(toolExists('snap_node_to_ground')).toBe(true);
    expect(toolExists('place_node_relative')).toBe(true);
  });

  it('includes editor viewport tooling in the advertised MCP registry', () => {
    expect(toolExists('take_editor_viewport_screenshot')).toBe(true);
  });

  it('includes live editor scene-tree method tooling in the advertised MCP registry', () => {
    expect(toolExists('call_node_method')).toBe(true);
  });

  it('includes scene layout analysis tooling in the advertised MCP registry', () => {
    expect(toolExists('summarize_scene_layout')).toBe(true);
  });

  it('includes metadata-driven scene property workflow tools in the advertised MCP registry', () => {
    expect(toolExists('get_scene_node_properties')).toBe(true);
    expect(toolExists('set_scene_node_property')).toBe(true);
    expect(toolExists('set_resource_property')).toBe(true);
  });

  it('includes dedicated lighting workflow tools in the advertised MCP registry', () => {
    expect(toolExists('get_light_info')).toBe(true);
    expect(toolExists('set_sun_light')).toBe(true);
    expect(toolExists('validate_scene_lighting')).toBe(true);
  });

  it('includes navigation mesh workflow tools in the advertised MCP registry', () => {
    expect(toolExists('set_navigation_mesh')).toBe(true);
    expect(toolExists('get_navigation_mesh_info')).toBe(true);
    expect(toolExists('bake_navigation_mesh')).toBe(true);
  });

  it('includes persisted scene signal workflow tools in the advertised MCP registry', () => {
    expect(toolExists('map_scene_signals')).toBe(true);
    expect(toolExists('update_scene_signal_connections')).toBe(true);
  });

  it('every advertised MCP tool is registered in the Godot executor map OR the runtime helper', () => {
    const executorTools = getExecutorToolNames();
    const runtimeTools = getRuntimeToolNames();
    const missing = allTools
      .map(tool => tool.name)
      .filter(name => !executorTools.has(name) && !runtimeTools.has(name));

    expect(missing).toEqual([]);
  });

  it('runtime-only tools are declared in the runtime helper, not the editor map', () => {
    const executorTools = getExecutorToolNames();
    const runtimeTools = getRuntimeToolNames();
    for (const name of RUNTIME_ONLY_TOOLS) {
      expect(runtimeTools.has(name), `${name} missing from mcp_runtime.gd`).toBe(true);
      expect(executorTools.has(name), `${name} should NOT be in tool_executor.gd`).toBe(false);
    }
  });
});
