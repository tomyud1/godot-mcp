/**
 * Context menu, new script modal, and view switching
 */

import {
  nodes, edges, setCurrentView, setSceneData, getFolderColor,
  setExpandedScene, setExpandedSceneHierarchy, setSelectedSceneNode,
  setHoveredSceneNode, expandedScene
} from './state.js';
import { sendCommand } from './websocket.js';
import { draw, getCanvas, roundRect, getContext, clearPositions, fitToView } from './canvas.js';
import { initLayout } from './layout.js';
import { closePanel, closeSceneNodePanel } from './panel.js';
import { updateStats } from './events.js';

let contextMenu;

export function initModals() {
  contextMenu = document.getElementById('context-menu');
  initContextMenu();
}

// ---- Context Menu ----
function initContextMenu() {
  const canvas = getCanvas();

  canvas.addEventListener('contextmenu', (e) => {
    e.preventDefault();

    // Position menu at mouse
    contextMenu.style.left = e.clientX + 'px';
    contextMenu.style.top = e.clientY + 'px';
    contextMenu.classList.add('visible');
  });

  // Hide context menu on click elsewhere
  document.addEventListener('click', (e) => {
    if (!contextMenu.contains(e.target)) {
      contextMenu.classList.remove('visible');
    }
  });

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      contextMenu.classList.remove('visible');
      closeNewScriptModal();
    }
  });
}

// ---- New Script Creation ----
window.createNewScript = function () {
  contextMenu.classList.remove('visible');
  document.getElementById('new-script-modal').style.display = 'flex';
  document.getElementById('new-script-path').focus();
};

window.closeNewScriptModal = function () {
  document.getElementById('new-script-modal').style.display = 'none';
};

function closeNewScriptModal() {
  document.getElementById('new-script-modal').style.display = 'none';
}

window.submitNewScript = async function () {
  const path = document.getElementById('new-script-path').value.trim();
  const extendsType = document.getElementById('new-script-extends').value;
  const className = document.getElementById('new-script-classname').value.trim();

  if (!path) {
    alert('Please enter a script path');
    return;
  }

  if (!path.startsWith('res://') || !path.endsWith('.gd')) {
    alert('Path must start with res:// and end with .gd');
    return;
  }

  try {
    // Use existing create_script tool via invokeTool (not internal)
    const result = await sendCommand('create_script_file', {
      path: path,
      extends: extendsType,
      class_name: className || ''
    });

    if (result.ok) {
      closeNewScriptModal();
      // Refresh the project map
      refreshProject();
    } else {
      alert('Failed to create script: ' + (result.error || 'Unknown error'));
    }
  } catch (err) {
    alert('Failed to create script: ' + err.message);
  }
};

window.refreshProject = async function () {
  contextMenu.classList.remove('visible');
  try {
    const result = await sendCommand('refresh_map', {});
    if (result.ok && result.project_map) {
      // Update nodes and edges
      const newNodes = result.project_map.nodes.map((n, i) => ({
        ...n,
        x: nodes[i]?.x || 0,
        y: nodes[i]?.y || 0,
        color: getFolderColor(n.folder),
        highlighted: true,
        visible: true
      }));
      nodes.length = 0;
      nodes.push(...newNodes);
      edges.length = 0;
      edges.push(...result.project_map.edges);
      initLayout();
      draw();
    }
  } catch (err) {
    console.error('Failed to refresh:', err);
  }
};

function refreshProject() {
  window.refreshProject();
}

// ---- Reset Layout ----
window.resetLayout = function () {
  contextMenu.classList.remove('visible');
  // Clear saved positions
  clearPositions();
  // Re-run force-directed layout
  initLayout();
  // Fit view to show all nodes
  fitToView(nodes);
  // Redraw
  draw();
};

// ---- View Switching (Scripts/Scenes) ----
window.switchView = function (view) {
  const currentViewTab = document.querySelector('#view-tabs button.active')?.textContent.toLowerCase();
  if (view === currentViewTab) return;

  // Close any open panels
  if (view === 'scripts') {
    closeSceneNodePanel();
    // Clear scene state
    setExpandedScene(null);
    setExpandedSceneHierarchy(null);
    setSelectedSceneNode(null);
    setHoveredSceneNode(null);
    // Hide scene back button
    const backBtn = document.getElementById('scene-back-btn');
    if (backBtn) backBtn.style.display = 'none';
    // Show legend for scripts view
    const legend = document.getElementById('legend');
    if (legend) legend.classList.remove('hidden');
  } else {
    closePanel();
  }

  setCurrentView(view);

  // Update tab buttons
  document.querySelectorAll('#view-tabs button').forEach(btn => {
    btn.classList.toggle('active', btn.textContent.toLowerCase() === view);
  });

  // Update search placeholder
  const searchInput = document.getElementById('search');
  if (searchInput) {
    searchInput.placeholder = view === 'scripts' ? 'Search scripts...' : 'Search scenes...';
  }

  if (view === 'scenes') {
    loadSceneView();
  } else {
    updateStats();
    draw();
  }
};

async function loadSceneView() {
  // Request scene data from Godot
  try {
    const result = await sendCommand('map_scenes', { root: 'res://' });
    if (result.ok) {
      setSceneData(result.scene_map);
      updateStats();
      draw();
    } else {
      console.error('Failed to load scenes:', result.error);
      alert('Failed to load scenes: ' + (result.error || 'Unknown error'));
    }
  } catch (err) {
    console.error('Failed to load scenes:', err);
    // Show placeholder for now
    draw();
  }
}
