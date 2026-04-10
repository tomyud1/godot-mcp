/**
 * Scene/script runner tool for Godot MCP Server
 * Spawns a headless Godot subprocess and captures its output.
 * Runs independently of the GodotBridge WebSocket — handled inline in index.ts.
 */

import type { ToolDefinition } from '../types.js';

export const runnerTools: ToolDefinition[] = [
  {
    name: 'run_scene',
    description: [
      'Run a Godot scene or GDScript in a headless subprocess and return its full output.',
      'Ideal for executing GUT test suites and reading pass/fail results without leaving the MCP session.',
      'The Godot editor does not need to be open — but the project path must be known (connect the editor first, or pass project_path explicitly).',
      '',
      'Examples:',
      '  Run GUT tests: scene_path="res://addons/gut/gut_cmdln.gd", args=["-gdir=res://tests/", "-gprefix=test_", "-gexit", "-glog=1"]',
      '  Run a scene:   scene_path="res://scenes/Main.tscn"',
    ].join('\n'),
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'res:// path to the scene (.tscn) or script (.gd) to run'
        },
        args: {
          type: 'array',
          items: { type: 'string', description: 'A single CLI argument string' },
          description: 'Additional CLI arguments forwarded to the scene/script (e.g. ["-gdir=res://tests/", "-gexit"])'
        },
        timeout_ms: {
          type: 'number',
          description: 'Kill the process after this many milliseconds (default: 60000)'
        },
        headless: {
          type: 'boolean',
          description: 'Run without a display using --headless (default: true)'
        },
        project_path: {
          type: 'string',
          description: 'Absolute filesystem path to the Godot project root (contains project.godot). Auto-detected when Godot editor is connected.'
        }
      },
      required: ['scene_path']
    }
  }
];
