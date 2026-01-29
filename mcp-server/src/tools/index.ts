/**
 * Tool registry - exports all tool definitions and handlers
 */

import { fileTools, getMockFileToolResponse } from './file-tools.js';
import { sceneTools, getMockSceneToolResponse } from './scene-tools.js';
import { scriptTools, getMockScriptToolResponse } from './script-tools.js';
import { projectTools, getMockProjectToolResponse } from './project-tools.js';
import { assetTools, getMockAssetToolResponse } from './asset-tools.js';
import { visualizerTools, getMockVisualizerToolResponse } from './visualizer-tools.js';
import type { ToolDefinition } from '../types.js';

// Export all tool definitions
export const allTools: ToolDefinition[] = [
  ...fileTools,
  ...sceneTools,
  ...scriptTools,
  ...projectTools,
  ...assetTools,
  ...visualizerTools,
];

// Tool name sets for categorization and routing
export const fileToolNames = new Set(fileTools.map(t => t.name));
export const sceneToolNames = new Set(sceneTools.map(t => t.name));
export const scriptToolNames = new Set(scriptTools.map(t => t.name));
export const projectToolNames = new Set(projectTools.map(t => t.name));
export const assetToolNames = new Set(assetTools.map(t => t.name));
export const visualizerToolNames = new Set(visualizerTools.map(t => t.name));

/**
 * Get mock response for any tool (when Godot is not connected)
 */
export function getMockToolResponse(toolName: string, args: Record<string, unknown>): unknown {
  if (fileToolNames.has(toolName)) return getMockFileToolResponse(toolName, args);
  if (sceneToolNames.has(toolName)) return getMockSceneToolResponse(toolName, args);
  if (scriptToolNames.has(toolName)) return getMockScriptToolResponse(toolName, args);
  if (projectToolNames.has(toolName)) return getMockProjectToolResponse(toolName, args);
  if (assetToolNames.has(toolName)) return getMockAssetToolResponse(toolName, args);
  if (visualizerToolNames.has(toolName)) return getMockVisualizerToolResponse(toolName, args);

  return { error: `Unknown tool: ${toolName}`, available_tools: allTools.map(t => t.name) };
}

/**
 * Check if a tool exists
 */
export function toolExists(toolName: string): boolean {
  return allTools.some(t => t.name === toolName);
}
