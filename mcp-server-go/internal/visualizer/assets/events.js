/**
 * Event handlers for mouse, keyboard, and search
 */

import {
  nodes, edges, camera, W, H, defaultZoom,
  dragging, setDragging,
  hoveredNode, setHoveredNode,
  searchTerm, setSearchTerm,
  currentView, expandedScene, expandedSceneHierarchy, sceneData,
  setExpandedScene, setExpandedSceneHierarchy,
  setSelectedSceneNode, setHoveredSceneNode,
  selectedSceneNode, scenePositions, setScenePosition
} from './state.js';
import {
  getCanvas, screenToWorld, hitTest, draw, resize,
  updateZoomIndicator, centerOnNodes, savePositions,
  sceneHitTest, SCENE_CARD_W, SCENE_CARD_H
} from './canvas.js';
import { openPanel, closePanel, openSceneNodePanel, closeSceneNodePanel } from './panel.js';
import { sendCommand } from './websocket.js';

const DRAG_THRESHOLD = 5; // pixels - minimum movement to count as drag

export function initEvents() {
  const canvas = getCanvas();
  const searchInput = document.getElementById('search');
  const statsEl = document.getElementById('stats');

  // Mouse events
  canvas.addEventListener('mousedown', (e) => {
    const w = screenToWorld(e.clientX, e.clientY);
    
    if (currentView === 'scenes') {
      handleSceneMouseDown(e, w);
    } else {
      handleScriptsMouseDown(e, w);
    }
  });

  canvas.addEventListener('mousemove', (e) => {
    if (currentView === 'scenes') {
      handleSceneMouseMove(e);
    } else {
      handleScriptsMouseMove(e);
    }
  });

  canvas.addEventListener('mouseup', (e) => {
    if (currentView === 'scenes') {
      handleSceneMouseUp(e);
    } else {
      handleScriptsMouseUp(e);
    }
  });

  // Prevent click from also opening panel (mouseup already handles it)
  canvas.addEventListener('click', (e) => {
    // Only handle clicks on empty space (not nodes) - nodes are handled by mouseup
  });

  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    // Smaller zoom increments for finer control
    const zoomFactor = e.deltaY > 0 ? 0.95 : 1.05;
    const newZoom = Math.max(0.1, Math.min(5, camera.zoom * zoomFactor));
    const wx = (e.clientX - W / 2) / camera.zoom + camera.x;
    const wy = (e.clientY - H / 2) / camera.zoom + camera.y;
    camera.zoom = newZoom;
    camera.x = wx - (e.clientX - W / 2) / camera.zoom;
    camera.y = wy - (e.clientY - H / 2) / camera.zoom;
    updateZoomIndicator();
    draw();
  }, { passive: false });

  // Double-click to rename
  canvas.addEventListener('dblclick', (e) => {
    if (currentView === 'scenes' && expandedScene) {
      const w = screenToWorld(e.clientX, e.clientY);
      const hit = sceneHitTest(w.x, w.y);
      
      if (hit && hit.type === 'sceneNode') {
        e.preventDefault();
        startInlineRename(e.clientX, e.clientY, hit.node, hit.scenePath);
      }
    }
  });

  // Right-click context menu
  canvas.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    
    if (currentView === 'scenes' && expandedScene) {
      const w = screenToWorld(e.clientX, e.clientY);
      const hit = sceneHitTest(w.x, w.y);
      
      if (hit && hit.type === 'sceneNode') {
        showSceneContextMenu(e.clientX, e.clientY, hit.node, hit.scenePath);
        return;
      }
    }
    
    // Hide scene context menu if clicking elsewhere
    hideSceneContextMenu();
  });

  // Close context menus when clicking elsewhere
  document.addEventListener('click', (e) => {
    if (!e.target.closest('#scene-context-menu')) {
      hideSceneContextMenu();
    }
  });

  // Search
  searchInput.addEventListener('input', () => {
    const term = searchInput.value.toLowerCase().trim();
    setSearchTerm(term);

    if (currentView === 'scripts') {
      nodes.forEach(n => {
        if (!term) {
          n.highlighted = true;
          n.visible = true;
          return;
        }
        const matches = n.filename.toLowerCase().includes(term) ||
          (n.class_name && n.class_name.toLowerCase().includes(term)) ||
          (n.description && n.description.toLowerCase().includes(term)) ||
          (n.path && n.path.toLowerCase().includes(term));
        n.highlighted = matches;
        n.visible = matches;
      });

      const matchingNodes = nodes.filter(n => n.highlighted);
      const count = matchingNodes.length;
      statsEl.textContent = term
        ? `${count}/${nodes.length}`
        : `${nodes.length} scripts · ${edges.length} connections`;

      // If there are matching results, center the view on them
      if (term && matchingNodes.length > 0) {
        centerOnNodes(matchingNodes);

        // Adjust zoom if needed to fit all matching nodes
        if (matchingNodes.length === 1) {
          camera.zoom = Math.max(defaultZoom, 1);
        }
        updateZoomIndicator();
      }
    }
    // Scene search
    if (currentView === 'scenes') {
      if (expandedScene && expandedSceneHierarchy) {
        // Search within expanded scene - highlight matching nodes
        const matchingPaths = [];
        
        function searchNode(node) {
          const matches = !term || 
            node.name.toLowerCase().includes(term) ||
            (node.type && node.type.toLowerCase().includes(term));
          
          node.highlighted = matches;
          if (matches && term) matchingPaths.push(node.path);
          
          if (node.children) {
            for (const child of node.children) {
              searchNode(child);
            }
          }
        }
        
        searchNode(expandedSceneHierarchy);
        
        const totalNodes = countNodes(expandedSceneHierarchy);
        statsEl.textContent = term
          ? `${matchingPaths.length}/${totalNodes} nodes`
          : `${totalNodes} nodes`;
      } else if (sceneData && sceneData.scenes) {
        // Search in scene overview
        let matchCount = 0;
        for (const scene of sceneData.scenes) {
          const sceneName = scene.name || scene.path.split('/').pop().replace('.tscn', '');
          scene.highlighted = !term || 
            sceneName.toLowerCase().includes(term) ||
            (scene.root_type && scene.root_type.toLowerCase().includes(term));
          if (scene.highlighted) matchCount++;
        }
        
        statsEl.textContent = term
          ? `${matchCount}/${sceneData.scenes.length} scenes`
          : `${sceneData.scenes.length} scenes`;
      }
    }

    draw();
  });
  
  function countNodes(node) {
    let count = 1;
    if (node.children) {
      for (const child of node.children) {
        count += countNodes(child);
      }
    }
    return count;
  }

  // Keyboard shortcuts
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      // Also close context menus
      hideSceneContextMenu();
      
      if (currentView === 'scenes') {
        if (selectedSceneNode) {
          setSelectedSceneNode(null);
          closeSceneNodePanel();
          draw();
        } else if (expandedScene) {
          goBackToSceneOverview();
        }
      } else {
        closePanel();
      }
    }
    
    // Focus search with /
    if (e.key === '/' && document.activeElement !== searchInput) {
      e.preventDefault();
      searchInput.focus();
    }
    
    // Delete key to delete selected scene node
    if ((e.key === 'Delete' || e.key === 'Backspace') && currentView === 'scenes' && selectedSceneNode && !e.target.matches('input, textarea')) {
      e.preventDefault();
      sceneNodeAction('delete');
    }
    
    // Enter to open properties panel for selected node
    if (e.key === 'Enter' && currentView === 'scenes' && expandedScene && !e.target.matches('input, textarea')) {
      // If no node selected, select root
      // If node selected, this could toggle the panel (already handled by re-click)
    }
  });

  // Window resize
  window.addEventListener('resize', () => {
    resize();
    draw();
  });
}

// ---- Scripts view event handlers ----
function handleScriptsMouseDown(e, w) {
  const canvas = getCanvas();
  const hit = hitTest(w.x, w.y);

  if (hit && e.button === 0) {
    setDragging({
      type: 'node',
      node: hit,
      offX: hit.x - w.x,
      offY: hit.y - w.y,
      startScreenX: e.clientX,
      startScreenY: e.clientY,
      moved: false
    });
    canvas.classList.add('dragging');
  } else {
    setDragging({ type: 'pan', startX: e.clientX, startY: e.clientY, camX: camera.x, camY: camera.y });
    canvas.classList.add('dragging');
  }
}

function handleScriptsMouseMove(e) {
  const canvas = getCanvas();
  if (dragging) {
    if (dragging.type === 'node') {
      const w = screenToWorld(e.clientX, e.clientY);
      dragging.node.x = w.x + dragging.offX;
      dragging.node.y = w.y + dragging.offY;

      // Check if moved past threshold
      const dx = Math.abs(e.clientX - dragging.startScreenX);
      const dy = Math.abs(e.clientY - dragging.startScreenY);
      if (dx > DRAG_THRESHOLD || dy > DRAG_THRESHOLD) {
        dragging.moved = true;
      }
    } else {
      const dx = (e.clientX - dragging.startX) / camera.zoom;
      const dy = (e.clientY - dragging.startY) / camera.zoom;
      camera.x = dragging.camX - dx;
      camera.y = dragging.camY - dy;
    }
    draw();
  } else {
    const w = screenToWorld(e.clientX, e.clientY);
    const prev = hoveredNode;
    setHoveredNode(hitTest(w.x, w.y));
    if (hoveredNode !== prev) {
      canvas.style.cursor = hoveredNode ? 'pointer' : 'grab';
      draw();
    }
  }
}

function handleScriptsMouseUp(e) {
  const canvas = getCanvas();
  if (dragging && dragging.type === 'node') {
    if (dragging.moved) {
      // Node was moved - save positions
      savePositions();
    } else {
      // Node was clicked - open panel
      openPanel(dragging.node);
    }
  }
  canvas.classList.remove('dragging');
  setDragging(null);
}

// ---- Scene view event handlers ----
function handleSceneMouseDown(e, w) {
  const canvas = getCanvas();
  const hit = sceneHitTest(w.x, w.y);

  if (hit && e.button === 0) {
    if (hit.type === 'sceneCard') {
      // Scene card - prepare for possible drag or click
      const pos = scenePositions[hit.scenePath];
      setDragging({
        type: 'sceneCard',
        scene: hit.scene,
        scenePath: hit.scenePath,
        offX: pos.x - w.x,
        offY: pos.y - w.y,
        startScreenX: e.clientX,
        startScreenY: e.clientY,
        moved: false
      });
      canvas.classList.add('dragging');
    } else if (hit.type === 'sceneNode') {
      // Scene node in expanded view - click to select
      setDragging({
        type: 'sceneNode',
        node: hit.node,
        scenePath: hit.scenePath,
        startScreenX: e.clientX,
        startScreenY: e.clientY,
        moved: false
      });
    }
  } else {
    setDragging({ type: 'pan', startX: e.clientX, startY: e.clientY, camX: camera.x, camY: camera.y });
    canvas.classList.add('dragging');
  }
}

function handleSceneMouseMove(e) {
  const canvas = getCanvas();
  if (dragging) {
    if (dragging.type === 'sceneCard') {
      const w = screenToWorld(e.clientX, e.clientY);
      const newX = w.x + dragging.offX;
      const newY = w.y + dragging.offY;
      setScenePosition(dragging.scenePath, newX, newY);

      // Check if moved past threshold
      const dx = Math.abs(e.clientX - dragging.startScreenX);
      const dy = Math.abs(e.clientY - dragging.startScreenY);
      if (dx > DRAG_THRESHOLD || dy > DRAG_THRESHOLD) {
        dragging.moved = true;
      }
      draw();
    } else if (dragging.type === 'pan') {
      const dx = (e.clientX - dragging.startX) / camera.zoom;
      const dy = (e.clientY - dragging.startY) / camera.zoom;
      camera.x = dragging.camX - dx;
      camera.y = dragging.camY - dy;
      draw();
    }
  } else {
    const w = screenToWorld(e.clientX, e.clientY);
    const hit = sceneHitTest(w.x, w.y);
    
    if (hit) {
      if (hit.type === 'sceneCard') {
        setHoveredSceneNode({ scenePath: hit.scenePath, nodePath: null });
      } else if (hit.type === 'sceneNode') {
        setHoveredSceneNode({ scenePath: hit.scenePath, nodePath: hit.node.path });
      }
      canvas.style.cursor = 'pointer';
    } else {
      setHoveredSceneNode(null);
      canvas.style.cursor = 'grab';
    }
    draw();
  }
}

function handleSceneMouseUp(e) {
  const canvas = getCanvas();
  
  if (dragging) {
    if (dragging.type === 'sceneCard' && !dragging.moved) {
      // Scene card was clicked - expand the scene
      expandScene(dragging.scenePath);
    } else if (dragging.type === 'sceneNode' && !dragging.moved) {
      // Scene node was clicked - select it and open properties panel
      selectSceneNode(dragging.node, dragging.scenePath);
    }
  }
  
  canvas.classList.remove('dragging');
  setDragging(null);
}

// ---- Scene expansion and navigation ----
async function expandScene(scenePath) {
  console.log('Expanding scene:', scenePath);
  
  try {
    // Fetch the scene hierarchy
    const result = await sendCommand('get_scene_hierarchy', { scene_path: scenePath });
    
    if (result.ok) {
      setExpandedScene(scenePath);
      setExpandedSceneHierarchy(result.hierarchy);
      
      // Reset camera position but keep user's zoom level
      camera.x = 0;
      camera.y = 100;
      // Don't change zoom - keep user's preference
      
      // Update UI
      updateSceneBackButton(true, scenePath);
      draw();
    } else {
      console.error('Failed to get scene hierarchy:', result.error);
      alert('Failed to load scene: ' + (result.error || 'Unknown error'));
    }
  } catch (err) {
    console.error('Failed to expand scene:', err);
    alert('Failed to load scene: ' + err.message);
  }
}

async function selectSceneNode(node, scenePath) {
  console.log('Selected scene node:', node.name, 'in', scenePath);
  
  // If clicking the same node that's already selected, close the panel
  if (selectedSceneNode && selectedSceneNode.path === node.path) {
    setSelectedSceneNode(null);
    closeSceneNodePanel();
    draw();
    return;
  }
  
  setSelectedSceneNode(node);
  
  // Open the properties panel for this node
  await openSceneNodePanel(scenePath, node);
  draw();
}

export function goBackToSceneOverview() {
  setExpandedScene(null);
  setExpandedSceneHierarchy(null);
  setSelectedSceneNode(null);
  setHoveredSceneNode(null);
  closeSceneNodePanel();
  updateSceneBackButton(false);
  draw();
}

function updateSceneBackButton(show, scenePath = '') {
  const backBtn = document.getElementById('scene-back-btn');
  const legend = document.getElementById('legend');
  
  if (backBtn) {
    backBtn.style.display = show ? 'flex' : 'none';
    if (show) {
      const sceneName = scenePath.split('/').pop().replace('.tscn', '');
      backBtn.querySelector('.scene-name').textContent = sceneName;
    }
  }
  
  // Hide legend when in expanded scene view (it's not relevant there)
  if (legend) {
    legend.classList.toggle('hidden', show);
  }
}

// Expose for global access
window.goBackToSceneOverview = goBackToSceneOverview;
window.expandSceneFromPanel = expandScene;

export function updateStats() {
  const statsEl = document.getElementById('stats');
  if (currentView === 'scripts') {
    statsEl.textContent = `${nodes.length} scripts · ${edges.length} connections`;
  } else if (sceneData && sceneData.scenes) {
    statsEl.textContent = `${sceneData.scenes.length} scenes`;
  }
}

// ---- Scene Node Context Menu ----
let contextMenuNode = null;
let contextMenuScenePath = null;

function showSceneContextMenu(x, y, node, scenePath) {
  const menu = document.getElementById('scene-context-menu');
  contextMenuNode = node;
  contextMenuScenePath = scenePath;
  
  menu.style.left = x + 'px';
  menu.style.top = y + 'px';
  menu.classList.add('visible');
}

function hideSceneContextMenu() {
  const menu = document.getElementById('scene-context-menu');
  menu.classList.remove('visible');
  contextMenuNode = null;
  contextMenuScenePath = null;
}

async function sceneNodeAction(action) {
  // Save node info BEFORE hiding menu (which clears these variables)
  const node = contextMenuNode;
  const scenePath = contextMenuScenePath;
  
  hideSceneContextMenu();
  
  if (!node || !scenePath) return;
  
  try {
    switch (action) {
      case 'add_child': {
        const nodeType = prompt('Enter node type (e.g., Node2D, Sprite2D, Label):', 'Node2D');
        if (!nodeType) return;
        const nodeName = prompt('Enter node name:', 'NewNode');
        if (!nodeName) return;
        
        const result = await sendCommand('add_node', {
          scene_path: scenePath,
          parent_path: node.path,
          node_type: nodeType,
          node_name: nodeName
        });
        
        if (result.ok) {
          await refreshExpandedScene(scenePath);
        } else {
          alert('Failed to add node: ' + (result.error || 'Unknown error'));
        }
        break;
      }
      
      case 'rename': {
        const newName = prompt('Enter new name:', node.name);
        if (!newName || newName === node.name) return;
        
        const result = await sendCommand('rename_node', {
          scene_path: scenePath,
          node_path: node.path,
          new_name: newName
        });
        
        if (result.ok) {
          await refreshExpandedScene(scenePath);
        } else {
          alert('Failed to rename: ' + (result.error || 'Unknown error'));
        }
        break;
      }
      
      case 'duplicate': {
        const result = await sendCommand('duplicate_node', {
          scene_path: scenePath,
          node_path: node.path
        });
        
        if (result.ok) {
          await refreshExpandedScene(scenePath);
        } else {
          alert('Failed to duplicate: ' + (result.error || 'Unknown error'));
        }
        break;
      }
      
      case 'move_up': {
        if (node.index === undefined || node.index <= 0) {
          alert('Cannot move node up - already at top');
          return;
        }
        const result = await sendCommand('reorder_node', {
          scene_path: scenePath,
          node_path: node.path,
          new_index: node.index - 1
        });
        
        if (result.ok) {
          await refreshExpandedScene(scenePath);
        } else {
          alert('Failed to move: ' + (result.error || 'Unknown error'));
        }
        break;
      }
      
      case 'move_down': {
        const result = await sendCommand('reorder_node', {
          scene_path: scenePath,
          node_path: node.path,
          new_index: (node.index || 0) + 1
        });
        
        if (result.ok) {
          await refreshExpandedScene(scenePath);
        } else {
          alert('Failed to move: ' + (result.error || 'Unknown error'));
        }
        break;
      }
      
      case 'delete': {
        if (node.path === '.') {
          alert('Cannot delete root node');
          return;
        }
        if (!confirm(`Delete node "${node.name}" and all its children?`)) return;
        
        const result = await sendCommand('remove_node', {
          scene_path: scenePath,
          node_path: node.path
        });
        
        if (result.ok) {
          closeSceneNodePanel();
          setSelectedSceneNode(null);
          await refreshExpandedScene(scenePath);
        } else {
          alert('Failed to delete: ' + (result.error || 'Unknown error'));
        }
        break;
      }
    }
  } catch (err) {
    console.error('Scene action failed:', err);
    alert('Action failed: ' + err.message);
  }
}

async function refreshExpandedScene(scenePath) {
  // Re-fetch the scene hierarchy
  const result = await sendCommand('get_scene_hierarchy', { scene_path: scenePath });
  if (result.ok) {
    setExpandedSceneHierarchy(result.hierarchy);
    draw();
  }
}

// ---- Inline Rename ----
function startInlineRename(screenX, screenY, node, scenePath) {
  // Create an input overlay at the node position
  const existingInput = document.getElementById('inline-rename-input');
  if (existingInput) existingInput.remove();
  
  const input = document.createElement('input');
  input.id = 'inline-rename-input';
  input.type = 'text';
  input.value = node.name;
  input.style.cssText = `
    position: fixed;
    left: ${screenX - 50}px;
    top: ${screenY - 12}px;
    width: 120px;
    padding: 4px 8px;
    font-size: 12px;
    font-family: -apple-system, system-ui, sans-serif;
    font-weight: 600;
    background: #242428;
    border: 2px solid #7aa2f7;
    border-radius: 4px;
    color: #e8e4df;
    z-index: 1000;
    outline: none;
  `;
  
  document.body.appendChild(input);
  input.focus();
  input.select();
  
  async function finishRename() {
    const newName = input.value.trim();
    input.remove();
    
    if (newName && newName !== node.name) {
      try {
        const result = await sendCommand('rename_node', {
          scene_path: scenePath,
          node_path: node.path,
          new_name: newName
        });
        
        if (result.ok) {
          await refreshExpandedScene(scenePath);
        } else {
          alert('Failed to rename: ' + (result.error || 'Unknown error'));
        }
      } catch (err) {
        alert('Failed to rename: ' + err.message);
      }
    }
  }
  
  input.addEventListener('blur', finishRename);
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      input.blur();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      input.value = node.name; // Reset to original
      input.blur();
    }
  });
}

// Expose for global access
window.sceneNodeAction = sceneNodeAction;
