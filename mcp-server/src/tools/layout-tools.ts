import type { ToolDefinition } from '../types.js';

export const layoutTools: ToolDefinition[] = [
  {
    name: 'summarize_scene_layout',
    description: 'Analyze a 3D scene using CollisionShape3D geometry and return a top-down layout summary with floors, walls, obstacles, scene bounds, and detected wall openings.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        runtime: {
          type: 'boolean',
          description: 'Inspect the currently open editor scene tree instead of loading the .tscn file from disk. This sees live editor-state overrides, but not the separate running game process.'
        },
        floor_height_threshold: {
          type: 'number',
          description: 'Maximum AABB height that should still count as floor geometry (default: 0.75)'
        },
        wall_height_threshold: {
          type: 'number',
          description: 'Minimum AABB height required for a shape to be considered wall-like (default: 1.5)'
        },
        thin_threshold: {
          type: 'number',
          description: 'Maximum wall thickness used to classify thin wall segments and broad floor surfaces (default: 1.0)'
        },
        line_merge_tolerance: {
          type: 'number',
          description: 'Tolerance used when grouping nearby wall segments onto the same line for opening detection (default: 0.25)'
        },
        min_opening_width: {
          type: 'number',
          description: 'Minimum wall gap width that should be reported as an opening (default: 0.75)'
        }
      },
      required: ['scene_path']
    }
  }
];
