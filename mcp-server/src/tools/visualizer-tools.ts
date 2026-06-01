/**
 * Visualizer tools - project mapping and visualization
 */

import type { ToolDefinition } from '../types.js';

export const visualizerTools: ToolDefinition[] = [
  {
    name: 'map_project',
    description: 'Crawl the entire Godot project and build an interactive script-level map of GDScript files showing their structure (variables, functions, declared signals) and inferred code relationships (extends, preloads, regex-parsed connect() usage). This is a source-code graph, not saved scene-connection truth. Opens an interactive browser-based visualization.',
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
