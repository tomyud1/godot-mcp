import type { ToolDefinition } from '../types.js';

export const editorSceneTools: ToolDefinition[] = [
  {
    name: 'call_node_method',
    description: 'Invoke a method on a node in the currently open Godot editor scene tree. Use this for @tool workflows that need a live SceneTree context, such as baking terrain, regenerating scatter, rebuilding helper nodes, or running other editor-side scene mutations that cannot work on an orphaned PackedScene instance.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the scene that must already be open in the Godot editor'
        },
        node_path: {
          type: 'string',
          description: 'Relative path to the target node inside the open editor scene. Use "." for the root node (default: ".")'
        },
        method_name: {
          type: 'string',
          description: 'Method name to invoke on the target node'
        },
        args: {
          type: 'array',
          description: 'Optional argument list passed to the method. Values use the same structured Variant shapes as other scene tools.'
        },
        save_scene_after: {
          type: 'boolean',
          description: 'Save the currently open editor scene after the method call. Disable this if you want the scene to stay dirty for manual review (default: true)'
        }
      },
      required: ['scene_path', 'method_name']
    }
  }
];
