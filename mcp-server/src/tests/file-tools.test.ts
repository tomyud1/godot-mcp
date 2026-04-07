/**
 * Tests for file-tools module
 */

import { describe, it, expect } from 'vitest';
import { fileTools } from '../tools/file-tools.js';

describe('file-tools', () => {
  describe('tool definitions', () => {
    it('should export 4 file tools', () => {
      expect(fileTools).toHaveLength(4);
    });

    it('should have correct tool names', () => {
      const toolNames = fileTools.map(t => t.name);
      expect(toolNames).toContain('list_dir');
      expect(toolNames).toContain('read_file');
      expect(toolNames).toContain('search_project');
      expect(toolNames).toContain('create_script');
    });
  });

  describe('list_dir tool', () => {
    let tool: typeof fileTools[0];

    beforeEach(() => {
      tool = fileTools.find(t => t.name === 'list_dir')!;
    });

    it('should have correct name', () => {
      expect(tool.name).toBe('list_dir');
    });

    it('should require root parameter', () => {
      expect(tool.inputSchema.required).toContain('root');
    });

    it('should have root property defined', () => {
      expect(tool.inputSchema.properties.root).toBeDefined();
      expect(tool.inputSchema.properties.root.type).toBe('string');
    });

    it('should have description', () => {
      expect(tool.description).toBeTruthy();
      expect(tool.description).toContain('List files and folders');
    });
  });

  describe('read_file tool', () => {
    let tool: typeof fileTools[0];

    beforeEach(() => {
      tool = fileTools.find(t => t.name === 'read_file')!;
    });

    it('should have correct name', () => {
      expect(tool.name).toBe('read_file');
    });

    it('should require path parameter', () => {
      expect(tool.inputSchema.required).toContain('path');
    });

    it('should have optional line range parameters', () => {
      expect(tool.inputSchema.properties.start_line).toBeDefined();
      expect(tool.inputSchema.properties.end_line).toBeDefined();
      expect(tool.inputSchema.required).not.toContain('start_line');
      expect(tool.inputSchema.required).not.toContain('end_line');
    });

    it('should have path property with correct description', () => {
      expect(tool.inputSchema.properties.path.description).toContain('res://');
    });
  });

  describe('search_project tool', () => {
    let tool: typeof fileTools[0];

    beforeEach(() => {
      tool = fileTools.find(t => t.name === 'search_project')!;
    });

    it('should have correct name', () => {
      expect(tool.name).toBe('search_project');
    });

    it('should require query parameter', () => {
      expect(tool.inputSchema.required).toContain('query');
    });

    it('should have optional glob parameter', () => {
      expect(tool.inputSchema.properties.glob).toBeDefined();
      expect(tool.inputSchema.required).not.toContain('glob');
    });

    it('should have description mentioning search functionality', () => {
      expect(tool.description.toLowerCase()).toContain('search');
    });
  });

  describe('create_script tool', () => {
    let tool: typeof fileTools[0];

    beforeEach(() => {
      tool = fileTools.find(t => t.name === 'create_script')!;
    });

    it('should have correct name', () => {
      expect(tool.name).toBe('create_script');
    });

    it('should require both path and content', () => {
      expect(tool.inputSchema.required).toContain('path');
      expect(tool.inputSchema.required).toContain('content');
    });

    it('should have content property for script content', () => {
      expect(tool.inputSchema.properties.content.type).toBe('string');
    });

    it('should mention GDScript in description', () => {
      expect(tool.description).toContain('GDScript');
    });
  });
});
