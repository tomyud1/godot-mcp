import { describe, it, expect } from 'vitest';
import { allTools, advertisedTools } from '../tools/index.js';
import { deriveAnnotations, requiresUserInteraction } from '../tools/annotations.js';
import { GUIDES } from '../resources.js';

describe('deriveAnnotations', () => {
  it('marks read-only tools by name prefix', () => {
    expect(deriveAnnotations({ name: 'read_file' }).readOnlyHint).toBe(true);
    expect(deriveAnnotations({ name: 'get_scene_hierarchy' }).readOnlyHint).toBe(true);
    expect(deriveAnnotations({ name: 'search_project' }).readOnlyHint).toBe(true);
    expect(deriveAnnotations({ name: 'query_runtime_node' }).readOnlyHint).toBe(true);
  });

  it('marks mutating tools as not read-only', () => {
    expect(deriveAnnotations({ name: 'edit_script' }).readOnlyHint).toBe(false);
    expect(deriveAnnotations({ name: 'add_node' }).readOnlyHint).toBe(false);
    expect(deriveAnnotations({ name: 'set_node_properties' }).readOnlyHint).toBe(false);
    expect(deriveAnnotations({ name: 'create_scene' }).readOnlyHint).toBe(false);
  });

  it('does not treat read-prefixed tools that actually write as safe', () => {
    // These would otherwise be auto-approved by a client because of the name.
    expect(deriveAnnotations({ name: 'validate_script' }).readOnlyHint).toBe(false);
    expect(deriveAnnotations({ name: 'rescan_filesystem' }).readOnlyHint).toBe(false);
    expect(deriveAnnotations({ name: 'bake_navigation_mesh' }).readOnlyHint).toBe(false);
  });

  it('flags irreversible tools as destructive', () => {
    expect(deriveAnnotations({ name: 'delete_file' }).destructiveHint).toBe(true);
    expect(deriveAnnotations({ name: 'remove_node' }).destructiveHint).toBe(true);
    expect(deriveAnnotations({ name: 'runtime_eval' }).destructiveHint).toBe(true);
  });

  it('does not flag ordinary writes as destructive', () => {
    expect(deriveAnnotations({ name: 'edit_script' }).destructiveHint).toBe(false);
    expect(deriveAnnotations({ name: 'add_node' }).destructiveHint).toBe(false);
  });

  it('treats reads and idempotent writes as idempotent', () => {
    expect(deriveAnnotations({ name: 'read_file' }).idempotentHint).toBe(true);
    expect(deriveAnnotations({ name: 'modify_node_property' }).idempotentHint).toBe(true);
  });

  it('treats accumulating writes as non-idempotent', () => {
    // add_node twice creates two nodes.
    expect(deriveAnnotations({ name: 'add_node' }).idempotentHint).toBe(false);
    expect(deriveAnnotations({ name: 'send_input' }).idempotentHint).toBe(false);
  });

  it('flags tools that act outside the project as open-world', () => {
    expect(deriveAnnotations({ name: 'run_scene' }).openWorldHint).toBe(true);
    expect(deriveAnnotations({ name: 'read_file' }).openWorldHint).toBe(false);
  });

  it('lets a tool override the derived value', () => {
    const a = deriveAnnotations({ name: 'read_file', annotationOverrides: { readOnlyHint: false } });
    expect(a.readOnlyHint).toBe(false);
  });
});

describe('requiresUserInteraction', () => {
  it('is true for irreversible tools', () => {
    expect(requiresUserInteraction('delete_file')).toBe(true);
    expect(requiresUserInteraction('runtime_eval')).toBe(true);
  });

  it('is false for ordinary tools, so confirmations stay meaningful', () => {
    expect(requiresUserInteraction('edit_script')).toBe(false);
    expect(requiresUserInteraction('read_file')).toBe(false);
  });
});

describe('every registered tool gets annotations', () => {  it('derives a complete annotation set for all tools', () => {
    for (const tool of allTools) {
      const a = deriveAnnotations(tool);
      expect(typeof a.readOnlyHint, `${tool.name}.readOnlyHint`).toBe('boolean');
      expect(typeof a.destructiveHint, `${tool.name}.destructiveHint`).toBe('boolean');
      expect(typeof a.idempotentHint, `${tool.name}.idempotentHint`).toBe('boolean');
      expect(typeof a.openWorldHint, `${tool.name}.openWorldHint`).toBe('boolean');
    }
  });

  it('has no duplicate tool names', () => {
    const names = allTools.map((t) => t.name);
    expect(new Set(names).size).toBe(names.length);
  });

  it('requires confirm=true on runtime_eval, the arbitrary-code tool', () => {
    const evalTool = allTools.find((t) => t.name === 'runtime_eval');
    expect(evalTool).toBeDefined();
    expect(evalTool!.inputSchema.required).toContain('confirm');
    expect(evalTool!.inputSchema.properties.confirm).toBeDefined();
  });

  it('requires confirm=true on delete_file', () => {
    const del = allTools.find((t) => t.name === 'delete_file');
    expect(del!.inputSchema.required).toContain('confirm');
  });
});

describe('advertised vs dispatchable tools', () => {
  it('keeps hidden tools callable, so existing agents do not break', () => {
    // Usage logs showed the agent splitting calls across two names that are
    // the same function. The alias stays dispatchable, just unlisted.
    const alias = allTools.find((t) => t.name === 'modify_node_property');
    expect(alias, 'alias must still exist in the dispatchable registry').toBeDefined();
    expect(alias!.hidden).toBe(true);
  });

  it('omits hidden tools from the advertised list', () => {
    const names = advertisedTools.map((t) => t.name);
    expect(names).not.toContain('modify_node_property');
    expect(names).toContain('set_scene_node_property');
    expect(names).toContain('set_node_properties');
  });

  it('advertises strictly fewer tools than it dispatches', () => {
    expect(advertisedTools.length).toBeLessThan(allTools.length);
  });

  it('keeps every hidden tool pointed at a real canonical name', () => {
    const advertised = new Set(advertisedTools.map((t) => t.name));
    for (const tool of allTools.filter((t) => t.hidden)) {
      expect(tool.description, `${tool.name} should say what to use instead`).toMatch(/DEPRECATED ALIAS of (\w+)/);
      const canonical = /DEPRECATED ALIAS of (\w+)/.exec(tool.description)![1];
      expect(advertised.has(canonical), `${tool.name} points at ${canonical}, which must be advertised`).toBe(true);
    }
  });

  it('advertises no duplicate tool names', () => {
    const names = advertisedTools.map((t) => t.name);
    expect(new Set(names).size).toBe(names.length);
  });
});

describe('guides only reference real tools', () => {
  it('names no tool in the guides that the agent cannot call', () => {
    // The tool-index guide used to advertise duplicate_node, reorder_node,
    // get_scene_hierarchy and map_scenes. Those exist only as visualizer-
    // internal commands, so following the guide produced "Unknown tool".
    const callable = new Set(allTools.map((t) => t.name));
    // Names that are parameters, response fields, or `assert_runtime` assertion
    // kinds rather than tools.
    const ASSERTION_KINDS = [
      'node_exists', 'node_visible', 'node_inside_viewport', 'rect_contains_point',
      'text_matches', 'property_equals', 'group_count', 'no_errors',
    ];
    const NON_TOOL_NAMES = new Set([
      ...ASSERTION_KINDS,
      'action', 'children', 'groups', 'height', 'node_type', 'nodes', 'note',
      'runtime_connected', 'scale', 'script', 'synchronized', 'width',
      'save_path', 'property', 'value', 'path', 'code', 'slug', 'group',
      'query', 'text', 'contains', 'equals', 'max', 'visible', 'point', 'x', 'y',
      'node_paths', 'checks', 'return', 'save_to', 'viewport_index', 'force_draw',
    ]);

    const phantom: string[] = [];
    let scanned = 0;
    for (const guide of GUIDES) {
      // The guide text holds plain backticks at runtime (they are escaped only
      // in the TypeScript template literal), so match a literal backtick.
      for (const m of guide.text.matchAll(/`([a-z_0-9]+)`/g)) {
        scanned++;
        const name = m[1];
        if (callable.has(name) || NON_TOOL_NAMES.has(name)) continue;
        phantom.push(`${guide.slug}: ${name}`);
      }
    }
    // Guard against the check silently matching nothing, which would make it
    // vacuous and permanently green.
    expect(scanned, 'expected the guides to mention backticked names').toBeGreaterThan(50);
    expect(phantom, `guides reference non-existent tools: ${phantom.join(', ')}`).toEqual([]);
  });
});
