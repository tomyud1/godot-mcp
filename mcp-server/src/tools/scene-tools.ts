/**
 * Scene operation tools for Godot MCP Server
 * Tools for creating, reading, and modifying Godot scenes (.tscn files)
 */

import type { ToolDefinition } from '../types.js';

export const sceneTools: ToolDefinition[] = [
  {
    name: 'create_scene',
    description: 'Create a new Godot scene (.tscn) file with nodes. Use this to create player scenes, UI screens, game objects, etc.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Scene file path (e.g., res://Scenes/player.tscn)'
        },
        root_node_name: {
          type: 'string',
          description: 'Name of root node (default: derived from filename)'
        },
        root_node_type: {
          type: 'string',
          description: 'Type of root node (e.g., Node2D, CharacterBody2D, Control, Node3D). REQUIRED.'
        },
        nodes: {
          type: 'array',
          description: 'Array of child nodes to add. Each node: {name, type, properties, script, children}.'
        },
        attach_script: {
          type: 'string',
          description: 'Optional script path to attach to root node (res://path/to/script.gd)'
        }
      },
      required: ['scene_path', 'root_node_type']
    }
  },
  {
    name: 'read_scene',
    description: 'Read and parse a scene file to get its full node structure and properties. Use this to understand a scene before editing.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the scene file (res://path/to/scene.tscn)'
        },
        include_properties: {
          type: 'boolean',
          description: 'Include node properties in the output (default: false)'
        }
      },
      required: ['scene_path']
    }
  },
  {
    name: 'add_node',
    description: 'Add a single node to an existing scene file.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the scene file (res://path/to/scene.tscn)'
        },
        node_name: {
          type: 'string',
          description: 'Name for the new node'
        },
        node_type: {
          type: 'string',
          description: 'Type of node (e.g., Sprite2D, Camera2D, RigidBody2D, CollisionShape2D)'
        },
        parent_path: {
          type: 'string',
          description: 'Path to parent node (. for root, or relative path like Sprite2D)'
        },
        properties: {
          type: 'object',
          description: 'Optional dictionary of properties to set on the node'
        }
      },
      required: ['scene_path', 'node_name', 'node_type']
    }
  },
  {
    name: 'remove_node',
    description: 'Remove a node from an existing scene file.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the node to remove (cannot be root, use relative path)'
        }
      },
      required: ['scene_path', 'node_path']
    }
  },
  {
    name: 'modify_node_property',
    description: 'Modify a property on a node in a .tscn scene file. ALWAYS use this tool to modify properties in scene files - NEVER edit .tscn files directly. Use this to change positions, colors, sizes, visibility, etc.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the node (. for root, or relative path like "Sprite2D")'
        },
        property_name: {
          type: 'string',
          description: 'Name of the property to modify (position, scale, rotation, modulate, visible, etc.)'
        },
        value: {
          type: 'object',
          description: 'New value. For Vector2/Vector3/Color, use {type: "Vector2", x: 100, y: 200}. For primitives, use directly.'
        }
      },
      required: ['scene_path', 'property_name', 'value']
    }
  },
  {
    name: 'rename_node',
    description: 'Rename a node in a scene.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the node to rename'
        },
        new_name: {
          type: 'string',
          description: 'New name for the node'
        }
      },
      required: ['scene_path', 'node_path', 'new_name']
    }
  },
  {
    name: 'move_node',
    description: 'Move a node to a different parent in a scene and optionally control its position among siblings.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the node to move'
        },
        new_parent_path: {
          type: 'string',
          description: 'Path to the new parent node (. for root)'
        },
        sibling_index: {
          type: 'number',
          description: 'Optional position among siblings (0 = first child). Omit or -1 to append.'
        }
      },
      required: ['scene_path', 'node_path', 'new_parent_path']
    }
  },
  {
    name: 'attach_script',
    description: 'Attach or change a script on a node in a scene.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the node (. for root, or relative path)'
        },
        script_path: {
          type: 'string',
          description: 'Path to the script file (res://path/to/script.gd)'
        }
      },
      required: ['scene_path', 'script_path']
    }
  },
  {
    name: 'detach_script',
    description: 'Remove a script from a node in a scene.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the node (. for root)'
        }
      },
      required: ['scene_path', 'node_path']
    }
  },
  {
    name: 'set_collision_shape',
    description: 'Create and assign a collision shape resource to a CollisionShape2D or CollisionShape3D node. Supports: CircleShape2D, RectangleShape2D, CapsuleShape2D, SphereShape3D, BoxShape3D, etc.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the CollisionShape2D/3D node'
        },
        shape_type: {
          type: 'string',
          description: 'Shape type: CircleShape2D, RectangleShape2D, CapsuleShape2D, SphereShape3D, BoxShape3D, etc.'
        },
        shape_params: {
          type: 'object',
          description: 'Shape parameters: {radius: 32} for circles, {size: {x: 64, y: 64}} for rectangles, etc.'
        }
      },
      required: ['scene_path', 'shape_type']
    }
  },
  {
    name: 'set_sprite_texture',
    description: 'Assign a texture to a Sprite2D/Sprite3D/TextureRect node. Use after generate_2d_asset or to load existing images.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the Sprite2D/Sprite3D/TextureRect node'
        },
        texture_type: {
          type: 'string',
          description: 'Texture type: "ImageTexture", "PlaceholderTexture2D", "GradientTexture2D", "NoiseTexture2D"'
        },
        texture_params: {
          type: 'object',
          description: 'Texture parameters. ImageTexture: {path: "res://assets/sprite.png"}. PlaceholderTexture2D: {size: {x: 64, y: 64}}.'
        }
      },
      required: ['scene_path', 'texture_type']
    }
  }
];

export function getMockSceneToolResponse(toolName: string, args: Record<string, unknown>): unknown {
  const mockNote = { _mock: true, _note: 'Connect Godot for real results.' };

  switch (toolName) {
    case 'create_scene':
      return { ok: true, scene_path: args.scene_path, message: 'Mock: Scene would be created', ...mockNote };
    case 'read_scene':
      return { ok: true, scene_path: args.scene_path, root: { name: 'Root', type: 'Node2D', children: [{ name: 'Sprite2D', type: 'Sprite2D' }] }, ...mockNote };
    case 'add_node':
      return { ok: true, message: `Mock: Would add ${args.node_type} named ${args.node_name}`, ...mockNote };
    case 'remove_node':
      return { ok: true, message: `Mock: Would remove node at ${args.node_path}`, ...mockNote };
    case 'modify_node_property':
      return { ok: true, message: `Mock: Would set ${args.property_name} on ${args.node_path}`, ...mockNote };
    case 'rename_node':
      return { ok: true, message: `Mock: Would rename ${args.node_path} to ${args.new_name}`, ...mockNote };
    case 'move_node':
      return { ok: true, message: `Mock: Would move ${args.node_path} to ${args.new_parent_path}`, ...mockNote };
    case 'attach_script':
      return { ok: true, message: `Mock: Would attach ${args.script_path}`, ...mockNote };
    case 'detach_script':
      return { ok: true, message: `Mock: Would detach script from ${args.node_path}`, ...mockNote };
    case 'set_collision_shape':
      return { ok: true, message: `Mock: Would set ${args.shape_type} shape`, ...mockNote };
    case 'set_sprite_texture':
      return { ok: true, message: `Mock: Would set ${args.texture_type} texture`, ...mockNote };
    default:
      return { error: `Unknown scene tool: ${toolName}`, ...mockNote };
  }
}
