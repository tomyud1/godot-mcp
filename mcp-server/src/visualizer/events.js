/**
 * Event handlers for mouse, keyboard, and search
 */

import {
  nodes, edges, camera, W, H, defaultZoom,
  dragging, setDragging,
  hoveredNode, setHoveredNode,
  searchTerm, setSearchTerm
} from './state.js';
import {
  getCanvas, screenToWorld, hitTest, draw, resize,
  updateZoomIndicator, centerOnNodes, savePositions
} from './canvas.js';
import { openPanel, closePanel } from './panel.js';

const DRAG_THRESHOLD = 5; // pixels - minimum movement to count as drag

export function initEvents() {
  const canvas = getCanvas();
  const searchInput = document.getElementById('search');
  const statsEl = document.getElementById('stats');

  // Mouse events
  canvas.addEventListener('mousedown', (e) => {
    const w = screenToWorld(e.clientX, e.clientY);
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
  });

  canvas.addEventListener('mousemove', (e) => {
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
  });

  canvas.addEventListener('mouseup', (e) => {
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
  });

  // Prevent click from also opening panel (mouseup already handles it)
  canvas.addEventListener('click', (e) => {
    // Only handle clicks on empty space (not nodes) - nodes are handled by mouseup
  });

  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    const zoomFactor = e.deltaY > 0 ? 0.9 : 1.1;
    const newZoom = Math.max(0.1, Math.min(5, camera.zoom * zoomFactor));
    const wx = (e.clientX - W / 2) / camera.zoom + camera.x;
    const wy = (e.clientY - H / 2) / camera.zoom + camera.y;
    camera.zoom = newZoom;
    camera.x = wx - (e.clientX - W / 2) / camera.zoom;
    camera.y = wy - (e.clientY - H / 2) / camera.zoom;
    updateZoomIndicator();
    draw();
  }, { passive: false });

  // Search
  searchInput.addEventListener('input', () => {
    const term = searchInput.value.toLowerCase().trim();
    setSearchTerm(term);

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

    draw();
  });

  // Keyboard shortcuts
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') closePanel();
    if (e.key === '/' && document.activeElement !== searchInput) {
      e.preventDefault();
      searchInput.focus();
    }
  });

  // Window resize
  window.addEventListener('resize', () => {
    resize();
    draw();
  });
}

export function updateStats() {
  const statsEl = document.getElementById('stats');
  statsEl.textContent = `${nodes.length} scripts · ${edges.length} connections`;
}
