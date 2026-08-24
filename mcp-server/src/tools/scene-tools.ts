/**
 * Scene operation tools for Godot MCP Server
 * Tools for creating, reading, and modifying Godot scenes (.tscn files)
 */

import type { ToolDefinition } from '../types.js';

export const sceneTools: ToolDefinition[] = [
  {
    name: 'create_scene',
    description: 'Create a new Godot scene (.tscn) file with nodes. Use this to create player scenes, UI screens, game objects, etc.\n\n**Atomic pre-validation:** the entire spec (root, attach_script, every entry of `nodes`, and recursively their `children` / `properties` / `script`) is walked and validated BEFORE the scene file is created. If any node_type isn\'t a known class, any property name doesn\'t exist on its target class (plus the attached script\'s @export\'d properties when present), or any script path is missing / isn\'t a Script — the call returns `ok: false` with a `validation_errors` array of path-pointed messages (`nodes[1].children[2].properties.text: property does not exist on Sprite2D`) and ZERO filesystem mutation. Fix all listed issues in one shot.',
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
          items: { type: 'object', description: 'A node spec: {name|node_name, type|node_type, properties?, script?, groups?, children?}. Unknown keys are rejected with an error.' },
          description: 'Array of child nodes to add. Each node spec: {name|node_name, type|node_type, properties?, script?, groups?, children?}. Use either {name, type} or the same {node_name, node_type} keys used at the top level \u2014 both work. Unknown keys (e.g. "class", "kind", "parent") return an error instead of silently producing a generic Node.'
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
    description: 'Read and parse a scene file to get its full node structure and properties. Use this to understand a scene before editing. NOTE: `include_properties: true` returns a hand-picked subset (position, rotation, scale, size, offset, visible, modulate, z_index, text, collision_layer, collision_mask, mass) optimized for quick scene overviews. To see ALL properties on a specific node — including @export\'d script vars — use `get_scene_node_properties`.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the scene file (res://path/to/scene.tscn)'
        },
        include_properties: {
          type: 'boolean',
          description: 'Include the curated property subset above on each node (default: false). For a full per-node property dump use get_scene_node_properties.'
        }
      },
      required: ['scene_path']
    }
  },
  {
    name: 'get_scene_node_properties',
    description: 'Return the FULL property list of a single node in a .tscn file, including @export\'d script vars and inherited properties — with current values, declared variant types, hint metadata, and a category grouping. Complements `read_scene` (which uses a curated subset of common properties for quick tree overviews) and `get_node_properties` (which returns class-level metadata, not a specific node\'s current values). Use this to verify a property was actually set after `add_node` / `set_node_properties` (especially for script @export vars), or to discover the exact name of a property you can\'t remember (handy when AI suggestions like "color" turn out to be "modulate"). Returns `{ok, scene_path, node_path, node_type, node_name, inheritance_chain, property_count, properties, categories}`.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the scene file (res://path/to/scene.tscn)'
        },
        node_path: {
          type: 'string',
          description: 'Path to the node within the scene (. for root, or relative path like "UI/HUD/Label"). Defaults to "." (scene root).'
        }
      },
      required: ['scene_path']
    }
  },
  {
    name: 'add_node',
    description: 'Add a node to an existing scene file. Supports an optional script attachment, group memberships, and a tree of children created in the same call (1 tool call instead of N). Children format: {name|node_name, type|node_type, properties?, script?, groups?, children?}. Both key styles are accepted so children can reuse the same keys you use at the top level (node_name, node_type) or the shorter form (name, type). Unknown child keys are rejected with a clear error.\n\n**Atomic pre-validation:** the entire spec (top-level node + every descendant in `children`, recursively) is walked and validated BEFORE the .tscn is loaded from disk. Property names are checked against ClassDB + the attached script\'s @export\'d properties; `script` paths are checked for existence and Script-ness; node_types are checked against ClassDB. If anything fails, returns `ok: false` with `validation_errors: [...]` listing every issue with path-pointed prefixes (e.g. `children[2].properties.text: property does not exist on Sprite2D`), and ZERO mutation. Previously a typo like `properties: {color: ...}` on a Sprite2D would be silently swallowed; now it surfaces immediately.',
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
        },
        script: {
          type: 'string',
          description: 'Optional script path to attach to the new node (res://path/to/script.gd)'
        },
        groups: {
          type: 'array',
          items: { type: 'string' },
          description: 'Optional list of node groups this node should belong to. Persisted to the .tscn file.'
        },
        children: {
          type: 'array',
          items: { type: 'object', description: '{name, type, properties?, script?, groups?, children?}' },
          description: 'Optional tree of children to create under the new node. Each entry has the same shape as add_node\'s args (minus parent_path). Use this to build sub-trees in one call.'
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
    description: 'Modify a single property on a node in a .tscn scene file. For multiple properties at once use set_node_properties. ALWAYS use a tool to modify .tscn files \u2014 NEVER edit them as text. To attach or change a script, use attach_script (NOT modify_node_property with property="script") \u2014 modify_node_property only rewrites the .tscn on disk, leaving the editor\'s in-memory node without the script, which makes connect_signal fail.',
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
          description: 'New value for the property. ANY JSON value accepted: primitives (numbers, strings, booleans, null), arrays, or objects. Use the {type, ...} discriminated form for Godot variant types. Common forms: numeric (e.g. 1.5), boolean (true), string ("hello"), Vector2 ({type:"Vector2",x,y}), Vector3 ({type:"Vector3",x,y,z}), Color ({type:"Color",r,g,b,a}), Quaternion ({type:"Quaternion",x,y,z,w}), Basis ({type:"Basis",euler:{x,y,z}}), Transform3D ({type:"Transform3D",basis:{...},origin:{x,y,z}}), AABB ({type:"AABB",position:{x,y,z},size:{x,y,z}}), Rect2 ({type:"Rect2",x,y,width,height}), NodePath (string starting with "."). For Resource-typed properties (Texture2D, Mesh, Material, Shape, etc.) DO NOT pass values here \u2014 use set_resource_property, set_sprite_texture, set_mesh, set_material, or set_collision_shape.'
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
    description: 'Assign a texture resource to a Sprite2D / Sprite3D / TextureRect node in a .tscn scene file. Modes:\n  \u2022 FromPath  \u2014 load any texture file from disk (png/jpg/webp/svg/.tres) via load(). Returns whatever Texture2D the importer produced (usually CompressedTexture2D). Most common after generate_2d_asset.\n  \u2022 ImageTexture (DEPRECATED ALIAS for FromPath, kept for back-compat)\n  \u2022 NewImageTexture \u2014 force-create an ImageTexture (in-memory) from a raw image file.\n  \u2022 PlaceholderTexture2D \u2014 in-scene placeholder of a given size.\n  \u2022 GradientTexture2D / NoiseTexture2D \u2014 procedural textures.\nResponse always includes texture_class (the actual Godot class the texture decoded to), width, height, and texture_path so the agent can confirm what landed without an extra get_resource_info call.',
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
          enum: ['FromPath', 'ImageTexture', 'NewImageTexture', 'PlaceholderTexture2D', 'GradientTexture2D', 'NoiseTexture2D'],
          description: 'How to obtain the texture. Prefer FromPath for assets on disk.'
        },
        texture_params: {
          type: 'object',
          description: 'Texture parameters. FromPath / ImageTexture / NewImageTexture: {path: "res://assets/sprite.png"}. PlaceholderTexture2D: {size: {x: 64, y: 64}}. GradientTexture2D / NoiseTexture2D: {width, height}.'
        }
      },
      required: ['scene_path', 'texture_type']
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
    description: 'Query computed 3D spatial data for a Node3D in a scene file. Returns local/global positions, scales, rotation quaternions, and subtree bounding boxes (AABB) when available. Use this before making precise 3D placement decisions.',
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
    name: 'set_node_properties',
    description: 'Set MULTIPLE properties on a node in a single tool call. **Atomic pre-validation** — every entry is checked (name exists on the node\'s class plus its attached script\'s @export\'d properties; Resource-typed properties must use the dedicated resource tools) BEFORE anything is written. If ANY entry fails, the response is `ok: false` with a `validation_errors` array (e.g. `properties.color: property does not exist on Sprite2D`) and ZERO mutation occurs — no scene save, no half-applied state. On success, returns the `applied` list with old/new values per property. Resource-typed properties must use set_resource_property / set_sprite_texture / set_mesh / set_material / set_collision_shape.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: { type: 'string', description: 'Path to the .tscn scene file' },
        node_path: { type: 'string', description: 'Path to the node (. for root, or relative path)' },
        properties: {
          type: 'object',
          description: 'Map of property_name -> value. Each value follows the same form as modify_node_property.value (primitives, arrays, or {type:"Vector3",...} discriminated objects).'
        }
      },
      required: ['scene_path', 'properties']
    }
  },
  {
    name: 'set_node_groups',
    description: 'Set, add, or remove a node\'s group memberships in a .tscn scene file. Groups persist to disk so the running game can call get_tree().get_nodes_in_group(name).',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: { type: 'string', description: 'Path to the .tscn scene file' },
        node_path: { type: 'string', description: 'Path to the node (. for root)' },
        groups: { type: 'array', items: { type: 'string' }, description: 'List of group names to apply' },
        mode: {
          type: 'string',
          enum: ['replace', 'add', 'remove'],
          description: 'replace (default): node ends up in EXACTLY the listed groups. add: union with existing. remove: drop the listed groups.'
        }
      },
      required: ['scene_path', 'groups']
    }
  },
  {
    name: 'get_node_groups',
    description: 'Read the list of groups a node belongs to in a .tscn scene file.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: { type: 'string' },
        node_path: { type: 'string' }
      },
      required: ['scene_path']
    }
  },
  {
    name: 'find_nodes',
    description: 'Search a .tscn file for nodes matching one or more filters. Filters AND together; pass any subset. Scene-scoped — for project-wide text search use search_project instead. Returns one entry per match with path (relative to scene root, "." = root), name, type (Godot class), and groups.\n\nFilters:\n  \u2022 name_pattern: case-insensitive. If it contains "*" or "?" it is treated as a glob (matchn); otherwise as a substring (findn).\n  \u2022 type: Godot class name (e.g. "Node2D", "CharacterBody3D", "Button"). Matches the node\'s class AND any subclass (so "Node2D" matches "Sprite2D"). Also matches custom script class_names registered globally via "class_name". Unknown types return an error (not silent zero matches).\n  \u2022 in_group: exact group name; matches nodes where is_in_group() returns true.\n  \u2022 recursive (default true): when false, only the scene root and its direct children are checked.\n\nIf scene_path is omitted, defaults to the currently edited scene in the editor (must be saved at least once). Loads from disk like all other scene tools, so unsaved in-editor edits are not seen.\n\nNo filters at all returns every node in the scene — handy as a structured alternative to scene_tree_dump.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: { type: 'string', description: 'Path to the .tscn scene file (res://...). Optional; defaults to the editor\'s current edited scene.' },
        name_pattern: { type: 'string', description: 'Case-insensitive match against node names. Glob (contains "*"/"?") or substring otherwise.' },
        type: { type: 'string', description: 'Godot class name or globally registered script class_name. Matches class AND subclasses (is_a check).' },
        in_group: { type: 'string', description: 'Group name to filter by.' },
        recursive: { type: 'boolean', description: 'Traverse the whole subtree (default true). If false, only the scene root and its direct children are checked.' }
      },
      required: []
    }
  },
  {
    name: 'set_resource_property',
    description: 'Modify a property on a Resource that is currently held by a node (or by another resource attached to that node). Use this to tweak shape radii, material colors, gradient stops, etc., WITHOUT recreating the resource. resource_path walks from the node down to the resource using "/"-separated property names, e.g. "shape", "material", or "material/next_pass". After the change, saves the scene.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: { type: 'string', description: 'Path to the .tscn scene file' },
        node_path: { type: 'string', description: 'Path to the node owning the resource' },
        resource_path: { type: 'string', description: 'Path from node to the target resource via property names. Examples: "shape", "material", "material/next_pass"' },
        property_name: { type: 'string', description: 'Property on the target resource to set (e.g. "radius", "albedo_color")' },
        value: { description: 'New value (same shape as modify_node_property.value)' }
      },
      required: ['scene_path', 'resource_path', 'property_name', 'value']
    }
  },
  {
    name: 'save_resource_to_file',
    description: 'Save a Resource currently held by a node (or sub-resource) to a standalone .tres file so it can be referenced by other scenes / shared / committed. The node\'s property is then re-pointed to the loaded-from-disk version, so future set_resource_property calls write through to that file. Works for any Resource subclass: Material, Mesh, Shape, Curve, Gradient, etc.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: { type: 'string' },
        node_path: { type: 'string' },
        resource_path: { type: 'string', description: 'Path from node to the resource (e.g. "shape", "material")' },
        save_to: { type: 'string', description: 'Destination path (res://.../foo.tres)' }
      },
      required: ['scene_path', 'resource_path', 'save_to']
    }
  },
  {
    name: 'get_resource_info',
    description: 'Inspect ANY Godot Resource. Two modes:\n  \u2022 path mode: pass {path: "res://foo.png"} for a resource on disk (.tres / .res / image / .glb / .ogg / .tscn / etc.)\n  \u2022 node mode: pass {scene_path, node_path, resource_property} to inspect a resource attached to a node WITHOUT having to save it as .tres first (e.g. the shape on a CollisionShape2D, the material on a MeshInstance3D, the stream on an AudioStreamPlayer).\nReturns class, file size (path mode), and type-specific info: width/height for textures, vertex/surface counts and AABB for meshes, length for AudioStream/Animation, node count for PackedScene, common Material properties, Shape extents, and the resource\'s dependencies.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Path mode: resource path on disk (res://...).' },
        scene_path: { type: 'string', description: 'Node mode: path to the .tscn that owns the node.' },
        node_path: { type: 'string', description: 'Node mode: path to the node within the scene.' },
        resource_property: { type: 'string', description: 'Node mode: property name on the node holding the resource (e.g. "shape", "material", "stream", "texture").' }
      }
    }
  },
  {
    name: 'list_signal_connections',
    description: 'List signal connections involving a node. source="scene_file" (default) reads connections persisted to a .tscn. source="runtime" requires the game to be running and reads live connections from the SceneTree. Use the runtime mode to verify dynamically-connected signals (those connected from code in _ready, not in the editor).',
    inputSchema: {
      type: 'object',
      properties: {
        source: { type: 'string', enum: ['scene_file', 'runtime'], description: 'Where to read connections from. Default: scene_file' },
        scene_path: { type: 'string', description: 'For source="scene_file": path to the .tscn' },
        node_path: { type: 'string', description: 'Path to the node. For source="runtime" use absolute (/root/Main/Player) or relative to current_scene.' },
        include_outgoing: { type: 'boolean', description: 'Include signals that this node emits (default: true)' },
        include_incoming: { type: 'boolean', description: 'Include signals from other nodes whose handler is on this node (default: true). Only honored for scene_file source.' }
      },
      required: ['node_path']
    }
  },
  {
    name: 'connect_signal',
    description: 'Connect a signal between two nodes inside a .tscn scene file. The target script must define the method (will refuse otherwise). Equivalent to clicking the "+" in the editor\'s Node > Signals panel and persists the connection to the .tscn. NOTE: scripts must be attached via attach_script (NOT via modify_node_property), otherwise the editor\'s in-memory node will not see the script and this tool will reject the connection.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: { type: 'string' },
        from_node: { type: 'string', description: 'Path to the emitting node' },
        signal: { type: 'string', description: 'Signal name on the emitting node' },
        to_node: { type: 'string', description: 'Path to the receiving node' },
        method: { type: 'string', description: 'Method name on the receiving node\'s script' },
        flags: { type: 'number', description: 'Connection flags (CONNECT_DEFERRED=1, CONNECT_PERSIST=2, CONNECT_ONE_SHOT=4). Default 0.' }
      },
      required: ['scene_path', 'from_node', 'signal', 'to_node', 'method']
    }
  },
  {
    name: 'disconnect_signal',
    description: 'Remove a signal connection from a .tscn scene file. No-op if the connection doesn\'t exist.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: { type: 'string' },
        from_node: { type: 'string' },
        signal: { type: 'string' },
        to_node: { type: 'string' },
        method: { type: 'string' }
      },
      required: ['scene_path', 'from_node', 'signal', 'to_node', 'method']
    }
  },
  {
    name: 'call_method',
    description:
      "Invoke any method on any node, in either the editor's on-disk scene or the running game. The write counterpart to query_runtime_node (which only reads).\n\n" +
      "**Two modes** controlled by `runtime`:\n" +
      "  • `runtime: false` (default, editor mode) — Loads the .tscn from disk, finds the node, invokes the method, ALWAYS saves the scene back. Snapshot taken so `mcp_undo` reverts the file. Use for **engine/built-in methods that mutate persistent scene state**: `CollisionObject2D.set_collision_layer_value(layer, on)`, `Curve2D.add_point(pos)`, `Node.add_user_signal(name)`, `Node.add_to_group(name, true)` (the `true` is required to persist into the .tscn).\n" +
      "    ⚠️ **Editor mode cannot run user-defined methods in non-@tool scripts.** Godot's editor instantiates scenes with `GEN_EDIT_STATE_MAIN`, which attaches scripts and lets `@export` vars round-trip but does NOT dispatch user method bodies for non-@tool scripts. `call_method` detects this case and refuses with `reason: \"non_tool_script_method\"` — DO NOT use editor mode to invoke `take_damage`, `respawn`, `play_intro`, or any other game-logic method on your script. Use runtime mode for that.\n" +
      "  • `runtime: true` — Routes the call to the MCPRuntime helper inside the running game. Finds the live node in the active SceneTree, invokes the method, returns the serialized result. Use to drive the game from the AI: `Player.take_damage(50)`, `AnimationPlayer.play(\"intro\")`, `AudioStreamPlayer.play()`, `Inventory.add_item(\"sword\", 1)`. REQUIRES `run_scene` first (the game must be running) — same precondition as query_runtime_node / send_input.\n\n" +
      "**node_path resolution:**\n" +
      "  • editor mode — relative to scene root, e.g. \"Player\" or \"UI/HUD/HealthLabel\", or \".\" for root.\n" +
      "  • runtime mode — absolute (\"/root/Main/Player\") OR relative to current_scene (\"Player\"). Same rules as query_runtime_node.\n\n" +
      "**args** — array of positional arguments. Each follows the same form as `modify_node_property.value`: primitives (`1.5`, `\"hello\"`, `true`, `null`), arrays, or `{type:\"Vector2\",x,y}` / `{type:\"Color\",r,g,b,a}` / `{type:\"NodePath\",...}` / `{type:\"Resource\",path:\"res://...\"}` discriminated objects.\n\n" +
      "**Method validation** — on miss, returns `closest_matches` (top similar method names) and an `available_methods_sample` so the AI can self-correct. Arity is also pre-checked against `MethodInfo` (with default-arg awareness).\n\n" +
      "**Destructive denylist** — `queue_free`, `free`, `set_script`, `remove_child`, `replace_by`, `reparent` require `confirm: true`. In runtime mode, calls directly on `/root/<name>` (likely autoloads or the active scene root) also require confirm. Use `attach_script` / `detach_script` / `remove_node` instead of the corresponding raw method calls in editor mode.\n\n" +
      "**Coroutines** — methods containing `await` return a `GDScriptFunctionState`. Such calls are dispatched fire-and-forget: `is_coroutine: true, awaited: false` is reported, side effects still run, but the return value is not captured. Follow up with `wait` + `query_runtime_node` to observe results.\n\n" +
      "**Return shape (success):** `{ok:true, runtime, scene_path?, node_path, node_class, method, method_signature?, duration_ms, return_value?, return_type?, awaited, is_coroutine}`. `awaited` and `is_coroutine` are ALWAYS present (stable for parsing). `return_value` / `return_type` are omitted when `expect_return: false` or the method is a coroutine. Object/Node returns are serialized as `{type:\"Object\", class, name?, node_path?, serializable:false}` — follow up with `query_runtime_node` to inspect properties. Resource returns are `{type:\"Resource\", class, resource_path?}`.",
    inputSchema: {
      type: 'object',
      properties: {
        node_path: {
          type: 'string',
          description: 'Path to the target node. Editor mode: relative to scene root (e.g. "Player", "UI/HUD/Label", or "." for root). Runtime mode: absolute (/root/Main/Player) or relative to current_scene (Player).'
        },
        method: {
          type: 'string',
          description: 'Method name on the target node. Validated against node.has_method(); on miss returns closest_matches and available_methods_sample.'
        },
        args: {
          type: 'array',
          items: { description: 'Positional argument. Primitive, array, or {type:"Vector2"|"Vector3"|"Color"|"Resource"|...} discriminated object — same form as modify_node_property.value.' },
          description: 'Positional arguments to pass. Default: []. Arity is pre-checked against the method signature (allowing for default arguments).'
        },
        scene_path: {
          type: 'string',
          description: 'Editor mode only: which .tscn to operate on. Defaults to the editor\'s currently edited scene (must be saved at least once). Ignored when runtime=true.'
        },
        runtime: {
          type: 'boolean',
          description: 'When true, call on the live node in the running game via MCPRuntime. Requires the game to be running (run_scene first). When false (default), operates on the .tscn file in the editor.'
        },
        expect_return: {
          type: 'boolean',
          description: 'Capture and serialize the return value (default: true). Set false for void / fire-and-forget calls to skip serialization in the response.'
        },
        confirm: {
          type: 'boolean',
          description: 'Required for methods on the destructive denylist (queue_free, free, set_script, remove_child, replace_by, reparent) and, in runtime mode, for direct calls on /root/<name> (autoload/scene root territory). Defaults false.'
        }
      },
      required: ['node_path', 'method']
    }
  }
];
