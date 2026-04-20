/**
 * Tool registry - exports all tool definitions
 */

import { fileTools } from './file-tools.js';
import { sceneTools } from './scene-tools.js';
import { editorViewTools } from './editor-view-tools.js';
import { layoutTools } from './layout-tools.js';
import { lightingTools } from './lighting-tools.js';
import { navigationTools } from './navigation-tools.js';
import { signalTools } from './signal-tools.js';
import { scriptTools } from './script-tools.js';
import { projectTools } from './project-tools.js';
import { assetTools } from './asset-tools.js';
import { visualizerTools } from './visualizer-tools.js';
import type { ToolDefinition } from '../types.js';

export const allTools: ToolDefinition[] = [
  ...fileTools,
  ...sceneTools,
  ...editorViewTools,
  ...layoutTools,
  ...lightingTools,
  ...navigationTools,
  ...signalTools,
  ...scriptTools,
  ...projectTools,
  ...assetTools,
  ...visualizerTools,
];

export function toolExists(toolName: string): boolean {
  return allTools.some(t => t.name === toolName);
}
