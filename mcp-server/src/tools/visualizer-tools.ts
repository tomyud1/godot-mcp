/**
 * Visualizer tools - project mapping and visualization
 */

import type { ToolDefinition } from '../types.js';

export const visualizerTools: ToolDefinition[] = [
  {
    name: 'map_project',
    description: 'Crawl the entire Godot project and build an interactive visual map of all scripts showing their structure (variables, functions, signals), connections (extends, preloads, signal connections), and descriptions. Opens an interactive browser-based visualization.',
    inputSchema: {
      type: 'object',
      properties: {
        root: {
          type: 'string',
          description: 'Root path to start crawling from (default: res://)'
        },
        include_addons: {
          type: 'boolean',
          description: 'Whether to include scripts in the addons/ folder (default: false)'
        }
      },
      required: []
    }
  }
];

export function getMockVisualizerToolResponse(toolName: string, _args: Record<string, unknown>): unknown {
  if (toolName === 'map_project') {
    return {
      project_map: {
        nodes: [
          {
            path: 'res://scripts/player.gd',
            filename: 'player.gd',
            folder: 'res://scripts',
            class_name: 'Player',
            extends: 'CharacterBody2D',
            description: 'Handles player movement and input',
            line_count: 85,
            variables: [
              { name: 'speed', exported: true },
              { name: 'jump_force', exported: true },
              { name: '_velocity', exported: false }
            ],
            functions: [
              { name: '_ready', params: '' },
              { name: '_physics_process', params: 'delta: float' },
              { name: 'take_damage', params: 'amount: float' }
            ],
            signals: ['health_changed', 'died'],
            preloads: ['res://scenes/bullet.tscn'],
            connections: []
          },
          {
            path: 'res://scripts/enemy.gd',
            filename: 'enemy.gd',
            folder: 'res://scripts',
            class_name: 'Enemy',
            extends: 'CharacterBody2D',
            description: 'Base enemy AI with patrol and chase behavior',
            line_count: 120,
            variables: [
              { name: 'patrol_speed', exported: true },
              { name: 'chase_speed', exported: true }
            ],
            functions: [
              { name: '_ready', params: '' },
              { name: '_physics_process', params: 'delta: float' },
              { name: '_on_detection_area_entered', params: 'body: Node2D' }
            ],
            signals: ['enemy_defeated'],
            preloads: [],
            connections: [{ signal: 'body_entered', line: 15 }]
          }
        ],
        edges: [
          { from: 'res://scripts/player.gd', to: 'res://scenes/bullet.tscn', type: 'preload' }
        ],
        total_scripts: 2,
        total_connections: 1
      },
      message: 'Mock project map generated. Connect Godot for real data.'
    };
  }
  return { error: `Unknown visualizer tool: ${toolName}` };
}
