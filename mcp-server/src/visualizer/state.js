/**
 * Shared state and constants for the visualizer
 */

// Project data injected at build time
export const PROJECT_DATA = "%%PROJECT_DATA%%";

// Node dimensions
export const NODE_W = 200;
export const NODE_H = 54;

// Camera state
export const camera = { x: 0, y: 0, zoom: 1 };
export let defaultZoom = 1;

export function setDefaultZoom(value) {
  defaultZoom = value;
}

// Viewport dimensions
export let W = 0;
export let H = 0;

export function setDimensions(width, height) {
  W = width;
  H = height;
}

// Interaction state
export let dragging = null;
export let hoveredNode = null;
export let selectedNode = null;
export let searchTerm = '';

export function setDragging(value) {
  dragging = value;
}

export function setHoveredNode(value) {
  hoveredNode = value;
}

export function setSelectedNode(value) {
  selectedNode = value;
}

export function setSearchTerm(value) {
  searchTerm = value;
}

// Folder color mapping
const FOLDER_COLORS = [
  '#d4a27f', '#7aa2f7', '#a6e3a1', '#f38ba8', '#89dceb',
  '#fab387', '#cba6f7', '#f9e2af', '#94e2d5', '#eba0ac'
];

const folderColorMap = {};
let folderColorIdx = 0;

export function getFolderColor(folder) {
  if (!folder) return FOLDER_COLORS[0];
  if (!folderColorMap[folder]) {
    folderColorMap[folder] = FOLDER_COLORS[folderColorIdx % FOLDER_COLORS.length];
    folderColorIdx++;
  }
  return folderColorMap[folder];
}

// Initialize nodes from project data
export const nodes = PROJECT_DATA.nodes.map((n, i) => ({
  ...n,
  x: 0,
  y: 0,
  color: getFolderColor(n.folder),
  highlighted: true,
  visible: true
}));

export const edges = PROJECT_DATA.edges;

// View state
export let currentView = 'scripts';
export let sceneData = null;

export function setCurrentView(view) {
  currentView = view;
}

export function setSceneData(data) {
  sceneData = data;
}

// Delete operation state
export let pendingDelete = null;
export let currentUsages = [];

export function setPendingDelete(value) {
  pendingDelete = value;
}

export function setCurrentUsages(value) {
  currentUsages = value;
}

// Utility function
export function esc(s) {
  return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
