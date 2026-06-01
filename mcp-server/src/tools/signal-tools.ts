import type { ToolDefinition } from '../types.js';

export const signalTools: ToolDefinition[] = [
  {
    name: 'map_scene_signals',
    description: 'Inspect the persisted signal connection graph of a saved Godot scene using scene-file metadata. This is the editor-facing source of truth for saved scene connections, not an inferred script graph. Returns source node paths, signal names, target node paths, methods, flags, binds, and optional validation against the instantiated editor scene.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        include_inherited: {
          type: 'boolean',
          description: 'Include connections declared in base scenes when inspecting an inherited scene (default: true)'
        },
        include_validation: {
          type: 'boolean',
          description: 'Instantiate the scene and validate that source nodes, target nodes, signals, and methods still exist (default: true)'
        }
      },
      required: ['scene_path']
    }
  },
  {
    name: 'update_scene_signal_connections',
    description: 'Batch add or remove persisted signal connections in a saved scene file. Use this to edit saved scene-connection truth in the editor workflow; added connections are always persisted with CONNECT_PERSIST and the scene is saved once after the batch.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        stop_on_error: {
          type: 'boolean',
          description: 'Stop processing remaining operations after the first error (default: false)'
        },
        operations: {
          type: 'array',
          description: 'List of add/remove operations to apply before a single scene save.',
          items: {
            type: 'object',
            properties: {
              action: {
                type: 'string',
                description: 'Operation type: add/connect or remove/disconnect'
              },
              source_node_path: {
                type: 'string',
                description: 'Relative path to the source node that owns the signal (. for root)'
              },
              signal_name: {
                type: 'string',
                description: 'Name of the signal on the source node'
              },
              target_node_path: {
                type: 'string',
                description: 'Relative path to the target node that owns the method (. for root)'
              },
              method_name: {
                type: 'string',
                description: 'Method name on the target node'
              },
              flags: {
                oneOf: [
                  { type: 'number' },
                  { type: 'object' },
                  { type: 'array' }
                ],
                description: 'Optional connection flags. You can pass an integer bitmask, an object like {deferred:true, one_shot:false, reference_counted:false}, or an array of names like ["deferred"]. CONNECT_PERSIST is always applied for added scene connections.'
              },
              binds: {
                type: 'array',
                description: 'Optional bound arguments for the callable'
              },
              unbinds: {
                type: 'number',
                description: 'Optional number of trailing signal arguments to ignore'
              },
              remove_all_matching: {
                type: 'boolean',
                description: 'For remove operations without explicit binds/unbinds, remove every matching target+method connection instead of only the first match (default: true)'
              }
            },
            required: ['action', 'signal_name', 'method_name']
          }
        }
      },
      required: ['scene_path', 'operations']
    }
  }
];
