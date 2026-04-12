import type { ToolDefinition } from '../types.js';

export const editorViewTools: ToolDefinition[] = [
  {
    name: 'take_editor_viewport_screenshot',
    description: 'Capture the current Godot editor 3D viewport to a PNG file. Use this for visual verification after scene edits or placement changes.',
    inputSchema: {
      type: 'object',
      properties: {
        viewport_index: {
          type: 'number',
          description: '3D editor viewport index from 0 to 3 (default: 0)'
        },
        output_path: {
          type: 'string',
          description: 'Optional absolute path, res:// path, or user:// path for the PNG file. Defaults to user://mcp_screenshots/editor_viewport_<timestamp>.png'
        },
        force_draw: {
          type: 'boolean',
          description: 'Force a render pass before capture. Leave enabled unless you know the viewport is already fresh (default: true)'
        }
      }
    }
  }
];
