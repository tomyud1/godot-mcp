/**
 * Tool registry - exports all tool definitions
 */

import { fileTools } from './file-tools.js';
import { sceneTools } from './scene-tools.js';
import { editorSceneTools } from './editor-scene-tools.js';
import { editorViewTools } from './editor-view-tools.js';
import { layoutTools } from './layout-tools.js';
import { lightingTools } from './lighting-tools.js';
import { navigationTools } from './navigation-tools.js';
import { signalTools } from './signal-tools.js';
import { scriptTools } from './script-tools.js';
import { projectTools } from './project-tools.js';
import { assetTools } from './asset-tools.js';
import { visualizerTools } from './visualizer-tools.js';
import { runtimeTools } from './runtime-tools.js';
import type { ToolDefinition } from '../types.js';

export const allTools: ToolDefinition[] = [
  ...fileTools,
  ...sceneTools,
  ...editorSceneTools,
  ...editorViewTools,
  ...layoutTools,
  ...lightingTools,
  ...navigationTools,
  ...signalTools,
  ...scriptTools,
  ...projectTools,
  ...assetTools,
  ...visualizerTools,
  ...runtimeTools,
];

export function toolExists(toolName: string): boolean {
  return allTools.some(t => t.name === toolName);
}

/**
 * The tools advertised via `tools/list`.
 *
 * Hidden tools stay dispatchable (so nothing that used them breaks) but are
 * omitted here, which is where the model's context cost actually comes from.
 */
export const advertisedTools: ToolDefinition[] = allTools.filter(t => !t.hidden);
