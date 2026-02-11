/**
 * Asset generation tools for Godot MCP Server
 * Tools for generating 2D assets via SVG.
 *
 * NOTE: RunningHub workflow tools (inspect_runninghub_workflow,
 * customize_and_run_workflow) exist in the Godot plugin but are not
 * exposed as MCP tools yet.  They require a RunningHub account / API key
 * and will be re-enabled in a future release.  The GDScript implementations
 * in asset_tools.gd are kept intact.
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
  }
];

export function getMockAssetToolResponse(toolName: string, args: Record<string, unknown>): unknown {
  const mockNote = { _mock: true, _note: 'Connect Godot for real results.' };

  switch (toolName) {
    case 'generate_2d_asset':
      return { ok: true, resource_path: `res://assets/generated/${args.filename}`, dimensions: { width: 64, height: 64 }, ...mockNote };
    default:
      return { error: `Unknown asset tool: ${toolName}`, ...mockNote };
  }
}
