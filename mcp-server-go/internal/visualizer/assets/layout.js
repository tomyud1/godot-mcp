/**
 * Force-directed layout algorithm for node positioning
 */

import { nodes, edges, NODE_W, NODE_H } from './state.js';

// Minimum spacing between nodes
const MIN_SPACING_X = NODE_W + 40;
const MIN_SPACING_Y = NODE_H + 30;

export function initLayout() {
  if (nodes.length === 0) return;

  // Build adjacency map for connected nodes
  const adjacency = new Map();
  nodes.forEach(n => adjacency.set(n.path, []));

  edges.forEach(e => {
    if (adjacency.has(e.from) && adjacency.has(e.to)) {
      adjacency.get(e.from).push(e.to);
      adjacency.get(e.to).push(e.from);
    }
  });

  // Find root nodes (most connections or extends nothing)
  const connectionCount = new Map();
  nodes.forEach(n => {
    const count = (adjacency.get(n.path) || []).length;
    connectionCount.set(n.path, count);
  });

  // Sort nodes by connection count (most connected first)
  const sortedNodes = [...nodes].sort((a, b) =>
    connectionCount.get(b.path) - connectionCount.get(a.path)
  );

  // Initial placement: spread nodes in a grid with good spacing
  const cols = Math.ceil(Math.sqrt(nodes.length));
  const startX = -(cols * MIN_SPACING_X) / 2;
  const startY = -(Math.ceil(nodes.length / cols) * MIN_SPACING_Y) / 2;

  sortedNodes.forEach((n, i) => {
    const col = i % cols;
    const row = Math.floor(i / cols);
    n.x = startX + col * MIN_SPACING_X;
    n.y = startY + row * MIN_SPACING_Y;
  });

  // Run force-directed simulation with collision detection
  const iterations = 150;
  for (let iter = 0; iter < iterations; iter++) {
    const alpha = Math.pow(1 - iter / iterations, 2); // Quadratic cooling
    applyForces(alpha, adjacency);
    resolveCollisions();
  }

  // Final collision resolution pass
  for (let i = 0; i < 10; i++) {
    resolveCollisions();
  }

  // Center the layout
  centerLayout();
}

function applyForces(alpha, adjacency) {
  const repulsion = 50000;  // Strong repulsion
  const attraction = 0.08;  // Moderate attraction
  const idealEdgeLength = MIN_SPACING_X * 1.2;

  // Repulsion between all nodes
  for (let i = 0; i < nodes.length; i++) {
    for (let j = i + 1; j < nodes.length; j++) {
      const a = nodes[i];
      const b = nodes[j];
      let dx = b.x - a.x;
      let dy = b.y - a.y;

      // Add small random offset if nodes are at same position
      if (dx === 0 && dy === 0) {
        dx = (Math.random() - 0.5) * 10;
        dy = (Math.random() - 0.5) * 10;
      }

      const dist = Math.sqrt(dx * dx + dy * dy) || 1;
      const minDist = MIN_SPACING_X; // Minimum desired distance

      // Stronger repulsion when nodes are close
      let force = repulsion / (dist * dist);
      if (dist < minDist) {
        force *= 3; // Extra push when too close
      }

      const fx = (dx / dist) * force * alpha;
      const fy = (dy / dist) * force * alpha;
      a.x -= fx;
      a.y -= fy;
      b.x += fx;
      b.y += fy;
    }
  }

  // Attraction along edges - pull connected nodes together
  edges.forEach(e => {
    const from = nodes.find(n => n.path === e.from);
    const to = nodes.find(n => n.path === e.to);
    if (!from || !to) return;

    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const dist = Math.sqrt(dx * dx + dy * dy) || 1;

    // Only attract if nodes are far apart
    if (dist > idealEdgeLength) {
      const force = (dist - idealEdgeLength) * attraction * alpha;
      const fx = (dx / dist) * force;
      const fy = (dy / dist) * force;
      from.x += fx;
      from.y += fy;
      to.x -= fx;
      to.y -= fy;
    }
  });
}

function resolveCollisions() {
  // Separate overlapping nodes
  for (let i = 0; i < nodes.length; i++) {
    for (let j = i + 1; j < nodes.length; j++) {
      const a = nodes[i];
      const b = nodes[j];

      // Check for overlap using bounding boxes
      const overlapX = MIN_SPACING_X - Math.abs(b.x - a.x);
      const overlapY = MIN_SPACING_Y - Math.abs(b.y - a.y);

      if (overlapX > 0 && overlapY > 0) {
        // Nodes are overlapping - push them apart
        let dx = b.x - a.x;
        let dy = b.y - a.y;

        // Add random offset if exactly overlapping
        if (dx === 0) dx = (Math.random() - 0.5) * 2;
        if (dy === 0) dy = (Math.random() - 0.5) * 2;

        const dist = Math.sqrt(dx * dx + dy * dy) || 1;

        // Push apart in the direction of least overlap
        if (overlapX < overlapY) {
          // Push horizontally
          const push = (overlapX / 2 + 5) * Math.sign(dx);
          a.x -= push;
          b.x += push;
        } else {
          // Push vertically
          const push = (overlapY / 2 + 5) * Math.sign(dy);
          a.y -= push;
          b.y += push;
        }
      }
    }
  }
}

function centerLayout() {
  if (nodes.length === 0) return;

  // Find bounding box
  let minX = Infinity, maxX = -Infinity;
  let minY = Infinity, maxY = -Infinity;

  nodes.forEach(n => {
    minX = Math.min(minX, n.x);
    maxX = Math.max(maxX, n.x);
    minY = Math.min(minY, n.y);
    maxY = Math.max(maxY, n.y);
  });

  // Center around origin
  const centerX = (minX + maxX) / 2;
  const centerY = (minY + maxY) / 2;

  nodes.forEach(n => {
    n.x -= centerX;
    n.y -= centerY;
  });
}
