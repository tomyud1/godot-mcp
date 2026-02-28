/**
 * Usage detection, delete operations, and floating usage panel
 */

import {
  nodes, selectedNode, pendingDelete, setPendingDelete,
  currentUsages, setCurrentUsages, esc
} from './state.js';
import { sendCommand } from './websocket.js';
import { highlightGDScript } from './syntax.js';
import { openPanel, expandAndHighlightFunction } from './panel.js';

// ---- Delete with Floating Usage Panel ----
window.showDeleteUsages = async function (index, isExport, type) {
  // Get the item name
  let itemName = '';
  if (type === 'signal') {
    const sig = selectedNode.signals[index];
    itemName = typeof sig === 'string' ? sig : sig.name;
  } else if (type === 'function') {
    const func = selectedNode.functions[index];
    itemName = func?.name || '';
  } else {
    const vars = selectedNode.variables.filter(v => v.exported === isExport);
    itemName = vars[index]?.name || '';
  }

  // Store pending delete info and the declaring node
  setPendingDelete({ index, isExport, type, itemName, declaringNode: selectedNode });

  // Find usages with smart detection
  const usages = findUsagesSmart(itemName, type);
  setCurrentUsages(usages);

  if (usages.length === 0) {
    // No usages, delete directly
    await performDelete(index, isExport, type, itemName);
    return;
  }

  renderUsagePanel();
};

function renderUsagePanel() {
  if (!pendingDelete) return;
  const { itemName, type } = pendingDelete;

  const panel = document.getElementById('usage-float-panel');
  const titleEl = document.getElementById('ufp-title');
  const countEl = document.getElementById('ufp-count');
  const listEl = document.getElementById('ufp-list');
  const deleteBtn = document.getElementById('ufp-delete-btn');

  // Set title based on type
  const typeLabel = type === 'signal' ? 'Signal' : type === 'function' ? 'Function' : 'Variable';
  titleEl.innerHTML = `⚠ Delete ${typeLabel}: <span style="color:#f38ba8;font-weight:600">${itemName}</span>`;

  if (currentUsages.length === 0) {
    // All usages fixed! Can delete now
    countEl.innerHTML = `<span style="color:#a6e3a1">✓ All usages fixed! Safe to delete.</span>`;
    listEl.innerHTML = '<div style="padding: 30px; text-align: center; color: var(--text-muted);">No more usages found</div>';
    deleteBtn.textContent = 'Delete Now';
    deleteBtn.style.background = 'rgba(166, 227, 161, 0.2)';
    deleteBtn.style.color = '#a6e3a1';
    deleteBtn.style.borderColor = 'rgba(166, 227, 161, 0.4)';
  } else {
    countEl.innerHTML = `Found <span class="count-num">${currentUsages.length}</span> usage${currentUsages.length > 1 ? 's' : ''} — click to navigate`;

    listEl.innerHTML = currentUsages.map((u, i) => {
      const highlightedCode = highlightUsageInCode(u.code, itemName);
      const fileName = u.file.split('/').pop().replace('.gd', '');
      return `
        <div class="ufp-item"
             data-usage-index="${i}"
             data-file="${u.file}"
             data-line="${u.line}"
             data-func="${u.funcName || ''}"
             onclick="navigateToUsage(this)">
          <div class="ufp-loc">
            <span class="ufp-func">${u.funcName || 'unknown'}</span>
            <span class="ufp-line">line ${u.line}</span>
          </div>
          <div class="ufp-code">${highlightedCode}</div>
          <div class="ufp-file">${fileName}.gd</div>
        </div>
      `;
    }).join('');
    deleteBtn.textContent = 'Delete Anyway';
    deleteBtn.style.background = '';
    deleteBtn.style.color = '';
    deleteBtn.style.borderColor = '';
  }

  deleteBtn.onclick = () => forceDeleteFromPanel();

  // Position panel if not already positioned by drag
  if (!panel.dataset.positioned) {
    const detailPanel = document.getElementById('detail-panel');
    const detailWidth = detailPanel.offsetWidth;
    panel.style.right = (detailWidth + 20) + 'px';
    panel.style.top = '80px';
    panel.style.left = 'auto';
  }

  panel.classList.add('visible');
  initUsagePanelDrag();
  initUsagePanelResize();
}

window.refreshUsages = function () {
  if (!pendingDelete) return;
  const { itemName, type } = pendingDelete;

  // Re-scan for usages
  const usages = findUsagesSmart(itemName, type);
  setCurrentUsages(usages);
  renderUsagePanel();
};

// ---- Draggable Usage Panel ----
let ufpDragging = false;
let ufpDragStart = { x: 0, y: 0 };
let ufpPanelStart = { x: 0, y: 0 };

function initUsagePanelDrag() {
  const header = document.getElementById('ufp-header');
  const panel = document.getElementById('usage-float-panel');

  // Remove existing listeners
  header.onmousedown = (e) => {
    if (e.target.tagName === 'BUTTON') return; // Don't drag when clicking buttons

    ufpDragging = true;
    panel.classList.add('dragging');
    ufpDragStart = { x: e.clientX, y: e.clientY };

    const rect = panel.getBoundingClientRect();
    ufpPanelStart = { x: rect.left, y: rect.top };

    document.addEventListener('mousemove', onUfpDrag);
    document.addEventListener('mouseup', onUfpDragEnd);
  };
}

function onUfpDrag(e) {
  if (!ufpDragging) return;

  const panel = document.getElementById('usage-float-panel');
  const dx = e.clientX - ufpDragStart.x;
  const dy = e.clientY - ufpDragStart.y;

  const newX = ufpPanelStart.x + dx;
  const newY = ufpPanelStart.y + dy;

  // Switch to left/top positioning for dragging
  panel.style.left = Math.max(0, newX) + 'px';
  panel.style.top = Math.max(0, newY) + 'px';
  panel.style.right = 'auto';
  panel.dataset.positioned = 'true';
}

function onUfpDragEnd() {
  ufpDragging = false;
  document.getElementById('usage-float-panel')?.classList.remove('dragging');
  document.removeEventListener('mousemove', onUfpDrag);
  document.removeEventListener('mouseup', onUfpDragEnd);
}

// ---- Resizable Usage Panel ----
let ufpResizing = false;
let ufpResizeStart = { x: 0, y: 0, w: 0, h: 0 };

function initUsagePanelResize() {
  const resizeHandle = document.getElementById('ufp-resize');
  const panel = document.getElementById('usage-float-panel');

  resizeHandle.onmousedown = (e) => {
    e.preventDefault();
    e.stopPropagation();
    ufpResizing = true;
    ufpResizeStart = {
      x: e.clientX,
      y: e.clientY,
      w: panel.offsetWidth,
      h: panel.offsetHeight
    };
    document.addEventListener('mousemove', onUfpResize);
    document.addEventListener('mouseup', onUfpResizeEnd);
  };
}

function onUfpResize(e) {
  if (!ufpResizing) return;
  const panel = document.getElementById('usage-float-panel');

  const dw = e.clientX - ufpResizeStart.x;
  const dh = e.clientY - ufpResizeStart.y;

  const newW = Math.max(300, ufpResizeStart.w + dw);
  const newH = Math.max(200, ufpResizeStart.h + dh);

  panel.style.width = newW + 'px';
  panel.style.height = newH + 'px';
}

function onUfpResizeEnd() {
  ufpResizing = false;
  document.removeEventListener('mousemove', onUfpResize);
  document.removeEventListener('mouseup', onUfpResizeEnd);
}

function highlightUsageInCode(code, name) {
  const escaped = esc(code);
  // Highlight the variable/signal/function name
  const regex = new RegExp(`\\b(${name})\\b`, 'g');
  return escaped.replace(regex, '<span class="highlight">$1</span>');
}

window.closeUsagePanel = function () {
  const panel = document.getElementById('usage-float-panel');
  panel.classList.remove('visible');
  panel.dataset.positioned = '';
  panel.style.left = '';
  panel.style.right = '';
  panel.style.top = '';
  setPendingDelete(null);
  setCurrentUsages([]);
};

window.navigateToUsage = function (el) {
  // Mark this item as active
  document.querySelectorAll('#ufp-list .ufp-item').forEach(item => {
    item.classList.remove('active');
  });
  el.classList.add('active');

  const file = el.dataset.file;
  const line = parseInt(el.dataset.line);
  const funcName = el.dataset.func;

  // Find the node for this file
  const targetNode = nodes.find(n => n.path === file);
  if (!targetNode) {
    console.log('Node not found for file:', file);
    return;
  }

  // If it's a different node, switch to it
  if (selectedNode?.path !== targetNode.path) {
    openPanel(targetNode);
    // Wait for panel to render
    setTimeout(() => {
      if (funcName) {
        expandAndHighlightFunction(funcName, line, targetNode);
      }
    }, 150);
  } else {
    // Same node, just expand/highlight
    if (funcName) {
      expandAndHighlightFunction(funcName, line, targetNode);
    }
  }
};

async function performDelete(index, isExport, type, itemName) {
  try {
    if (type === 'signal') {
      await sendCommand('modify_signal', {
        path: selectedNode.path,
        action: 'delete',
        old_name: itemName
      });
      selectedNode.signals.splice(index, 1);
    } else if (type === 'function') {
      await sendCommand('modify_function_delete', {
        path: selectedNode.path,
        name: itemName
      });
      selectedNode.functions.splice(index, 1);
    } else {
      await sendCommand('modify_variable', {
        path: selectedNode.path,
        action: 'delete',
        old_name: itemName
      });
      const vars = selectedNode.variables.filter(v => v.exported === isExport);
      const actualIndex = selectedNode.variables.findIndex(v => v.name === vars[index].name);
      if (actualIndex !== -1) selectedNode.variables.splice(actualIndex, 1);
    }
    console.log(`Deleted ${type} "${itemName}" from ${selectedNode.path}`);
    window.closeUsagePanel();
    openPanel(selectedNode);
  } catch (err) {
    console.error('Failed to delete:', err);
    alert('Failed to delete: ' + err.message);
  }
}

async function forceDeleteFromPanel() {
  if (!pendingDelete) return;
  const { index, isExport, type, itemName } = pendingDelete;
  await performDelete(index, isExport, type, itemName);
}

// ---- Smart Usage Detection ----
// Avoids false positives like matching "new" in "SomeClass.new()"
function findUsagesSmart(name, type) {
  const usages = [];

  // GDScript built-in methods/keywords to avoid false positives
  const builtinMethods = ['new', 'free', 'queue_free', 'get', 'set', 'call', 'emit', 'connect', 'disconnect'];
  const isBuiltinMethod = builtinMethods.includes(name);

  for (const node of nodes) {
    // Check if this is the node where the item is declared
    const isDeclaringNode = node.path === selectedNode?.path;

    for (const func of (node.functions || [])) {
      if (!func.body) continue;

      const lines = func.body.split('\n');
      lines.forEach((line, i) => {
        const lineNum = (func.line || 1) + i;

        // Skip the declaration line itself
        if (isDeclaringNode && isDeclarationLine(line, name, type)) {
          return;
        }

        // Check if this line actually uses the variable/signal/function
        if (isActualUsage(line, name, type, isBuiltinMethod)) {
          usages.push({
            file: node.path,
            line: lineNum,
            code: line.trim(),
            funcName: func.name
          });
        }
      });
    }
  }

  return usages;
}

function isDeclarationLine(line, name, type) {
  const trimmed = line.trim();
  if (type === 'variable') {
    // var name, @export var name, @onready var name
    return new RegExp(`^(@export\\s+)?(@onready\\s+)?var\\s+${name}\\b`).test(trimmed);
  }
  if (type === 'signal') {
    return new RegExp(`^signal\\s+${name}\\b`).test(trimmed);
  }
  if (type === 'function') {
    return new RegExp(`^func\\s+${name}\\s*\\(`).test(trimmed);
  }
  return false;
}

function isActualUsage(line, name, type, isBuiltinMethod) {
  // Build a regex that matches the name as a word boundary
  const namePattern = `\\b${name}\\b`;

  if (!new RegExp(namePattern).test(line)) {
    return false; // Name not in line at all
  }

  // For variables named like builtins (e.g., "new"), do extra checks
  if (isBuiltinMethod) {
    // Exclude patterns like "ClassName.new()" or ".new()"
    // These are constructor calls, not variable usages
    const constructorPattern = new RegExp(`\\.${name}\\s*\\(`);
    if (constructorPattern.test(line)) {
      // Check if the name appears OUTSIDE of a constructor pattern too
      const withoutConstructors = line.replace(new RegExp(`\\w+\\.${name}\\s*\\([^)]*\\)`, 'g'), '');
      if (!new RegExp(namePattern).test(withoutConstructors)) {
        return false; // Only appears in constructor calls
      }
    }
  }

  // For signals, check for signal-specific patterns
  if (type === 'signal') {
    // Match: signal_name.emit(), signal_name.connect(), etc.
    return new RegExp(`\\b${name}\\s*\\.\\s*(emit|connect|disconnect)\\b`).test(line) ||
      new RegExp(`\\.${name}\\s*\\.\\s*(connect|emit)`).test(line);
  }

  // For functions, match function calls
  if (type === 'function') {
    return new RegExp(`\\b${name}\\s*\\(`).test(line);
  }

  // For variables, the name should appear as a standalone identifier
  // Not as part of another word and not only in a method call position
  return true;
}
