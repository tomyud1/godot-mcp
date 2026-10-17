import { describe, it, expect } from 'vitest';
import { prepareToolCall, didYouMean, formatUsage } from '../validation.js';
import { advertisedTools, findTool } from '../tools/index.js';

function prep(name: string, args: Record<string, unknown>) {
  const tool = findTool(name);
  if (!tool) throw new Error(`no tool ${name}`);
  return prepareToolCall(tool, args, findTool);
}

function errorsOf(name: string, args: Record<string, unknown>): string[] {
  const r = prep(name, args);
  if (r.ok) throw new Error(`expected ${name} to be rejected`);
  return r.errors;
}

function wireOf(name: string, args: Record<string, unknown>): Record<string, unknown> {
  const r = prep(name, args);
  if (!r.ok) throw new Error(`expected ${name} to pass: ${r.errors.join('; ')}`);
  return r.args;
}

describe('unknown and missing arguments', () => {
  it('rejects an unknown argument with a suggestion', () => {
    const errors = errorsOf('run_scene', { scene_pth: 'res://a.tscn' });
    expect(errors).toEqual(["unknown argument 'scene_pth' (did you mean 'scene_path'?)"]);
  });

  it('rejects bogus top-level keys (feedback: create_scene root_node_type_note)', () => {
    const errors = errorsOf('create_scene', { scene_path: 'res://a.tscn', root_node_type: 'Node2D', root_node_type_note: 'x' });
    expect(errors[0]).toMatch(/^unknown argument 'root_node_type_note'/);
  });

  it('reports every missing required argument', () => {
    expect(errorsOf('connect_signal', { scene_path: 'res://a.tscn' })).toEqual([
      "missing required argument 'from_node_path'",
      "missing required argument 'signal'",
      "missing required argument 'to_node_path'",
      "missing required argument 'method'",
    ]);
  });

  it('reports wrong types and enum values', () => {
    expect(errorsOf('read_scene', { scene_path: 5 as unknown as string, include_properties: 'yes' })).toEqual([
      "'scene_path' must be a string (got number 5)",
      "'include_properties' must be a boolean (got a string \"yes\")",
    ]);
    expect(errorsOf('set_node_groups', { scene_path: 'res://a.tscn', groups: ['g'], mode: 'merge' })).toEqual([
      "'mode' must be one of: \"replace\", \"add\", \"remove\"",
    ]);
  });

  it('describes oneOf fields once', () => {
    const errors = errorsOf('snap_node_to_grid', { scene_path: 'res://a.tscn', grid_size: 'big' });
    expect(errors).toEqual(["'grid_size' must be number or object"]);
  });

  it('includes a usage line', () => {
    const r = prep('run_scene', { nope: 1 });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.usage).toMatch(/^run_scene\(\{ scene_path\?: string/);
  });
});

describe('lenient input that clients commonly send', () => {
  it('parses JSON-stringified objects and arrays', () => {
    const wire = wireOf('set_node_properties', { scene_path: 'res://a.tscn', properties: '{"visible": false}' });
    expect(wire.properties).toEqual({ visible: false });
  });

  it('converts numeric and boolean strings', () => {
    const wire = wireOf('scene_tree_dump', { max_depth: '2' });
    expect(wire.max_depth).toBe(2);
    expect(wireOf('read_scene', { scene_path: 'res://a.tscn', include_properties: 'true' }).include_properties).toBe(true);
  });

  it('treats null optional arguments as omitted', () => {
    expect(wireOf('run_scene', { scene_path: null })).toEqual({});
  });

  it('keeps null where it means "clear" (untyped values)', () => {
    const wire = wireOf('modify_node_property', { scene_path: 'res://a.tscn', node_path: 'S', property_name: 'texture', value: null });
    expect(wire).toHaveProperty('value', null);
  });
});

describe('renamed arguments and wire format', () => {
  it('sends the old name to the plugin', () => {
    expect(wireOf('run_scene', { scene_path: 'res://a.tscn' })).toEqual({ scene: 'res://a.tscn' });
    expect(wireOf('list_dir', { path: 'res://x' })).toEqual({ root: 'res://x' });
  });

  it('still accepts the old name', () => {
    expect(wireOf('run_scene', { scene: 'current' })).toEqual({ scene: 'current' });
    expect(wireOf('connect_signal', { scene_path: 's', from_node: 'A', signal: 'x', to_node: '.', method: 'm' }))
      .toEqual({ scene_path: 's', from_node: 'A', signal: 'x', to_node: '.', method: 'm' });
  });

  it('rejects old and new name together', () => {
    expect(errorsOf('run_scene', { scene: 'a', scene_path: 'b' })[0]).toMatch(/renamed to 'scene_path'/);
  });

  it('normalizes aliases to the canonical name', () => {
    expect(wireOf('set_editor_selection', { node_path: 'Player' })).toEqual({ node_paths: 'Player' });
  });
});

describe('edit_script', () => {
  const nested = { edit: { type: 'snippet_replace', file: 'res://a.gd', old_snippet: 'a', new_snippet: 'b' } };

  it('converts flat arguments to the nested wire shape', () => {
    expect(wireOf('edit_script', { path: 'res://a.gd', old_text: 'a', new_text: 'b' })).toEqual(nested);
  });

  it('accepts the older nested shape', () => {
    expect(wireOf('edit_script', nested)).toEqual(nested);
  });

  it('explains mixed or unknown shapes (feedback: flat path/old_text/new_text)', () => {
    expect(errorsOf('edit_script', { ...nested, path: 'x' })[0]).toMatch(/either the flat arguments/);
    expect(errorsOf('edit_script', { edit: { file: 'a', old: 'x' } })[0]).toMatch(/unknown key 'edit.old'/);
    expect(errorsOf('edit_script', { path: 'res://a.gd', old_text: '', new_text: 'b' })[0]).toMatch(/old_text/);
  });
});

describe('batch_execute', () => {
  it('validates and converts every sub-command', () => {
    const wire = wireOf('batch_execute', {
      commands: [
        { name: 'run_scene', args: { scene_path: 'res://a.tscn' } },
        { tool: 'edit_script', args: { path: 'res://a.gd', old_text: 'a', new_text: 'b' } },
      ],
    });
    expect(wire.commands).toEqual([
      { name: 'run_scene', args: { scene: 'res://a.tscn' } },
      { name: 'edit_script', args: { edit: { type: 'snippet_replace', file: 'res://a.gd', old_snippet: 'a', new_snippet: 'b' } } },
    ]);
  });

  it('points at the failing sub-command', () => {
    const errors = errorsOf('batch_execute', {
      commands: [
        { name: 'add_node', args: { scene_path: 's', node_name: 'A', node_type: 'Node', parent: '.' } },
        { name: 'no_such_tool', args: {} },
        { name: 'get_guide', args: {} },
        { name: 'read_scene', arguments: {} },
      ],
    });
    expect(errors[0]).toMatch(/^commands\[0\] \(add_node\): unknown argument 'parent'/);
    expect(errors).toContain("commands[1]: unknown tool 'no_such_tool'");
    expect(errors).toContain("commands[2]: 'get_guide' can't run inside batch_execute; call it directly");
    expect(errors.some((e) => e.startsWith("commands[3]: unknown key 'arguments'"))).toBe(true);
  });

  it('notes deprecated sub-commands', () => {
    const r = prep('batch_execute', { commands: [{ name: 'modify_node_property', args: { scene_path: 's', property_name: 'visible', value: false } }] });
    expect(r.ok && r.notes[0]).toMatch(/commands\[0\]: modify_node_property is deprecated/);
  });
});

describe('deprecated tools', () => {
  const deprecated = ['modify_node_property', 'set_resource_property', 'set_collision_shape', 'set_sprite_texture', 'set_mesh', 'set_material'];

  it('are hidden from the tool list but still callable', () => {
    const listed = new Set(advertisedTools.map((t) => t.name));
    for (const name of deprecated) {
      expect(listed.has(name), name).toBe(false);
      expect(findTool(name), name).toBeDefined();
    }
  });

  it('carry a pointer to the replacement', () => {
    const r = prep('set_collision_shape', { scene_path: 's', shape_type: 'CircleShape2D' });
    expect(r.ok && r.deprecation).toMatch(/set_node_properties/);
  });
});

describe('helpers', () => {
  it('didYouMean matches shared words and small typos', () => {
    expect(didYouMean('scene', ['scene_path', 'node_path'])).toBe(" (did you mean 'scene_path'?)");
    expect(didYouMean('pathh', ['path', 'include_hidden'])).toBe(" (did you mean 'path'?)");
    expect(didYouMean('zzz', ['path'])).toBe('');
  });

  it('formatUsage lists required arguments first', () => {
    expect(formatUsage(findTool('rename_node')!)).toBe('rename_node({ scene_path: string, node_path: string, new_name: string })');
  });
});
