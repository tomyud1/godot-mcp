/**
 * Tool registry - exports all tool definitions
 */

import { fileTools } from './file-tools.js';
import { sceneTools } from './scene-tools.js';
import { scriptTools } from './script-tools.js';
import { projectTools } from './project-tools.js';
import { assetTools } from './asset-tools.js';
import { visualizerTools } from './visualizer-tools.js';
import { undoTools } from './undo-tools.js';
import { batchTools } from './batch-tools.js';
import { serverTools } from './server-tools.js';
import type { ToolDefinition } from '../types.js';

/** Every tool the Godot plugin executes, including deprecated aliases. */
export const allTools: ToolDefinition[] = [
  ...fileTools,
  ...sceneTools,
  ...scriptTools,
  ...projectTools,
  ...assetTools,
  ...visualizerTools,
  ...undoTools,
  ...batchTools,
];

export { serverTools };

/** What tools/list shows: server tools plus non-deprecated plugin tools. */
export const advertisedTools: ToolDefinition[] = [
  ...serverTools,
  ...allTools.filter((t) => !t.deprecated),
];

const byName = new Map<string, ToolDefinition>(
  [...serverTools, ...allTools].map((t) => [t.name, t]),
);

/** Look up any callable tool, including deprecated aliases. */
export function findTool(toolName: string): ToolDefinition | undefined {
  return byName.get(toolName);
}

export function toolExists(toolName: string): boolean {
  return byName.has(toolName);
}

/** Total callable tools; used to detect a stale primary server. */
export const callableToolCount = byName.size;
