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
          items: { type: 'object', description: 'A node: {name, type, properties, script, children}' },
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
    name: 'instance_scene',
    description: 'Add an instance of another scene (.tscn) as a child node. This is how you compose scenes from reusable parts (like prefabs). The instance maintains a live reference to the source scene. Use this instead of add_node when you want to reuse an existing scene.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the scene file being edited (the parent scene)'
        },
        instance_path: {
          type: 'string',
          description: 'Path to the .tscn scene to instance (the child/prefab scene)'
        },
        node_name: {
          type: 'string',
          description: 'Optional name for the instance. If omitted, uses the instanced scene\'s root node name.'
        },
        parent_path: {
          type: 'string',
          description: 'Path to parent node within the scene (. for root, or relative path like Level/Enemies)'
        },
        properties: {
          type: 'object',
          description: 'Optional property overrides on the instance root (e.g., {position: {type: "Vector3", x: 5, y: 0, z: 10}})'
        }
      },
      required: ['scene_path', 'instance_path']
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
    description: 'Modify a property on a node in a .tscn scene file. ALWAYS use this tool to modify properties in scene files - NEVER edit .tscn files directly. Supports 3D typed values such as Quaternion, Basis, Transform3D, and AABB in addition to vectors, colors, and primitives.',
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
          oneOf: [
            { type: 'object' },
            { type: 'array' },
            { type: 'string' },
            { type: 'number' },
            { type: 'boolean' }
          ],
          description: 'New value. Examples: {type:"Vector3",x:1,y:2,z:3}, {type:"Quaternion",x:0,y:0,z:0,w:1}, {type:"Basis",euler:{x:0,y:1.57,z:0}}, {type:"Transform3D",basis:{type:"Basis",euler:{x:0,y:0,z:0}},origin:{x:0,y:2,z:0}}, {type:"AABB",position:{x:-1,y:0,z:-1},size:{x:2,y:1,z:2}}. For primitives, use directly.'
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
  },
  {
    name: 'set_mesh',
    description: 'Create and assign a mesh resource to a MeshInstance3D node. REQUIRED to make 3D geometry visible. Primitive types: BoxMesh, SphereMesh, CylinderMesh, CapsuleMesh, PlaneMesh, PrismMesh, TorusMesh, QuadMesh, TextMesh. Or load from file.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the MeshInstance3D node within the scene'
        },
        mesh_type: {
          type: 'string',
          description: 'Mesh class: "BoxMesh", "SphereMesh", "CylinderMesh", "CapsuleMesh", "PlaneMesh", "PrismMesh", "TorusMesh", "QuadMesh", "TextMesh", or "file" to load from a resource path'
        },
        mesh_params: {
          type: 'object',
          description: 'BoxMesh: {size:{x,y,z}}. SphereMesh: {radius,height,radial_segments,rings}. CylinderMesh: {top_radius,bottom_radius,height}. CapsuleMesh: {radius,height}. PlaneMesh: {size:{x,y}}. PrismMesh: {left_to_right,size:{x,y,z}}. TorusMesh: {inner_radius,outer_radius,rings}. QuadMesh: {size:{x,y}}. TextMesh: {text,font_size,depth}. file: {path:"res://mesh.tres"}'
        }
      },
      required: ['scene_path', 'mesh_type']
    }
  },
  {
    name: 'set_material',
    description: 'Create and assign a material to a MeshInstance3D, CSG, or GeometryInstance3D node. Supports StandardMaterial3D or loading from file.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the target node'
        },
        material_type: {
          type: 'string',
          description: '"StandardMaterial3D" or "file" to load from a resource path'
        },
        material_params: {
          type: 'object',
          description: 'StandardMaterial3D: {albedo_color:{r,g,b,a}, metallic:0-1, roughness:0-1, emission:{r,g,b}, emission_energy:float, transparency:0=disabled/1=alpha/2=scissor/3=hash/4=depth_pre_pass}. file: {path:"res://material.tres"}'
        },
        surface_index: {
          type: 'number',
          description: 'For MeshInstance3D only: surface index for per-surface override. Omit for material_override on all surfaces.'
        }
      },
      required: ['scene_path', 'material_type']
    }
  },
  {
    name: 'get_node_spatial_info',
    description: 'Query computed 3D spatial data for a Node3D in a scene file. Returns local/global transforms, positions, scales, quaternions, and subtree bounds when available. Use this before making precise placement decisions.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the Node3D (. for root, or relative path like Level/Props/Crate)'
        },
        include_bounds: {
          type: 'boolean',
          description: 'Include computed subtree AABBs when visual descendants exist (default: true)'
        }
      },
      required: ['scene_path']
    }
  },
  {
    name: 'measure_node_distance',
    description: 'Measure the world-space distance between two Node3D nodes in a scene file. Returns both the full 3D delta and the horizontal XZ distance.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        from_node_path: {
          type: 'string',
          description: 'Path to the first Node3D'
        },
        to_node_path: {
          type: 'string',
          description: 'Path to the second Node3D'
        }
      },
      required: ['scene_path', 'from_node_path', 'to_node_path']
    }
  },
  {
    name: 'snap_node_to_grid',
    description: 'Snap a Node3D position to a grid in local or global space. Useful for modular level building and keeping 3D scenes aligned.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the Node3D to snap'
        },
        grid_size: {
          description: 'Positive grid size. Use a number for uniform snapping or {x,y,z} for per-axis snapping.',
          oneOf: [
            { type: 'number' },
            {
              type: 'object',
              properties: {
                x: { type: 'number' },
                y: { type: 'number' },
                z: { type: 'number' }
              },
              required: ['x', 'y', 'z']
            }
          ]
        },
        axes: {
          type: 'array',
          items: { type: 'string' },
          description: 'Axes to snap. Any of: ["x"], ["x","z"], ["x","y","z"] (default: all axes)'
        },
        space: {
          type: 'string',
          description: 'Coordinate space: "local" or "global" (default: "global")'
        }
      },
      required: ['scene_path', 'grid_size']
    }
  },
  {
    name: 'place_node_relative',
    description: 'Place one Node3D relative to another using bounds-aware world-axis relationships. Supports on_top_of, below, left_of, right_of, in_front_of, behind, and centered.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the Node3D that should be moved'
        },
        target_node_path: {
          type: 'string',
          description: 'Path to the anchor Node3D'
        },
        relation: {
          type: 'string',
          description: 'Placement relation: "on_top_of", "below", "left_of", "right_of", "in_front_of", "behind", or "centered"'
        },
        gap: {
          type: 'number',
          description: 'Optional spacing to leave between the moved node and the target (default: 0)'
        },
        use_bounds: {
          type: 'boolean',
          description: 'Use subtree bounds when available; otherwise fall back to node origins (default: true)'
        }
      },
      required: ['scene_path', 'node_path', 'target_node_path']
    }
  }
];
