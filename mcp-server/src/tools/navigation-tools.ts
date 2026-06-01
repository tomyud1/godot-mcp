import type { ToolDefinition } from '../types.js';

export const navigationTools: ToolDefinition[] = [
  {
    name: 'set_navigation_mesh',
    description: 'Create or update the NavigationMesh resource on a NavigationRegion3D. Use this to configure bake settings before baking a navmesh.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the NavigationRegion3D (. for root, or a relative node path)'
        },
        create_if_missing: {
          type: 'boolean',
          description: 'Create a new NavigationMesh if the region does not already have one (default: true)'
        },
        duplicate_external_resource: {
          type: 'boolean',
          description: 'If the region uses an external NavigationMesh resource, duplicate it into the scene before editing so changes persist with the scene (default: true)'
        },
        region_settings: {
          type: 'object',
          description: 'Optional NavigationRegion3D settings such as {enabled, use_edge_connections, navigation_layers, enter_cost, travel_cost}'
        },
        navigation_mesh_settings: {
          type: 'object',
          description: 'Optional NavigationMesh bake settings. Supported keys include agent_radius, agent_height, agent_max_climb, agent_max_slope, border_size, cell_size, cell_height, detail_sample_distance, detail_sample_max_error, edge_max_error, edge_max_length, filter_ledge_spans, filter_low_hanging_obstacles, filter_walkable_low_height_spans, filter_baking_aabb, filter_baking_aabb_offset, geometry_collision_mask, geometry_parsed_geometry_type, geometry_source_geometry_mode, geometry_source_group_name, sample_partition_type, region_merge_size, region_min_size, and vertices_per_polygon. Enum settings accept numeric values or strings: geometry_parsed_geometry_type = mesh_instances|static_colliders|both, geometry_source_geometry_mode = root_node_children|groups_with_children|groups_explicit, sample_partition_type = watershed|monotone|layers.'
        }
      },
      required: ['scene_path']
    }
  },
  {
    name: 'get_navigation_mesh_info',
    description: 'Inspect a NavigationRegion3D and its NavigationMesh resource. Returns region settings, bake settings, and whether the navmesh contains baked polygon data.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the NavigationRegion3D (. for root, or a relative node path)'
        }
      },
      required: ['scene_path']
    }
  },
  {
    name: 'bake_navigation_mesh',
    description: 'Bake the NavigationMesh on a NavigationRegion3D using Godot\'s non-deprecated region bake API. Applies optional region and NavigationMesh settings before baking, then saves the scene.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Path to the NavigationRegion3D (. for root, or a relative node path)'
        },
        create_if_missing: {
          type: 'boolean',
          description: 'Create a new NavigationMesh if the region does not already have one (default: true)'
        },
        duplicate_external_resource: {
          type: 'boolean',
          description: 'If the region uses an external NavigationMesh resource, duplicate it into the scene before baking so the baked result persists with the scene (default: true)'
        },
        region_settings: {
          type: 'object',
          description: 'Optional NavigationRegion3D settings such as {enabled, use_edge_connections, navigation_layers, enter_cost, travel_cost}'
        },
        navigation_mesh_settings: {
          type: 'object',
          description: 'Optional NavigationMesh bake settings to apply immediately before baking. Uses the same keys and enum values as set_navigation_mesh.'
        }
      },
      required: ['scene_path']
    }
  }
];
