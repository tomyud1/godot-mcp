/**
 * Main entry point for the Godot Project Map Visualizer
 */

import {
  nodes, edges, camera, NODE_W, NODE_H
} from './state.js';
import { connectWebSocket } from './websocket.js';
import { initLayout } from './layout.js';
import { initCanvas, resize, draw, updateZoomIndicator, fitToView } from './canvas.js';
import { initPanel } from './panel.js';
import { initModals } from './modals.js';
import { initEvents, updateStats } from './events.js';
import './usages.js'; // Load usages module for side effects (global functions)

// Initialize everything when DOM is ready
function init() {
  // Connect WebSocket for real-time communication
  connectWebSocket();

  // Initialize canvas and rendering (also restores saved positions)
  const { positionsRestored } = initCanvas();

  // Initialize panel and modals
  initPanel();
  initModals();

  // Initialize event handlers
  initEvents();

  // Update stats
  updateStats();

  // Get zoom indicator element
  const zoomIndicator = document.getElementById('zoom-indicator');

  if (nodes.length === 0) {
    // No scripts found - show placeholder
    const ctx = document.getElementById('canvas').getContext('2d');
    const W = window.innerWidth;
    const H = window.innerHeight;

    ctx.font = '18px -apple-system, system-ui, sans-serif';
    ctx.fillStyle = '#706c66';
    ctx.textAlign = 'center';
    ctx.fillText('No scripts found in project', W / 2, H / 2);
    zoomIndicator.style.display = 'none';
  } else {
    if (positionsRestored) {
      // Positions were restored from localStorage - just update zoom indicator
      updateZoomIndicator();
    } else {
      // No saved positions - run force-directed layout
      initLayout();
      // Fit view to show all nodes
      fitToView(nodes);
    }

    // Initial draw
    draw();
  }
}

// Start when DOM is loaded
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
