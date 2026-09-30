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
          description: 'Optional res:// path, user:// path, or relative path (mapped to user://) for the PNG file. Defaults to user://mcp_screenshots/editor_viewport_<timestamp>.png. Absolute paths outside the project are rejected unless allow_absolute_output=true.'
        },
        allow_absolute_output: {
          type: 'boolean',
          description: 'Permit writing the PNG to an absolute path outside the project. Off by default because the tool also creates the containing directory. Only set this when the user explicitly asked for a path outside the project.'
        },
        force_draw: {
          type: 'boolean',
          description: 'Force a render pass before capture. Leave enabled unless you know the viewport is already fresh (default: true)'
        }
      }
    }
  }
];
