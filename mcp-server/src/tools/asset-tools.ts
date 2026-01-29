/**
 * Asset generation tools for Godot MCP Server
 * Tools for generating 2D assets via SVG and ComfyUI/RunningHub workflows
 */

import type { ToolDefinition } from '../types.js';

export const assetTools: ToolDefinition[] = [
  {
    name: 'generate_2d_asset',
    description: 'Generate a 2D sprite/texture from SVG code and save as PNG. Use for custom visuals (characters, objects, backgrounds, UI). Returns resource_path and dimensions.',
    inputSchema: {
      type: 'object',
      properties: {
        svg_code: {
          type: 'string',
          description: 'Complete SVG code string with <svg> tags including width/height.'
        },
        filename: {
          type: 'string',
          description: 'Filename for the asset (saved as .png). Example: "player_sprite.png"'
        },
        save_path: {
          type: 'string',
          description: 'Godot resource path to save (default: res://assets/generated/)'
        }
      },
      required: ['svg_code', 'filename']
    }
  },
  {
    name: 'search_comfyui_nodes',
    description: 'Search the ComfyUI node library (10,514+ nodes) to discover nodes for building custom workflows.',
    inputSchema: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Search keyword - searches node names and descriptions'
        },
        category: {
          type: 'string',
          description: 'Filter by category: loaders, samplers, conditioning, latent, image, output, mask, video, utilities'
        },
        limit: {
          type: 'number',
          description: 'Maximum results to return (default: 20, max: 100)'
        }
      }
    }
  },
  {
    name: 'inspect_runninghub_workflow',
    description: 'Inspect a RunningHub workflow to discover customizable parameters before execution. ALWAYS use before customize_and_run_workflow.',
    inputSchema: {
      type: 'object',
      properties: {
        workflow_id: {
          type: 'string',
          description: 'RunningHub workflow ID from the URL'
        }
      },
      required: ['workflow_id']
    }
  },
  {
    name: 'customize_and_run_workflow',
    description: 'Run a RunningHub workflow to generate assets. Inspect first, then customize node_inputs to control generation.',
    inputSchema: {
      type: 'object',
      properties: {
        workflow_id: {
          type: 'object',
          description: 'String workflow ID or complete custom workflow JSON object'
        },
        node_inputs: {
          type: 'array',
          description: 'Array of customizations: [{nodeId, fieldName, fieldValue}]. MANDATORY - controls what gets generated.'
        },
        save_path: {
          type: 'string',
          description: 'Where to save the generated PNG (default: res://assets/runninghub/)'
        },
        filename: {
          type: 'string',
          description: 'Optional PNG filename'
        }
      },
      required: ['workflow_id', 'node_inputs']
    }
  }
];

export function getMockAssetToolResponse(toolName: string, args: Record<string, unknown>): unknown {
  const mockNote = { _mock: true, _note: 'Connect Godot for real results.' };

  switch (toolName) {
    case 'generate_2d_asset':
      return { ok: true, resource_path: `res://assets/generated/${args.filename}`, dimensions: { width: 64, height: 64 }, ...mockNote };
    case 'search_comfyui_nodes':
      return { ok: true, results: [], count: 0, message: 'Mock: ComfyUI search requires Godot connection', ...mockNote };
    case 'inspect_runninghub_workflow':
      return { ok: true, workflow_id: args.workflow_id, nodes: [], message: 'Mock: Workflow inspection requires Godot connection', ...mockNote };
    case 'customize_and_run_workflow':
      return { ok: true, message: 'Mock: Workflow execution requires Godot connection', ...mockNote };
    default:
      return { error: `Unknown asset tool: ${toolName}`, ...mockNote };
  }
}
