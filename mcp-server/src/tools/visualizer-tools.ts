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
