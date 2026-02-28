/**
 * Canvas rendering, camera controls, and drawing utilities
 */

import {
  nodes, edges, NODE_W, NODE_H, camera, defaultZoom,
  W, H, setDimensions, searchTerm, hoveredNode, selectedNode,
  currentView, sceneData, expandedScene, expandedSceneHierarchy,
  selectedSceneNode, hoveredSceneNode, scenePositions,
  setExpandedScene, setSelectedSceneNode, setHoveredSceneNode,
  setScenePosition, scriptToScenes
} from './state.js';

let canvas, ctx;
let zoomIndicator, zoomText;
let dpr = 1; // Device pixel ratio

// Storage key for position persistence
const STORAGE_KEY = 'godot-visualizer-positions';

export function initCanvas() {
  canvas = document.getElementById('canvas');
  ctx = canvas.getContext('2d');
  zoomIndicator = document.getElementById('zoom-indicator');
  zoomText = document.getElementById('zoom-text');

  // Get device pixel ratio for crisp rendering on high-DPI displays
  dpr = window.devicePixelRatio || 1;

  resize();
  const positionsRestored = loadPositions(); // Restore saved positions
  return { canvas, ctx, positionsRestored };
}

export function getDpr() {
  return dpr;
}

export function getCanvas() {
  return canvas;
}

export function getContext() {
  return ctx;
}

export function resize() {
  const w = window.innerWidth;
  const h = window.innerHeight;
  setDimensions(w, h);

  // Update DPR in case it changed (e.g., moving window between displays)
  dpr = window.devicePixelRatio || 1;

  // Set canvas size accounting for device pixel ratio for crisp rendering
  canvas.width = w * dpr;
  canvas.height = h * dpr;

  // Scale canvas back to CSS size
  canvas.style.width = w + 'px';
  canvas.style.height = h + 'px';

  // Scale context to account for DPR
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
}

export function screenToWorld(sx, sy) {
  return {
    x: (sx - W / 2) / camera.zoom + camera.x,
    y: (sy - H / 2) / camera.zoom + camera.y
  };
}

export function updateZoomIndicator() {
  const pct = Math.round(camera.zoom * 100);
  zoomText.value = pct + '%';
  zoomIndicator.classList.toggle('faded', Math.abs(camera.zoom - defaultZoom) < 0.01);
}

export function resetZoom() {
  camera.zoom = defaultZoom;
  updateZoomIndicator();
  draw();
}

export function setCustomZoom(value) {
  // Parse percentage string like "150%" or just "150" or "1.5"
  let parsed = parseFloat(value.replace('%', '').trim());
  if (isNaN(parsed)) return;
  
  // If user entered a small number like 1.5, treat as multiplier
  if (parsed > 0 && parsed < 10) {
    parsed = parsed * 100;
  }
  
  // Clamp to valid range (10% - 500%)
  const newZoom = Math.max(0.1, Math.min(5, parsed / 100));
  camera.zoom = newZoom;
  updateZoomIndicator();
  draw();
}

// Make functions available globally for onclick
window.resetZoom = resetZoom;
window.setCustomZoom = setCustomZoom;

// ---- Position Persistence ----
export function savePositions() {
  try {
    const positions = {};
    nodes.forEach(n => {
      positions[n.path] = { x: n.x, y: n.y };
    });
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      positions,
      camera: { x: camera.x, y: camera.y, zoom: camera.zoom }
    }));
  } catch (e) {
    console.warn('Failed to save positions:', e);
  }
}

export function loadPositions() {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (!saved) return false;

    const data = JSON.parse(saved);
    let restored = 0;

    if (data.positions) {
      nodes.forEach(n => {
        if (data.positions[n.path]) {
          n.x = data.positions[n.path].x;
          n.y = data.positions[n.path].y;
          restored++;
        }
      });
    }

    if (data.camera && restored > 0) {
      camera.x = data.camera.x;
      camera.y = data.camera.y;
      camera.zoom = data.camera.zoom;
      // Don't change defaultZoom - keep it at 1 (100%) so reset always goes to 100%
    }

    return restored > 0;
  } catch (e) {
    console.warn('Failed to load positions:', e);
    return false;
  }
}

export function clearPositions() {
  try {
    localStorage.removeItem(STORAGE_KEY);
  } catch (e) {
    console.warn('Failed to clear positions:', e);
  }
}

// Save positions when node is moved
export function onNodeMoved() {
  savePositions();
}

// ---- Drawing ----
export function draw() {
  if (currentView === 'scenes') {
    drawSceneView();
    return;
  }

  // Ensure DPR transform is set for crisp rendering on high-DPI displays
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  
  // Disable image smoothing for crisper shapes and lines
  ctx.imageSmoothingEnabled = false;
  
  // Use crisp line rendering
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  
  ctx.clearRect(0, 0, W, H);
  ctx.save();
  ctx.translate(Math.round(W / 2), Math.round(H / 2));
  ctx.scale(camera.zoom, camera.zoom);
  ctx.translate(-camera.x, -camera.y);

  // Build path index for quick lookup
  const pathIdx = {};
  nodes.forEach((n, i) => pathIdx[n.path] = i);

  // Group edges by node pair, type, and direction for bundled drawing
  const edgeGroups = {};
  for (const e of edges) {
    const si = pathIdx[e.from], ti = pathIdx[e.to];
    if (si === undefined || ti === undefined) continue;

    // Keep direction (A->B is different from B->A)
    const key = `${si}-${ti}-${e.type}`;
    if (!edgeGroups[key]) {
      edgeGroups[key] = { from: e.from, to: e.to, type: e.type, edges: [], si, ti };
    }
    edgeGroups[key].edges.push(e);
  }

  // Draw bundled edges
  for (const key of Object.keys(edgeGroups)) {
    const group = edgeGroups[key];
    const s = nodes[group.si], t = nodes[group.ti];
    const count = group.edges.length;

    // Skip edges where both nodes are hidden during search
    if (searchTerm && s.visible === false && t.visible === false) continue;

    // Dim edges when one node is hidden, or when neither is highlighted
    const bothVisible = s.visible !== false && t.visible !== false;
    ctx.globalAlpha = (!bothVisible || (!s.highlighted && !t.highlighted)) ? 0.08 : 0.5;

    // Calculate perpendicular offset for multiple edge types between same nodes
    const angle = Math.atan2(t.y - s.y, t.x - s.x);
    const perpAngle = angle + Math.PI / 2;

    // Get offset based on edge type (so different types don't overlap)
    const typeOffset = group.type === 'extends' ? 0 : group.type === 'preload' ? 8 : 16;
    const offsetX = Math.cos(perpAngle) * typeOffset;
    const offsetY = Math.sin(perpAngle) * typeOffset;

    ctx.beginPath();
    ctx.moveTo(s.x + offsetX, s.y + offsetY);
    ctx.lineTo(t.x + offsetX, t.y + offsetY);

    // Line widths scale with zoom (fixed world-space size)
    if (group.type === 'extends') {
      ctx.strokeStyle = '#7aa2f7';
      ctx.setLineDash([]);
      ctx.lineWidth = 2;
    } else if (group.type === 'preload') {
      ctx.strokeStyle = '#d4a27f';
      ctx.setLineDash([]);
      ctx.lineWidth = 1.5;
    } else {
      ctx.strokeStyle = '#a6e3a1';
      ctx.setLineDash([4, 4]);
      ctx.lineWidth = 1.5;
    }
    ctx.stroke();
    ctx.setLineDash([]);

    // Arrow at midpoint - fixed world-space size
    const al = 10;
    const mx = (s.x + t.x) / 2 + offsetX, my = (s.y + t.y) / 2 + offsetY;
    ctx.beginPath();
    ctx.moveTo(mx + Math.cos(angle) * al, my + Math.sin(angle) * al);
    ctx.lineTo(mx + Math.cos(angle + 2.5) * al * 0.6, my + Math.sin(angle + 2.5) * al * 0.6);
    ctx.lineTo(mx + Math.cos(angle - 2.5) * al * 0.6, my + Math.sin(angle - 2.5) * al * 0.6);
    ctx.closePath();
    ctx.fillStyle = ctx.strokeStyle;
    ctx.fill();

    // Draw count badge if multiple connections of same type
    if (count > 1) {
      const badgeX = mx + Math.cos(perpAngle) * 12;
      const badgeY = my + Math.sin(perpAngle) * 12;
      const badgeSize = 16;

      ctx.globalAlpha = bothVisible ? 0.9 : 0.3;
      ctx.beginPath();
      ctx.arc(badgeX, badgeY, badgeSize / 2, 0, Math.PI * 2);
      ctx.fillStyle = ctx.strokeStyle;
      ctx.fill();

      // Count text - scales with zoom
      ctx.fillStyle = '#1a1a1e';
      ctx.font = `bold 10px -apple-system, system-ui, sans-serif`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(count.toString(), badgeX, badgeY);
    }
  }

  ctx.globalAlpha = 1;

  // Draw nodes
  for (const n of nodes) {
    // Skip hidden nodes during search
    if (searchTerm && n.visible === false) continue;

    // Round coordinates for crisper rendering
    const x = Math.round(n.x - NODE_W / 2);
    const y = Math.round(n.y - NODE_H / 2);
    const isHovered = n === hoveredNode, isSelected = n === selectedNode;

    ctx.globalAlpha = n.highlighted ? 1 : 0.12;

    // Shadow - fixed world-space size
    ctx.shadowColor = 'rgba(0,0,0,0.4)';
    ctx.shadowBlur = isHovered ? 16 : 8;
    ctx.shadowOffsetY = 2;

    // Background
    ctx.beginPath();
    roundRect(ctx, x, y, NODE_W, NODE_H, 10);
    ctx.fillStyle = isSelected ? '#35353b' : isHovered ? '#303036' : '#242428';
    ctx.fill();

    ctx.shadowBlur = 0;
    ctx.shadowOffsetY = 0;

    // Border - fixed world-space width
    ctx.strokeStyle = isSelected ? n.color : isHovered ? n.color : '#3a3a40';
    ctx.lineWidth = isSelected ? 2 : 1;
    ctx.stroke();

    // Left accent bar
    ctx.beginPath();
    ctx.roundRect(x + 4, y + 8, 3, NODE_H - 16, 2);
    ctx.fillStyle = n.color;
    ctx.fill();

    // Title - scales with node (no zoom compensation)
    const titleSize = 14;
    ctx.font = `600 ${titleSize}px -apple-system, system-ui, sans-serif`;
    ctx.fillStyle = '#e8e4df';
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    const displayName = n.class_name || n.filename.replace('.gd', '');
    ctx.fillText(displayName, x + 16, y + NODE_H / 2 - 6);

    // Subtitle with colored stats - scales with node
    const subSize = 11;
    const varCount = n.variables ? n.variables.length : 0;
    const funcCount = n.functions ? n.functions.length : 0;
    const sigCount = n.signals ? n.signals.length : 0;

    // Draw subtitle parts with colors
    ctx.font = `${subSize}px -apple-system, system-ui, sans-serif`;
    const subY = y + NODE_H / 2 + 9;
    let subX = x + 16;

    // Extends
    ctx.fillStyle = '#706c66';
    const extendsText = (n.extends || 'Node') + ' · ';
    ctx.fillText(extendsText, subX, subY);
    subX += ctx.measureText(extendsText).width;

    // Functions (cyan/teal)
    ctx.fillStyle = '#89dceb';
    ctx.fillText(funcCount + 'f', subX, subY);
    subX += ctx.measureText(funcCount + 'f').width;

    // Space
    ctx.fillStyle = '#706c66';
    ctx.fillText(' ', subX, subY);
    subX += ctx.measureText(' ').width;

    // Variables (purple)
    ctx.fillStyle = '#cba6f7';
    ctx.fillText(varCount + 'v', subX, subY);
    subX += ctx.measureText(varCount + 'v').width;

    // Space
    ctx.fillStyle = '#706c66';
    ctx.fillText(' ', subX, subY);
    subX += ctx.measureText(' ').width;

    // Signals (green)
    ctx.fillStyle = '#a6e3a1';
    ctx.fillText(sigCount + 's', subX, subY);
    subX += ctx.measureText(sigCount + 's').width;

    // Separator
    ctx.fillStyle = '#706c66';
    ctx.fillText(' · ', subX, subY);
    subX += ctx.measureText(' · ').width;

    // Lines (yellow/amber)
    ctx.fillStyle = '#f9e2af';
    ctx.fillText(n.line_count + 'L', subX, subY);
    
    // Scene usage badge (top-right corner)
    const usedInScenes = scriptToScenes[n.path];
    if (usedInScenes && usedInScenes.length > 0) {
      const badgeX = x + NODE_W - 8;
      const badgeY = y + 8;
      
      ctx.fillStyle = 'rgba(166, 227, 161, 0.2)';
      ctx.beginPath();
      ctx.roundRect(badgeX - 20, badgeY - 4, 24, 14, 3);
      ctx.fill();
      
      ctx.fillStyle = '#a6e3a1';
      ctx.font = `600 9px -apple-system, system-ui, sans-serif`;
      ctx.textAlign = 'right';
      ctx.fillText('📦' + usedInScenes.length, badgeX, badgeY + 4);
      ctx.textAlign = 'left';
    }
  }

  ctx.globalAlpha = 1;
  ctx.restore();
}

// Scene view constants
const SCENE_CARD_W = 200;  // Match NODE_W
const SCENE_CARD_H = 54;   // Match NODE_H
const SCENE_NODE_MIN_W = 80;   // Minimum node width
const SCENE_NODE_MAX_W = 200;  // Maximum node width
const SCENE_NODE_H = 36;
const SCENE_NODE_GAP_X = 15;  // Reduced for tighter layout
const SCENE_NODE_GAP_Y = 40;

// Calculate dynamic node width based on name
function calculateNodeWidth(name) {
  // Approximate width: ~7px per character + padding
  const textWidth = (name || 'Node').length * 7;
  const padding = 35; // For script icon and margins
  return Math.min(SCENE_NODE_MAX_W, Math.max(SCENE_NODE_MIN_W, textWidth + padding));
}

function drawSceneView() {
  // Ensure DPR transform is set for crisp rendering on high-DPI displays
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  
  // Disable image smoothing for crisper shapes and lines
  ctx.imageSmoothingEnabled = false;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  
  ctx.clearRect(0, 0, W, H);
  ctx.save();
  ctx.translate(Math.round(W / 2), Math.round(H / 2));
  ctx.scale(camera.zoom, camera.zoom);
  ctx.translate(-camera.x, -camera.y);

  if (!sceneData || !sceneData.scenes || sceneData.scenes.length === 0) {
    drawSceneViewPlaceholder();
    ctx.restore();
    return;
  }

  // Check if we're in expanded mode
  if (expandedScene && expandedSceneHierarchy) {
    drawExpandedSceneView();
  } else {
    drawSceneOverview();
  }

  ctx.restore();
}

function drawSceneOverview() {
  const scenes = sceneData.scenes;
  
  // Calculate positions if not set
  scenes.forEach((scene, i) => {
    if (!scenePositions[scene.path]) {
      const cols = Math.max(1, Math.floor(Math.sqrt(scenes.length * 1.5)));
      setScenePosition(
        scene.path,
        (i % cols) * (SCENE_CARD_W + 40) - ((cols - 1) * (SCENE_CARD_W + 40)) / 2,
        Math.floor(i / cols) * (SCENE_CARD_H + 30) - 100
      );
    }
  });

  // Draw edges between scenes (instance relationships)
  if (sceneData.edges) {
    ctx.globalAlpha = 0.4;
    for (const edge of sceneData.edges) {
      const fromScene = scenes.find(s => s.path === edge.from);
      const toScene = scenes.find(s => s.path === edge.to);
      if (!fromScene || !toScene) continue;

      const fromPos = scenePositions[edge.from];
      const toPos = scenePositions[edge.to];
      if (!fromPos || !toPos) continue;

      const fromX = fromPos.x + SCENE_CARD_W / 2;
      const fromY = fromPos.y + SCENE_CARD_H;
      const toX = toPos.x + SCENE_CARD_W / 2;
      const toY = toPos.y;

      ctx.beginPath();
      ctx.moveTo(fromX, fromY);
      ctx.lineTo(toX, toY);
      ctx.strokeStyle = '#89dceb';
      ctx.lineWidth = 1.5;
      ctx.setLineDash([4, 4]);
      ctx.stroke();
      ctx.setLineDash([]);
    }
    ctx.globalAlpha = 1;
  }

  // Draw scene cards
  scenes.forEach((scene, i) => {
    const pos = scenePositions[scene.path];
    const x = pos.x;
    const y = pos.y;
    
    const isHovered = hoveredSceneNode && hoveredSceneNode.scenePath === scene.path && !hoveredSceneNode.nodePath;
    const isExpanded = expandedScene === scene.path;
    const sceneColor = getSceneColor(scene.path);

    // Shadow - match script node styling
    ctx.shadowColor = 'rgba(0,0,0,0.4)';
    ctx.shadowBlur = isHovered ? 16 : 8;
    ctx.shadowOffsetY = 2;

    // Scene card background - match script node colors
    ctx.beginPath();
    roundRect(ctx, x, y, SCENE_CARD_W, SCENE_CARD_H, 10);
    ctx.fillStyle = isExpanded ? '#35353b' : isHovered ? '#303036' : '#242428';
    ctx.fill();

    ctx.shadowBlur = 0;
    ctx.shadowOffsetY = 0;

    // Border - match script node styling
    ctx.strokeStyle = isExpanded ? sceneColor : isHovered ? sceneColor : '#3a3a40';
    ctx.lineWidth = isExpanded ? 2 : 1;
    ctx.stroke();

    // Left accent bar (scene color)
    ctx.beginPath();
    ctx.roundRect(x + 4, y + 8, 3, SCENE_CARD_H - 16, 2);
    ctx.fillStyle = sceneColor;
    ctx.fill();

    // Scene name (main label)
    ctx.fillStyle = '#e8e4df';
    ctx.font = `600 13px -apple-system, system-ui, sans-serif`;
    ctx.textAlign = 'left';
    const sceneName = scene.name || scene.path.split('/').pop().replace('.tscn', '');
    ctx.fillText(sceneName, x + 14, y + 22);

    // Root type and stats on second line
    const nodeCount = scene.node_count || (scene.nodes ? scene.nodes.length : 0);
    ctx.fillStyle = '#706c66';
    ctx.font = `11px -apple-system, system-ui, sans-serif`;
    ctx.fillText(`${scene.root_type || 'Node'} · ${nodeCount} nodes`, x + 14, y + 40);
  });
}

function drawExpandedSceneView() {
  const hierarchy = expandedSceneHierarchy;
  if (!hierarchy) return;

  // Draw back button area (handled by HTML overlay)
  
  // Draw the node tree
  const treeLayout = calculateTreeLayout(hierarchy);
  
  // Draw connection lines first
  drawTreeConnections(treeLayout.nodes);
  
  // Draw nodes
  for (const node of treeLayout.nodes) {
    drawSceneNode(node);
  }
}

function calculateTreeLayout(hierarchy) {
  const nodes = [];
  const LEVEL_HEIGHT = SCENE_NODE_H + SCENE_NODE_GAP_Y;
  
  // Simple layout: each node positions its children directly below,
  // centered on itself, without considering grandchildren widths
  function processNode(node, depth, centerX) {
    const nodeWidth = calculateNodeWidth(node.name);
    const x = centerX - nodeWidth / 2;
    const y = depth * LEVEL_HEIGHT;
    
    const nodeLayout = {
      ...node,
      x,
      y,
      width: nodeWidth,
      height: SCENE_NODE_H,
      childPositions: []
    };
    nodes.push(nodeLayout);

    // Layout children centered under this node
    if (node.children && node.children.length > 0) {
      // Calculate total width of direct children only
      let totalChildrenWidth = 0;
      for (const child of node.children) {
        totalChildrenWidth += calculateNodeWidth(child.name) + SCENE_NODE_GAP_X;
      }
      totalChildrenWidth -= SCENE_NODE_GAP_X; // Remove last gap
      
      // Start children centered under parent
      let childX = centerX - totalChildrenWidth / 2;
      
      for (const child of node.children) {
        const childWidth = calculateNodeWidth(child.name);
        const childCenterX = childX + childWidth / 2;
        
        nodeLayout.childPositions.push({
          x: childCenterX,
          y: (depth + 1) * LEVEL_HEIGHT
        });
        
        processNode(child, depth + 1, childCenterX);
        childX += childWidth + SCENE_NODE_GAP_X;
      }
    }

    return nodeLayout;
  }

  processNode(hierarchy, 0, 0);

  return { nodes };
}

function drawTreeConnections(nodes) {
  ctx.strokeStyle = '#4a5568';
  ctx.lineWidth = 1.5;
  ctx.setLineDash([]);

  for (const node of nodes) {
    if (node.childPositions && node.childPositions.length > 0) {
      const parentX = node.x + node.width / 2;
      const parentY = node.y + SCENE_NODE_H;

      for (const childPos of node.childPositions) {
        ctx.beginPath();
        ctx.moveTo(parentX, parentY);
        
        // Draw an elbow connector
        const midY = parentY + (childPos.y - parentY) / 2;
        ctx.lineTo(parentX, midY);
        ctx.lineTo(childPos.x, midY);
        ctx.lineTo(childPos.x, childPos.y);
        
        ctx.stroke();
      }
    }
  }
}

function drawSceneNode(node) {
  const x = node.x;
  const y = node.y;
  const w = node.width;
  const isSelected = selectedSceneNode && selectedSceneNode.path === node.path;
  const isHovered = hoveredSceneNode && hoveredSceneNode.nodePath === node.path;
  const isHighlighted = node.highlighted !== false; // Default to true if not set

  // Node type color
  const nodeColor = getNodeTypeColor(node.type);
  
  // Dim non-highlighted nodes when searching
  ctx.globalAlpha = isHighlighted ? 1 : 0.25;

  // Shadow
  ctx.shadowColor = 'rgba(0,0,0,0.25)';
  ctx.shadowBlur = isHovered ? 12 : 6;
  ctx.shadowOffsetY = 2;

  // Background - highlight matching nodes with a glow
  ctx.beginPath();
  roundRect(ctx, x, y, w, SCENE_NODE_H, 6);
  ctx.fillStyle = isSelected ? '#35353b' : isHovered ? '#303036' : '#242428';
  ctx.fill();

  ctx.shadowBlur = 0;
  ctx.shadowOffsetY = 0;

  // Border - use accent color for highlighted search results
  const borderColor = isSelected ? nodeColor : isHovered ? nodeColor : 
                      (isHighlighted && searchTerm ? '#f9e2af' : '#3a3a40');
  ctx.strokeStyle = borderColor;
  ctx.lineWidth = (isSelected || (isHighlighted && searchTerm)) ? 2 : 1;
  ctx.stroke();

  // Left accent
  ctx.beginPath();
  ctx.roundRect(x + 3, y + 6, 2, SCENE_NODE_H - 12, 1);
  ctx.fillStyle = nodeColor;
  ctx.fill();

  // Node name
  ctx.fillStyle = '#e8e4df';
  ctx.font = `600 11px -apple-system, system-ui, sans-serif`;
  ctx.textAlign = 'left';
  ctx.textBaseline = 'middle';
  
  const displayName = node.name || 'Node';
  ctx.fillText(displayName, x + 10, y + SCENE_NODE_H / 2 - 4);

  // Node type (smaller, below name)
  ctx.fillStyle = '#706c66';
  ctx.font = `9px -apple-system, system-ui, sans-serif`;
  ctx.fillText(node.type, x + 10, y + SCENE_NODE_H / 2 + 7);

  // Script indicator
  if (node.script) {
    ctx.fillStyle = '#a6e3a1';
    ctx.font = `10px -apple-system, system-ui, sans-serif`;
    ctx.textAlign = 'right';
    ctx.fillText('📜', x + w - 6, y + SCENE_NODE_H / 2);
    ctx.textAlign = 'left';
  }

  // Sibling index indicator (for node order)
  if (node.index !== undefined && node.index > 0) {
    ctx.fillStyle = '#4a5568';
    ctx.font = `9px -apple-system, system-ui, sans-serif`;
    ctx.textAlign = 'right';
    ctx.fillText(`#${node.index}`, x + w - 6, y + 10);
    ctx.textAlign = 'left';
  }
  
  // Reset alpha
  ctx.globalAlpha = 1;
}

function getSceneColor(scenePath) {
  // Generate consistent color based on path
  const colors = ['#89dceb', '#a6e3a1', '#f9e2af', '#cba6f7', '#f38ba8', '#fab387'];
  let hash = 0;
  for (let i = 0; i < scenePath.length; i++) {
    hash = scenePath.charCodeAt(i) + ((hash << 5) - hash);
  }
  return colors[Math.abs(hash) % colors.length];
}

function getNodeTypeColor(nodeType) {
  // Godot's actual node type colors
  const GODOT_GREEN = '#8eef97';   // Control/UI nodes
  const GODOT_BLUE = '#8da5f3';    // Node2D nodes
  const GODOT_RED = '#fc7f7f';     // Node3D nodes
  const GODOT_GRAY = '#b2b2b2';    // Base Node
  
  // Control/UI nodes (green)
  const controlTypes = [
    'Control', 'Label', 'Button', 'LineEdit', 'TextEdit', 'RichTextLabel',
    'Panel', 'PanelContainer', 'Container', 'BoxContainer', 'VBoxContainer', 
    'HBoxContainer', 'GridContainer', 'MarginContainer', 'ScrollContainer',
    'TabContainer', 'ProgressBar', 'TextureRect', 'ColorRect', 'NinePatchRect',
    'CheckBox', 'CheckButton', 'OptionButton', 'SpinBox', 'Slider', 'HSlider',
    'VSlider', 'Tree', 'ItemList', 'MenuButton', 'LinkButton', 'CanvasLayer'
  ];
  
  // Node2D nodes (blue)
  const node2DTypes = [
    'Node2D', 'Sprite2D', 'AnimatedSprite2D', 'CharacterBody2D', 'RigidBody2D',
    'StaticBody2D', 'Area2D', 'CollisionShape2D', 'CollisionPolygon2D',
    'Camera2D', 'Path2D', 'PathFollow2D', 'Line2D', 'Polygon2D', 'TileMap',
    'TileMapLayer', 'Marker2D', 'RemoteTransform2D', 'VisibleOnScreenNotifier2D',
    'GPUParticles2D', 'CPUParticles2D', 'LightOccluder2D', 'PointLight2D',
    'DirectionalLight2D', 'AudioStreamPlayer2D', 'NavigationRegion2D'
  ];
  
  // Node3D nodes (red)
  const node3DTypes = [
    'Node3D', 'Sprite3D', 'AnimatedSprite3D', 'CharacterBody3D', 'RigidBody3D',
    'StaticBody3D', 'Area3D', 'CollisionShape3D', 'CollisionPolygon3D',
    'Camera3D', 'MeshInstance3D', 'MultiMeshInstance3D', 'CSGBox3D',
    'CSGCylinder3D', 'CSGSphere3D', 'CSGMesh3D', 'Path3D', 'PathFollow3D',
    'GPUParticles3D', 'CPUParticles3D', 'OmniLight3D', 'SpotLight3D',
    'DirectionalLight3D', 'AudioStreamPlayer3D', 'NavigationRegion3D'
  ];
  
  // Check exact matches first, then partial
  for (const type of controlTypes) {
    if (nodeType === type || nodeType.includes(type)) return GODOT_GREEN;
  }
  for (const type of node2DTypes) {
    if (nodeType === type || nodeType.includes(type)) return GODOT_BLUE;
  }
  for (const type of node3DTypes) {
    if (nodeType === type || nodeType.includes(type)) return GODOT_RED;
  }
  
  // Fallback: check for 2D/3D suffix
  if (nodeType.endsWith('2D')) return GODOT_BLUE;
  if (nodeType.endsWith('3D')) return GODOT_RED;
  
  return GODOT_GRAY; // Default gray for base Node
}

function drawSceneViewPlaceholder() {
  ctx.fillStyle = '#706c66';
  ctx.font = `16px -apple-system, system-ui, sans-serif`;
  ctx.textAlign = 'center';
  ctx.fillText('No scenes found', 0, 0);
  ctx.fillText('Create a .tscn file in your project', 0, 24);
  ctx.textAlign = 'left';
}

// Export scene hit testing
export function sceneHitTest(wx, wy) {
  if (!sceneData || !sceneData.scenes) return null;

  if (expandedScene && expandedSceneHierarchy) {
    // Hit test expanded scene nodes
    const treeLayout = calculateTreeLayout(expandedSceneHierarchy);
    for (let i = treeLayout.nodes.length - 1; i >= 0; i--) {
      const node = treeLayout.nodes[i];
      if (wx >= node.x && wx <= node.x + node.width &&
          wy >= node.y && wy <= node.y + SCENE_NODE_H) {
        return { type: 'sceneNode', node, scenePath: expandedScene };
      }
    }
    return null;
  } else {
    // Hit test scene cards
    for (const scene of sceneData.scenes) {
      const pos = scenePositions[scene.path];
      if (!pos) continue;
      
      if (wx >= pos.x && wx <= pos.x + SCENE_CARD_W &&
          wy >= pos.y && wy <= pos.y + SCENE_CARD_H) {
        return { type: 'sceneCard', scene, scenePath: scene.path };
      }
    }
    return null;
  }
}

export { SCENE_CARD_W, SCENE_CARD_H, SCENE_NODE_H };

export function roundRect(ctx, x, y, w, h, r) {
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
}

export function hitTest(wx, wy) {
  for (let i = nodes.length - 1; i >= 0; i--) {
    const n = nodes[i];
    // Skip hidden nodes during search
    if (searchTerm && n.visible === false) continue;
    if (wx >= n.x - NODE_W / 2 && wx <= n.x + NODE_W / 2 &&
        wy >= n.y - NODE_H / 2 && wy <= n.y + NODE_H / 2) return n;
  }
  return null;
}

export function centerOnNodes(nodeList) {
  if (!nodeList || nodeList.length === 0) return;

  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  nodeList.forEach(n => {
    minX = Math.min(minX, n.x);
    maxX = Math.max(maxX, n.x);
    minY = Math.min(minY, n.y);
    maxY = Math.max(maxY, n.y);
  });

  camera.x = (minX + maxX) / 2;
  camera.y = (minY + maxY) / 2;
  updateZoomIndicator();
}

export function fitToView(nodeList) {
  if (!nodeList || nodeList.length === 0) return;

  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  nodeList.forEach(n => {
    minX = Math.min(minX, n.x);
    maxX = Math.max(maxX, n.x);
    minY = Math.min(minY, n.y);
    maxY = Math.max(maxY, n.y);
  });

  camera.x = (minX + maxX) / 2;
  camera.y = (minY + maxY) / 2;

  const spanX = (maxX - minX) + NODE_W * 2;
  const spanY = (maxY - minY) + NODE_H * 2;
  // Calculate zoom to fit all nodes, but cap at 100% (1.0) to avoid zooming in too much
  camera.zoom = Math.min(1.0, W / spanX, H / spanY) * 0.9;
  // Don't change defaultZoom - keep it at 1 (100%) so reset always goes to 100%
  updateZoomIndicator();
}
