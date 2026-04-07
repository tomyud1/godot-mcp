/**
 * Tests for scene-tools module
 */

import { describe, it, expect } from 'vitest';
import { sceneTools } from '../tools/scene-tools.js';

describe('scene-tools', () => {
  describe('tool definitions', () => {
    it('should export scene tools', () => {
      expect(sceneTools.length).toBeGreaterThan(0);
    });

    it('should have create_scene tool', () => {
      const tool = sceneTools.find(t => t.name === 'create_scene');
      expect(tool).toBeDefined();
    });

    it('should have read_scene tool', () => {
      const tool = sceneTools.find(t => t.name === 'read_scene');
      expect(tool).toBeDefined();
    });
  });

  describe('create_scene tool', () => {
    let tool: typeof sceneTools[0];

    beforeEach(() => {
      tool = sceneTools.find(t => t.name === 'create_scene')!;
    });

    it('should have correct name', () => {
      expect(tool.name).toBe('create_scene');
    });

    it('should require scene_path and root_node_type', () => {
      expect(tool.inputSchema.required).toContain('scene_path');
      expect(tool.inputSchema.required).toContain('root_node_type');
    });

    it('should have root_node_type property', () => {
      expect(tool.inputSchema.properties.root_node_type.type).toBe('string');
    });

    it('should have nodes array property', () => {
      expect(tool.inputSchema.properties.nodes.type).toBe('array');
    });

    it('should have optional root_node_name', () => {
      expect(tool.inputSchema.properties.root_node_name).toBeDefined();
      expect(tool.inputSchema.required).not.toContain('root_node_name');
    });
  });

  describe('read_scene tool', () => {
    let tool: typeof sceneTools[0];

    beforeEach(() => {
      tool = sceneTools.find(t => t.name === 'read_scene')!;
    });

    it('should have correct name', () => {
      expect(tool.name).toBe('read_scene');
    });

    it('should require scene_path', () => {
      expect(tool.inputSchema.required).toContain('scene_path');
    });

    it('should have include_properties option', () => {
      expect(tool.inputSchema.properties.include_properties).toBeDefined();
    });
  });

  describe('add_node tool', () => {
    let tool: typeof sceneTools[0];

    beforeEach(() => {
      tool = sceneTools.find(t => t.name === 'add_node')!;
    });

    it('should have correct name', () => {
      expect(tool.name).toBe('add_node');
    });

    it('should require scene_path and node_type', () => {
      expect(tool.inputSchema.required).toContain('scene_path');
      expect(tool.inputSchema.required).toContain('node_type');
    });
  });

  describe('tool descriptions', () => {
    it('should have descriptive descriptions', () => {
      sceneTools.forEach(tool => {
        expect(tool.description).toBeTruthy();
        expect(tool.description.length).toBeGreaterThan(10);
      });
    });
  });
});
