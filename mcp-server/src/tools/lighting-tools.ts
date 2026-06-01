import type { ToolDefinition } from '../types.js';

export const lightingTools: ToolDefinition[] = [
  {
    name: 'get_light_info',
    description: 'Inspect a 3D light in a scene file. Returns transform data, shadow settings, emitted direction, and directional-light diagnostics such as sun angles and scene-tree sky order.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Optional path to the Light3D node. If omitted, the first Light3D in the scene is used.'
        },
        runtime: {
          type: 'boolean',
          description: 'Inspect the currently open editor scene tree instead of loading the .tscn file from disk. This sees live editor-state overrides, but not the separate running game process.'
        }
      },
      required: ['scene_path']
    }
  },
  {
    name: 'set_sun_light',
    description: 'Configure a DirectionalLight3D using sun-style azimuth/elevation angles instead of raw Euler rotation. This prevents the common error of lighting the scene from below. Also accepts optional shadow, color, and directional-shadow settings.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        node_path: {
          type: 'string',
          description: 'Optional path to the DirectionalLight3D node. If omitted, the first DirectionalLight3D in the scene is used.'
        },
        elevation_degrees: {
          type: 'number',
          description: 'Sun elevation above the horizon in degrees. Positive values place the sun above the horizon and point the light downward.'
        },
        azimuth_degrees: {
          type: 'number',
          description: 'Sun compass angle around +Y in degrees. 0 = sun in front of the scene along -Z, 90 = sun on +X.'
        },
        allow_below_horizon: {
          type: 'boolean',
          description: 'Allow negative sun elevation values. Defaults to false to guard against accidental under-lighting.'
        },
        color: {
          type: 'object',
          description: 'Optional light color, e.g. {type:"Color",r:1,g:0.95,b:0.9,a:1}'
        },
        energy: {
          type: 'number',
          description: 'Optional Light3D.light_energy value'
        },
        indirect_energy: {
          type: 'number',
          description: 'Optional Light3D.light_indirect_energy value'
        },
        volumetric_fog_energy: {
          type: 'number',
          description: 'Optional Light3D.light_volumetric_fog_energy value'
        },
        specular: {
          type: 'number',
          description: 'Optional Light3D.light_specular value'
        },
        temperature_kelvin: {
          type: 'number',
          description: 'Optional Light3D.light_temperature value'
        },
        angular_distance: {
          type: 'number',
          description: 'Optional Light3D.light_angular_distance value for sun disc size / softening'
        },
        shadow_enabled: {
          type: 'boolean',
          description: 'Enable or disable shadows'
        },
        shadow_bias: {
          type: 'number',
          description: 'Optional Light3D.shadow_bias value'
        },
        shadow_normal_bias: {
          type: 'number',
          description: 'Optional Light3D.shadow_normal_bias value'
        },
        shadow_blur: {
          type: 'number',
          description: 'Optional Light3D.shadow_blur value'
        },
        light_cull_mask: {
          type: 'number',
          description: 'Optional Light3D.light_cull_mask value'
        },
        shadow_caster_mask: {
          type: 'number',
          description: 'Optional Light3D.shadow_caster_mask value'
        },
        editor_only: {
          type: 'boolean',
          description: 'Optional Light3D.editor_only value'
        },
        visible: {
          type: 'boolean',
          description: 'Optional Node3D.visible value'
        },
        sky_mode: {
          oneOf: [{ type: 'string' }, { type: 'number' }],
          description: 'Optional DirectionalLight3D.sky_mode. Use light_and_sky, light_only, sky_only, or a numeric enum value.'
        },
        directional_shadow_mode: {
          oneOf: [{ type: 'string' }, { type: 'number' }],
          description: 'Optional DirectionalLight3D.directional_shadow_mode. Use orthogonal, parallel_2_splits, parallel_4_splits, or a numeric enum value.'
        },
        directional_shadow_max_distance: {
          type: 'number',
          description: 'Optional DirectionalLight3D.directional_shadow_max_distance value'
        },
        directional_shadow_blend_splits: {
          type: 'boolean',
          description: 'Optional DirectionalLight3D.directional_shadow_blend_splits value'
        },
        directional_shadow_fade_start: {
          type: 'number',
          description: 'Optional DirectionalLight3D.directional_shadow_fade_start value'
        },
        directional_shadow_split_1: {
          type: 'number',
          description: 'Optional DirectionalLight3D.directional_shadow_split_1 value'
        },
        directional_shadow_split_2: {
          type: 'number',
          description: 'Optional DirectionalLight3D.directional_shadow_split_2 value'
        },
        directional_shadow_split_3: {
          type: 'number',
          description: 'Optional DirectionalLight3D.directional_shadow_split_3 value'
        },
        directional_shadow_pancake_size: {
          type: 'number',
          description: 'Optional DirectionalLight3D.directional_shadow_pancake_size value'
        }
      },
      required: ['scene_path']
    }
  },
  {
    name: 'validate_scene_lighting',
    description: 'Run a scene-wide diagnostic over all DirectionalLight3D nodes. Reports Euler rotations, emitted directions, shadow/energy issues, conflicting sun directions, sky-order problems, and attached scripts that may override lighting at runtime.',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: {
          type: 'string',
          description: 'Path to the .tscn scene file'
        },
        runtime: {
          type: 'boolean',
          description: 'Inspect the currently open editor scene tree instead of loading the .tscn file from disk. This sees live editor-state overrides, but not the separate running game process.'
        }
      },
      required: ['scene_path']
    }
  }
];
