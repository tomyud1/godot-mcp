/**
 * Detail panel, inline editing, function viewer, and section management
 */

import {
  nodes, edges, selectedNode, setSelectedNode, esc,
  selectedSceneNode, setSelectedSceneNode,
  sceneNodeProperties, setSceneNodeProperties,
  expandedScene, scriptToScenes
} from './state.js';
import { sendCommand } from './websocket.js';
import { highlightGDScript } from './syntax.js';
import { draw } from './canvas.js';

let detailPanel;
let currentPanelMode = 'script'; // 'script' or 'sceneNode'

export function initPanel() {
  detailPanel = document.getElementById('detail-panel');
  initPanelResizing();
}

export function openPanel(node) {
  setSelectedNode(node);

  document.getElementById('panel-title').textContent = node.class_name || node.filename.replace('.gd', '');
  document.getElementById('panel-path').textContent = node.path;

  let html = '';

  // Description
  if (node.description) {
    html += `<div class="desc-block">${esc(node.description)}</div>`;
  }

  // Meta badges
  html += `<div class="meta-row">`;
  html += `<div class="meta-badge"><span>${node.line_count}</span> lines</div>`;
  html += `<div class="meta-badge">extends <span>${node.extends || 'Node'}</span></div>`;
  if (node.class_name) html += `<div class="meta-badge">class <span>${esc(node.class_name)}</span></div>`;
  html += `</div>`;
  
  // Scene usage (if this script is used in scenes)
  const usedInScenes = scriptToScenes[node.path];
  if (usedInScenes && usedInScenes.length > 0) {
    html += `<div class="section scene-usage-section">`;
    html += `<div class="section-header">Used in Scenes <span class="section-count">${usedInScenes.length}</span></div>`;
    html += `<ul class="item-list scene-list">`;
    for (const scene of usedInScenes) {
      html += `<li class="scene-link" onclick="jumpToScene('${esc(scene.path)}')">`;
      html += `<span class="scene-icon">📦</span>`;
      html += `<span class="scene-name">${esc(scene.name)}</span>`;
      html += `</li>`;
    }
    html += `</ul>`;
    html += `</div>`;
  }

  // Variables - split into @export and regular
  const exportVars = (node.variables || []).filter(v => v.exported);
  const regularVars = (node.variables || []).filter(v => !v.exported);

  // Exports section (always show for adding)
  html += `<div class="section">`;
  html += `<div class="section-header">Exports <span class="section-count">${exportVars.length}</span></div>`;
  html += `<ul class="item-list" id="exports-list">`;
  for (let vi = 0; vi < exportVars.length; vi++) {
    const v = exportVars[vi];
    html += `<li data-var-index="${vi}" data-exported="true">`;
    html += `<span class="exp">@export</span> `;
    html += `<span class="kw">var</span> `;
    html += `<span class="editable var-name" contenteditable="true" data-field="name" data-original="${esc(v.name)}">${esc(v.name)}</span>`;
    html += `<span class="ret">:</span> `;
    html += `<span class="tp editable var-type" contenteditable="true" data-field="type" data-placeholder="Type" data-original="${esc(v.type || '')}">${esc(v.type || '')}</span>`;
    html += ` <span class="ret">=</span> `;
    html += `<span class="num editable var-default" contenteditable="true" data-field="default" data-placeholder="value" data-original="${esc(v.default || '')}">${esc(v.default || '')}</span>`;
    html += `<span class="item-actions">`;
    html += `<button class="delete" onclick="showDeleteUsages(${vi}, true, 'variable')" title="Delete">×</button>`;
    html += `</span>`;
    html += `</li>`;
  }
  html += `</ul>`;
  html += `<div class="add-item-btn" onclick="addNewVariable(true)">`;
  html += `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 5v14M5 12h14"/></svg>`;
  html += `Add export</div>`;
  html += `</div>`;

  // Variables section (always show for adding)
  html += `<div class="section">`;
  html += `<div class="section-header">Variables <span class="section-count">${regularVars.length}</span></div>`;
  html += `<ul class="item-list" id="vars-list">`;
  for (let vi = 0; vi < regularVars.length; vi++) {
    const v = regularVars[vi];
    html += `<li data-var-index="${vi}" data-exported="false" data-onready="${v.onready || false}">`;
    if (v.onready) {
      html += `<span class="onready-badge" onclick="toggleOnready(${vi}, false)" title="Click to toggle @onready">@onready</span>`;
    }
    html += `<span class="kw">var</span> `;
    html += `<span class="editable var-name" contenteditable="true" data-field="name" data-original="${esc(v.name)}">${esc(v.name)}</span>`;
    html += `<span class="ret">:</span> `;
    html += `<span class="tp editable var-type" contenteditable="true" data-field="type" data-placeholder="Type" data-original="${esc(v.type || '')}">${esc(v.type || '')}</span>`;
    html += ` <span class="ret">=</span> `;
    html += `<span class="num editable var-default" contenteditable="true" data-field="default" data-placeholder="value" data-original="${esc(v.default || '')}">${esc(v.default || '')}</span>`;
    html += `<span class="item-actions">`;
    if (!v.onready) {
      html += `<button onclick="toggleOnready(${vi}, false)" title="Add @onready" style="font-size:9px;width:auto;padding:0 4px;">⏱</button>`;
    }
    html += `<button class="delete" onclick="showDeleteUsages(${vi}, false, 'variable')" title="Delete">×</button>`;
    html += `</span>`;
    html += `</li>`;
  }
  html += `</ul>`;
  html += `<div class="add-item-btn" onclick="addNewVariable(false)">`;
  html += `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 5v14M5 12h14"/></svg>`;
  html += `Add variable</div>`;
  html += `</div>`;

  // Functions
  if ((node.functions || []).length > 0) {
    html += `<div class="section">`;
    html += `<div class="section-header">Functions <span class="section-count">${node.functions.length}</span></div>`;
    html += `<ul class="item-list">`;
    for (let fi = 0; fi < node.functions.length; fi++) {
      const f = node.functions[fi];
      html += `<li class="clickable" onclick="toggleFunc(${fi})">`;
      html += `<span class="kw">func</span> <span class="fn">${esc(f.name)}</span>`;
      html += `<span class="param">(${esc(f.params)})</span>`;
      if (f.return_type) html += ` <span class="ret">&rarr;</span> <span class="tp">${esc(f.return_type)}</span>`;
      html += `<span style="margin-left:auto;display:flex;gap:4px;align-items:center">`;
      if (f.body_lines) html += `<span class="tag tag-lines">${f.body_lines}L</span>`;
      html += `<button class="delete" onclick="event.stopPropagation();showDeleteUsages(${fi}, false, 'function')" title="Delete function" style="opacity:0">×</button>`;
      html += `</span>`;
      html += `</li>`;
      html += `<div id="func-viewer-${fi}" class="func-viewer" style="display:none"></div>`;
    }
    html += `</ul></div>`;
  }

  // Signals section (always show for adding)
  const signalsList = node.signals || [];
  html += `<div class="section">`;
  html += `<div class="section-header">Signals <span class="section-count">${signalsList.length}</span></div>`;
  html += `<ul class="item-list" id="signals-list">`;
  for (let si = 0; si < signalsList.length; si++) {
    const s = signalsList[si];
    const sigName = typeof s === 'string' ? s : s.name;
    const sigParams = typeof s === 'object' ? s.params : '';
    html += `<li data-signal-index="${si}">`;
    html += `<span class="kw">signal</span> `;
    html += `<span class="sig editable signal-name" contenteditable="true" data-field="name" data-original="${esc(sigName)}">${esc(sigName)}</span>`;
    html += `<span class="param">(</span>`;
    html += `<span class="editable signal-params" contenteditable="true" data-field="params" data-placeholder="params" data-original="${esc(sigParams)}">${esc(sigParams)}</span>`;
    html += `<span class="param">)</span>`;
    html += `<span class="item-actions">`;
    html += `<button class="delete" onclick="showDeleteUsages(${si}, false, 'signal')" title="Delete">×</button>`;
    html += `</span>`;
    html += `</li>`;
  }
  html += `</ul>`;
  html += `<div class="add-item-btn" onclick="addNewSignal()">`;
  html += `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 5v14M5 12h14"/></svg>`;
  html += `Add signal</div>`;
  html += `</div>`;

  // Connections - group by target and show signal names
  const related = edges.filter(e => e.from === node.path || e.to === node.path);
  if (related.length > 0) {
    // Group connections by target and type
    const connGroups = {};
    for (const e of related) {
      const other = e.from === node.path ? e.to : e.from;
      const dir = e.from === node.path ? 'out' : 'in';
      const key = `${other}-${e.type}-${dir}`;
      if (!connGroups[key]) {
        connGroups[key] = { other, type: e.type, dir, signals: [] };
      }
      if (e.signal_name) connGroups[key].signals.push(e.signal_name);
    }

    html += `<div class="section">`;
    html += `<div class="section-header">Connections <span class="section-count">${related.length}</span></div>`;
    html += `<ul class="item-list">`;

    for (const key of Object.keys(connGroups)) {
      const g = connGroups[key];
      const dirIcon = g.dir === 'out' ? '→' : '←';
      const color = g.type === 'extends' ? 'var(--edge-extends)' : g.type === 'preload' ? 'var(--edge-preload)' : 'var(--edge-signal)';
      const filename = g.other.split('/').pop();

      html += `<li style="flex-wrap:wrap">`;
      html += `${dirIcon} <span style="color:${color}">${esc(filename)}</span> <span class="ret">(${g.type})</span>`;

      // Show signal names if this is a signal connection
      if (g.type === 'signal' && g.signals.length > 0) {
        const uniqueSignals = [...new Set(g.signals)];
        html += `<div style="width:100%;margin-top:4px;padding-left:20px;font-size:11px;color:var(--text-muted)">`;
        html += uniqueSignals.map(s => `<span class="sig">${esc(s)}</span>`).join(', ');
        html += `</div>`;
      }
      html += `</li>`;
    }
    html += `</ul></div>`;
  }

  // Preloads
  if ((node.preloads || []).length > 0) {
    html += `<div class="section">`;
    html += `<div class="section-header">Preloads <span class="section-count">${node.preloads.length}</span></div>`;
    html += `<ul class="item-list">`;
    for (const p of node.preloads) {
      html += `<li><span class="str">"${esc(p)}"</span></li>`;
    }
    html += `</ul></div>`;
  }

  document.getElementById('panel-body').innerHTML = html;
  detailPanel.classList.add('open');
  initSectionResizing();
  initInlineEditing();
  draw();
}

export function closePanel() {
  setSelectedNode(null);
  detailPanel.classList.remove('open');
  draw();
}

// Make closePanel available globally for onclick
window.closePanel = closePanel;

// Toggle function body viewer with inline editing
window.toggleFunc = function (fi) {
  const viewer = document.getElementById(`func-viewer-${fi}`);
  if (!viewer) return;

  if (viewer.style.display !== 'none') {
    viewer.style.display = 'none';
    viewer.innerHTML = '';
    return;
  }

  const f = selectedNode.functions[fi];
  if (!f.body) return;

  const editorId = `code-editor-${fi}`;

  viewer.innerHTML = `
    <div class="func-viewer-header">
      <span><span class="func-title">${esc(f.name)}</span> · <span id="line-count-${fi}">${f.body.split('\n').length}</span> lines</span>
      <button class="func-viewer-close" onclick="toggleFunc(${fi})">&times;</button>
    </div>
    <div class="func-viewer-code">
      <div class="code-editor-container" id="${editorId}">
        <div class="code-editor-highlight" id="highlight-${fi}"></div>
        <textarea class="code-editor-textarea" id="textarea-${fi}" spellcheck="false"></textarea>
      </div>
    </div>
    <div class="func-viewer-footer">
      <span class="status" id="status-${fi}">Modified</span>
      <span style="display:flex;gap:8px;align-items:center">
        <span style="opacity:0.6">Ctrl+S to save</span>
        <button class="save-btn" id="save-btn-${fi}" onclick="saveFunction(${fi})">Save</button>
      </span>
    </div>
  `;

  const textarea = document.getElementById(`textarea-${fi}`);
  const highlight = document.getElementById(`highlight-${fi}`);
  const statusEl = document.getElementById(`status-${fi}`);
  const saveBtn = document.getElementById(`save-btn-${fi}`);
  const lineCountEl = document.getElementById(`line-count-${fi}`);

  // Store original code for comparison
  textarea.dataset.original = f.body;
  textarea.dataset.funcIndex = fi;
  textarea.dataset.scriptPath = selectedNode.path;
  textarea.dataset.funcName = f.name;
  textarea.value = f.body;

  // Initial highlight
  updateHighlight(fi);

  // Sync highlight on input
  textarea.addEventListener('input', () => {
    updateHighlight(fi);
    const modified = textarea.value !== textarea.dataset.original;
    statusEl.classList.toggle('visible', modified);
    saveBtn.classList.toggle('active', modified);
    lineCountEl.textContent = textarea.value.split('\n').length;
  });

  // Sync scroll
  textarea.addEventListener('scroll', () => {
    highlight.style.transform = `translate(-${textarea.scrollLeft}px, -${textarea.scrollTop}px)`;
  });

  // Handle tab key
  textarea.addEventListener('keydown', (e) => {
    if (e.key === 'Tab') {
      e.preventDefault();
      const start = textarea.selectionStart;
      const end = textarea.selectionEnd;
      textarea.value = textarea.value.substring(0, start) + '\t' + textarea.value.substring(end);
      textarea.selectionStart = textarea.selectionEnd = start + 1;
      textarea.dispatchEvent(new Event('input'));
    }
    // Ctrl+S to save
    if (e.key === 's' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      saveFunction(fi);
    }
  });

  // Auto-resize textarea height
  function autoResize() {
    textarea.style.height = 'auto';
    textarea.style.height = textarea.scrollHeight + 'px';
    highlight.style.height = textarea.scrollHeight + 'px';
  }
  textarea.addEventListener('input', autoResize);
  setTimeout(autoResize, 0);

  viewer.style.display = 'block';
};

// Update syntax highlighting
function updateHighlight(fi) {
  const textarea = document.getElementById(`textarea-${fi}`);
  const highlight = document.getElementById(`highlight-${fi}`);
  if (!textarea || !highlight) return;

  // Highlight each line, wrap in spans for line-level highlighting
  const lines = textarea.value.split('\n');
  highlight.innerHTML = lines.map((line, i) =>
    `<div class="code-line" data-line="${i}">${highlightGDScript(line) || ' '}</div>`
  ).join('');
}

// Save function changes back to Godot
window.saveFunction = async function (fi) {
  const textarea = document.getElementById(`textarea-${fi}`);
  const statusEl = document.getElementById(`status-${fi}`);
  const saveBtn = document.getElementById(`save-btn-${fi}`);

  if (!textarea || textarea.value === textarea.dataset.original) return;

  const scriptPath = textarea.dataset.scriptPath;
  const funcName = textarea.dataset.funcName;
  const newCode = textarea.value;

  statusEl.textContent = 'Saving...';
  statusEl.classList.add('visible');

  try {
    // Send to Godot
    await sendCommand('modify_function', {
      path: scriptPath,
      name: funcName,
      body: newCode
    });

    // Update local state
    const funcIndex = parseInt(textarea.dataset.funcIndex);
    selectedNode.functions[funcIndex].body = newCode;
    selectedNode.functions[funcIndex].body_lines = newCode.split('\n').length;

    textarea.dataset.original = newCode;
    statusEl.textContent = 'Saved!';
    saveBtn.classList.remove('active');

    setTimeout(() => {
      statusEl.classList.remove('visible');
    }, 2000);

    console.log(`Saved function "${funcName}" in ${scriptPath}`);
  } catch (err) {
    statusEl.textContent = 'Error: ' + err.message;
    console.error('Failed to save:', err);
  }
};

// ---- Inline Editing for Variables/Signals ----
function initInlineEditing() {
  // Handle blur on editable fields - save changes
  document.querySelectorAll('.editable').forEach(el => {
    el.addEventListener('blur', handleInlineEdit);
    el.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        el.blur();
      }
      if (e.key === 'Escape') {
        el.textContent = el.dataset.original || '';
        el.blur();
      }
    });
  });
}

async function handleInlineEdit(e) {
  const el = e.target;
  const li = el.closest('li');
  if (!li) return;

  const newValue = el.textContent.trim();
  const original = el.dataset.original || '';
  const field = el.dataset.field;

  if (newValue === original) return; // No change

  // Determine what type of item this is
  const isSignal = li.dataset.signalIndex !== undefined;
  const isExport = li.dataset.exported === 'true';
  const index = parseInt(isSignal ? li.dataset.signalIndex : li.dataset.varIndex);

  try {
    if (isSignal) {
      // Update signal
      const sig = selectedNode.signals[index];
      const oldName = typeof sig === 'string' ? sig : sig.name;
      const oldParams = typeof sig === 'object' ? sig.params : '';

      const newSig = {
        name: field === 'name' ? newValue : oldName,
        params: field === 'params' ? newValue : oldParams
      };

      // Send to Godot
      await sendCommand('modify_signal', {
        path: selectedNode.path,
        action: 'update',
        old_name: oldName,
        name: newSig.name,
        params: newSig.params
      });

      // Update local state
      selectedNode.signals[index] = newSig;
      console.log(`Updated signal in ${selectedNode.path}:`, newSig);
    } else {
      // Update variable
      const vars = selectedNode.variables.filter(v => v.exported === isExport);
      const v = vars[index];
      const actualIndex = selectedNode.variables.findIndex(vr => vr.name === v.name);

      if (actualIndex !== -1) {
        const newVar = { ...selectedNode.variables[actualIndex] };
        if (field === 'name') newVar.name = newValue;
        if (field === 'type') newVar.type = newValue;
        if (field === 'default') newVar.default = newValue;

        // Send to Godot
        await sendCommand('modify_variable', {
          path: selectedNode.path,
          action: 'update',
          old_name: v.name,
          name: newVar.name,
          type: newVar.type,
          default: newVar.default,
          exported: isExport
        });

        // Update local state
        selectedNode.variables[actualIndex] = newVar;
        console.log(`Updated variable in ${selectedNode.path}:`, newVar);
      }
    }

    // Update the original value
    el.dataset.original = newValue;
  } catch (err) {
    console.error('Failed to update:', err);
    // Revert on error
    el.textContent = original;
    alert('Failed to save: ' + err.message);
  }
}

// ---- Toggle @onready ----
window.toggleOnready = async function (index, isExport) {
  const vars = selectedNode.variables.filter(v => v.exported === isExport);
  const v = vars[index];
  const actualIndex = selectedNode.variables.findIndex(vr => vr.name === v.name);

  if (actualIndex === -1) return;

  const newOnready = !v.onready;

  try {
    await sendCommand('modify_variable', {
      path: selectedNode.path,
      action: 'update',
      old_name: v.name,
      name: v.name,
      type: v.type || '',
      default: v.default || '',
      exported: isExport,
      onready: newOnready
    });

    selectedNode.variables[actualIndex].onready = newOnready;
    openPanel(selectedNode);
  } catch (err) {
    console.error('Failed to toggle @onready:', err);
    alert('Failed to update: ' + err.message);
  }
};

// ---- Add New Items ----
window.addNewVariable = async function (isExport) {
  const newVar = { name: 'new_var', type: '', default: '', exported: isExport };

  try {
    // Send to Godot first
    await sendCommand('modify_variable', {
      path: selectedNode.path,
      action: 'add',
      name: newVar.name,
      type: newVar.type,
      default: newVar.default,
      exported: isExport
    });

    // Update local state
    selectedNode.variables.push(newVar);
    openPanel(selectedNode);

    // Focus the new variable name after panel refresh
    setTimeout(() => {
      const list = document.getElementById(isExport ? 'exports-list' : 'vars-list');
      const lastItem = list?.querySelector('li:last-of-type .var-name');
      if (lastItem) {
        lastItem.focus();
        const range = document.createRange();
        range.selectNodeContents(lastItem);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      }
    }, 50);
  } catch (err) {
    console.error('Failed to add variable:', err);
    alert('Failed to add variable: ' + err.message);
  }
};

window.addNewSignal = async function () {
  const newSig = { name: 'new_signal', params: '' };

  try {
    // Send to Godot first
    await sendCommand('modify_signal', {
      path: selectedNode.path,
      action: 'add',
      name: newSig.name,
      params: newSig.params
    });

    // Update local state
    if (!selectedNode.signals) selectedNode.signals = [];
    selectedNode.signals.push(newSig);
    openPanel(selectedNode);

    setTimeout(() => {
      const list = document.getElementById('signals-list');
      const lastItem = list?.querySelector('li:last-of-type .signal-name');
      if (lastItem) {
        lastItem.focus();
        const range = document.createRange();
        range.selectNodeContents(lastItem);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      }
    }, 50);
  } catch (err) {
    console.error('Failed to add signal:', err);
    alert('Failed to add signal: ' + err.message);
  }
};

// Section resizing
let resizingList = null;
let resizeStartY = 0;
let resizeStartHeight = 0;

function initSectionResizing() {
  document.querySelectorAll('.section-resize-handle').forEach(handle => {
    // Remove old listeners
    handle.replaceWith(handle.cloneNode(true));
  });

  document.querySelectorAll('.section-resize-handle').forEach(handle => {
    handle.addEventListener('mousedown', (e) => {
      e.preventDefault();
      e.stopPropagation();

      // Find the item-list in this section
      const section = handle.closest('.section');
      resizingList = section?.querySelector('.item-list');
      if (!resizingList) return;

      section.classList.add('resizing');
      resizeStartY = e.clientY;
      resizeStartHeight = resizingList.offsetHeight;

      document.addEventListener('mousemove', onSectionResize);
      document.addEventListener('mouseup', onSectionResizeEnd);
    });
  });
}

function onSectionResize(e) {
  if (!resizingList) return;
  const dy = e.clientY - resizeStartY;
  const newHeight = Math.max(50, Math.min(500, resizeStartHeight + dy));
  resizingList.style.maxHeight = newHeight + 'px';
}

function onSectionResizeEnd() {
  if (resizingList) {
    const section = resizingList.closest('.section');
    section?.classList.remove('resizing');
    resizingList = null;
  }
  document.removeEventListener('mousemove', onSectionResize);
  document.removeEventListener('mouseup', onSectionResizeEnd);
}

// Panel horizontal resizing
let panelResizing = false;
let panelResizeStartX = 0;
let panelStartWidth = 460;

function initPanelResizing() {
  const handle = document.getElementById('panel-resize-handle');
  const panel = document.getElementById('detail-panel');

  handle.addEventListener('mousedown', (e) => {
    e.preventDefault();
    e.stopPropagation();
    panelResizing = true;
    panel.classList.add('resizing');
    panelResizeStartX = e.clientX;
    panelStartWidth = panel.offsetWidth;

    document.addEventListener('mousemove', onPanelResize);
    document.addEventListener('mouseup', onPanelResizeEnd);
  });
}

function onPanelResize(e) {
  if (!panelResizing) return;
  const panel = document.getElementById('detail-panel');
  const dx = panelResizeStartX - e.clientX; // Dragging left = wider
  const newWidth = Math.max(300, Math.min(window.innerWidth * 0.8, panelStartWidth + dx));
  panel.style.width = newWidth + 'px';
  panel.style.right = '0';
}

function onPanelResizeEnd() {
  panelResizing = false;
  const panel = document.getElementById('detail-panel');
  panel.classList.remove('resizing');
  document.removeEventListener('mousemove', onPanelResize);
  document.removeEventListener('mouseup', onPanelResizeEnd);
}

// Function to expand and highlight a specific line in a function viewer
export function expandAndHighlightFunction(funcName, targetLine, nodeData) {
  const node = nodeData || selectedNode;

  // Find the function index
  const funcIndex = node.functions.findIndex(f => f.name === funcName);
  if (funcIndex === -1) {
    console.log('Function not found:', funcName);
    return;
  }

  console.log(`Expanding function ${funcName} (index ${funcIndex}) to line ${targetLine}`);

  // Get the function viewer element
  const viewer = document.getElementById(`func-viewer-${funcIndex}`);
  if (!viewer) {
    console.log('Viewer element not found for index:', funcIndex);
    return;
  }

  // Check if already expanded
  const isExpanded = viewer.style.display !== 'none';

  if (!isExpanded) {
    // Need to expand - call toggleFunc
    window.toggleFunc(funcIndex);
  }

  // Wait for expansion, then highlight
  setTimeout(() => {
    highlightLineInViewer(viewer, funcName, targetLine, node);
    // Scroll the viewer into view
    viewer.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }, isExpanded ? 100 : 300);
}

function highlightLineInViewer(viewer, funcName, targetLine, nodeData) {
  // Find the function to get its start line
  const node = nodeData || selectedNode;
  const func = node.functions.find(f => f.name === funcName);
  if (!func) {
    console.log('Function not found for highlighting:', funcName);
    return;
  }

  const funcStartLine = func.line || 1;
  const relativeLineIndex = targetLine - funcStartLine;

  console.log(`Highlighting line ${targetLine} in ${funcName} (start: ${funcStartLine}, relative: ${relativeLineIndex})`);

  // Find the highlight overlay within the viewer
  const highlightDiv = viewer.querySelector('.code-editor-highlight');
  if (!highlightDiv) {
    console.log('Highlight div not found in viewer');
    return;
  }

  // Clear all previous highlights
  document.querySelectorAll('.code-line-highlight').forEach(el => {
    el.classList.remove('code-line-highlight');
  });

  // Get all lines and highlight the target
  const lines = highlightDiv.querySelectorAll('.code-line');
  console.log(`Found ${lines.length} lines in viewer`);

  if (relativeLineIndex >= 0 && relativeLineIndex < lines.length) {
    const targetLineEl = lines[relativeLineIndex];
    targetLineEl.classList.add('code-line-highlight');

    // Scroll the line into view within the code editor
    setTimeout(() => {
      targetLineEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }, 50);
  } else {
    console.log(`Line index ${relativeLineIndex} out of range (0-${lines.length - 1})`);
  }
}

// ============================================================================
// SCENE NODE PROPERTIES PANEL
// ============================================================================

export async function openSceneNodePanel(scenePath, node) {
  currentPanelMode = 'sceneNode';
  setSelectedSceneNode(node);

  // Show loading state
  document.getElementById('panel-title').textContent = node.name;
  document.getElementById('panel-path').textContent = `${node.type} • ${node.path}`;
  document.getElementById('panel-body').innerHTML = '<div class="loading-state">Loading properties...</div>';
  detailPanel.classList.add('open');

  try {
    // Fetch properties from Godot
    const result = await sendCommand('get_scene_node_properties', {
      scene_path: scenePath,
      node_path: node.path
    });

    if (result.ok) {
      setSceneNodeProperties(result);
      renderSceneNodePanel(result, scenePath, node);
    } else {
      document.getElementById('panel-body').innerHTML = `<div class="error-state">Failed to load properties: ${result.error}</div>`;
    }
  } catch (err) {
    console.error('Failed to fetch node properties:', err);
    document.getElementById('panel-body').innerHTML = `<div class="error-state">Error: ${err.message}</div>`;
  }
}

export function closeSceneNodePanel() {
  if (currentPanelMode === 'sceneNode') {
    setSelectedSceneNode(null);
    setSceneNodeProperties(null);
    detailPanel.classList.remove('open');
    draw();
  }
}

function renderSceneNodePanel(data, scenePath, node) {
  document.getElementById('panel-title').textContent = data.node_name;
  document.getElementById('panel-path').textContent = `${data.node_type} • ${data.node_path}`;

  let html = '';

  // Meta badges
  html += `<div class="meta-row">`;
  html += `<div class="meta-badge"><span>${data.node_type}</span></div>`;
  html += `<div class="meta-badge">${data.property_count} <span>properties</span></div>`;
  if (node.script) {
    html += `<div class="meta-badge script-badge" onclick="jumpToScript('${esc(node.script)}')">📜 <span>${node.script.split('/').pop()}</span></div>`;
  }
  html += `</div>`;

  // Render categories
  const categories = data.categories || {};
  const categoryOrder = data.inheritance_chain || Object.keys(categories);

  for (const category of categoryOrder) {
    const props = categories[category];
    if (!props || props.length === 0) continue;

    html += `<div class="section property-section" data-category="${esc(category)}">`;
    html += `<div class="section-header clickable" onclick="togglePropertySection(this)">`;
    html += `<span>${category}</span>`;
    html += `<span class="section-count">${props.length}</span>`;
    html += `</div>`;
    html += `<div class="property-list">`;

    for (const prop of props) {
      html += renderPropertyRow(prop, scenePath, data.node_path);
    }

    html += `</div></div>`;
  }

  document.getElementById('panel-body').innerHTML = html;
  initPropertyEditing(scenePath, data.node_path);
}

// Convert snake_case to Title Case for display
function formatPropertyName(name) {
  return name
    .replace(/_/g, ' ')
    .replace(/\b\w/g, c => c.toUpperCase());
}

function renderPropertyRow(prop, scenePath, nodePath) {
  const { name, type, type_name, value, hint, hint_string } = prop;
  const displayName = formatPropertyName(name);

  let html = `<div class="property-row" data-prop="${esc(name)}" data-type="${type}">`;
  html += `<label class="property-name" title="${esc(name)}">${esc(displayName)}</label>`;
  html += `<div class="property-value">`;

  // Render appropriate control based on type
  switch (type) {
    case 1: // TYPE_BOOL
      const boolChecked = value === true ? 'checked' : '';
      html += `<label class="toggle-switch">
        <input type="checkbox" ${boolChecked} data-prop="${esc(name)}" data-type="${type}">
        <span class="toggle-slider"></span>
      </label>`;
      break;

    case 2: // TYPE_INT
      if (hint === 2 && hint_string) { // PROPERTY_HINT_ENUM
        html += renderEnumSelect(name, type, value, hint_string);
      } else if (hint === 1 && hint_string) { // PROPERTY_HINT_RANGE
        html += renderRangeSlider(name, type, value, hint_string, true);
      } else {
        html += `<input type="number" class="property-input" value="${value ?? 0}" step="1" data-prop="${esc(name)}" data-type="${type}">`;
      }
      break;

    case 3: // TYPE_FLOAT
      if (hint === 1 && hint_string) { // PROPERTY_HINT_RANGE
        html += renderRangeSlider(name, type, value, hint_string, false);
      } else {
        html += `<input type="number" class="property-input" value="${value ?? 0}" step="0.01" data-prop="${esc(name)}" data-type="${type}">`;
      }
      break;

    case 4: // TYPE_STRING
      html += `<input type="text" class="property-input" value="${esc(value || '')}" data-prop="${esc(name)}" data-type="${type}">`;
      break;

    case 5: // TYPE_VECTOR2
      html += renderVector2Input(name, type, value);
      break;

    case 6: // TYPE_VECTOR2I
      html += renderVector2Input(name, type, value, true);
      break;

    case 9: // TYPE_VECTOR3
      html += renderVector3Input(name, type, value);
      break;

    case 10: // TYPE_VECTOR3I
      html += renderVector3Input(name, type, value, true);
      break;

    case 20: // TYPE_COLOR
      html += renderColorInput(name, type, value);
      break;

    case 24: // TYPE_OBJECT (Resource)
      if (value && value.type === 'Resource') {
        html += `<span class="resource-path">${esc(value.path || 'null')}</span>`;
      } else {
        html += `<span class="resource-path">null</span>`;
      }
      break;

    default:
      // Display value as text for unsupported types
      const displayValue = typeof value === 'object' ? JSON.stringify(value) : String(value ?? 'null');
      html += `<span class="property-readonly">${esc(displayValue.substring(0, 50))}${displayValue.length > 50 ? '...' : ''}</span>`;
  }

  html += `</div></div>`;
  return html;
}

function renderEnumSelect(name, type, value, hintString) {
  const options = hintString.split(',').map(opt => {
    const parts = opt.split(':');
    return { value: parts.length > 1 ? parseInt(parts[0]) : opt.trim(), label: parts.length > 1 ? parts[1].trim() : opt.trim() };
  });

  let html = `<select class="property-select" data-prop="${esc(name)}" data-type="${type}">`;
  for (const opt of options) {
    const selected = opt.value === value ? 'selected' : '';
    html += `<option value="${opt.value}" ${selected}>${esc(opt.label)}</option>`;
  }
  html += `</select>`;
  return html;
}

function renderRangeSlider(name, type, value, hintString, isInt) {
  const parts = hintString.split(',');
  const min = parseFloat(parts[0]) || 0;
  const max = parseFloat(parts[1]) || 100;
  const step = parts[2] ? parseFloat(parts[2]) : (isInt ? 1 : 0.01);

  return `<div class="range-input-group">
    <input type="range" class="property-range" value="${value ?? min}" min="${min}" max="${max}" step="${step}" data-prop="${esc(name)}" data-type="${type}">
    <input type="number" class="property-input range-number" value="${value ?? min}" min="${min}" max="${max}" step="${step}" data-prop="${esc(name)}" data-type="${type}">
  </div>`;
}

function renderVector2Input(name, type, value, isInt = false) {
  const x = value?.x ?? 0;
  const y = value?.y ?? 0;
  const step = isInt ? '1' : '0.01';

  return `<div class="vector-input-group" data-prop="${esc(name)}" data-type="${type}">
    <label>x</label><input type="number" class="property-input vec-x" value="${x}" step="${step}" data-component="x">
    <label>y</label><input type="number" class="property-input vec-y" value="${y}" step="${step}" data-component="y">
  </div>`;
}

function renderVector3Input(name, type, value, isInt = false) {
  const x = value?.x ?? 0;
  const y = value?.y ?? 0;
  const z = value?.z ?? 0;
  const step = isInt ? '1' : '0.01';

  return `<div class="vector-input-group vec3" data-prop="${esc(name)}" data-type="${type}">
    <label>x</label><input type="number" class="property-input vec-x" value="${x}" step="${step}" data-component="x">
    <label>y</label><input type="number" class="property-input vec-y" value="${y}" step="${step}" data-component="y">
    <label>z</label><input type="number" class="property-input vec-z" value="${z}" step="${step}" data-component="z">
  </div>`;
}

function renderColorInput(name, type, value) {
  const r = Math.round((value?.r ?? 1) * 255);
  const g = Math.round((value?.g ?? 1) * 255);
  const b = Math.round((value?.b ?? 1) * 255);
  const a = value?.a ?? 1;
  const hex = `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`;

  return `<div class="color-input-group" data-prop="${esc(name)}" data-type="${type}">
    <input type="color" class="property-color" value="${hex}" data-prop="${esc(name)}">
    <input type="number" class="property-input color-alpha" value="${a}" min="0" max="1" step="0.01" placeholder="α" data-component="a">
  </div>`;
}

function initPropertyEditing(scenePath, nodePath) {
  // Boolean toggles
  document.querySelectorAll('.property-row input[type="checkbox"]').forEach(el => {
    el.addEventListener('change', () => {
      const propName = el.dataset.prop;
      const value = el.checked;
      saveSceneNodeProperty(scenePath, nodePath, propName, value, parseInt(el.dataset.type));
    });
  });

  // Number and text inputs
  document.querySelectorAll('.property-row input.property-input:not(.vec-x):not(.vec-y):not(.vec-z):not(.color-alpha):not(.range-number)').forEach(el => {
    el.addEventListener('change', () => {
      const propName = el.dataset.prop;
      const type = parseInt(el.dataset.type);
      let value = el.value;
      if (type === 2 || type === 3) value = parseFloat(value);
      saveSceneNodeProperty(scenePath, nodePath, propName, value, type);
    });
  });

  // Select dropdowns
  document.querySelectorAll('.property-row select.property-select').forEach(el => {
    el.addEventListener('change', () => {
      const propName = el.dataset.prop;
      const type = parseInt(el.dataset.type);
      saveSceneNodeProperty(scenePath, nodePath, propName, parseInt(el.value), type);
    });
  });

  // Range sliders (sync with number input)
  document.querySelectorAll('.range-input-group').forEach(group => {
    const range = group.querySelector('input[type="range"]');
    const number = group.querySelector('input[type="number"]');

    range.addEventListener('input', () => {
      number.value = range.value;
    });
    range.addEventListener('change', () => {
      const propName = range.dataset.prop;
      const type = parseInt(range.dataset.type);
      saveSceneNodeProperty(scenePath, nodePath, propName, parseFloat(range.value), type);
    });
    number.addEventListener('change', () => {
      range.value = number.value;
      const propName = number.dataset.prop;
      const type = parseInt(number.dataset.type);
      saveSceneNodeProperty(scenePath, nodePath, propName, parseFloat(number.value), type);
    });
  });

  // Vector inputs
  document.querySelectorAll('.vector-input-group').forEach(group => {
    const propName = group.dataset.prop;
    const type = parseInt(group.dataset.type);
    const inputs = group.querySelectorAll('input');

    inputs.forEach(input => {
      input.addEventListener('change', () => {
        const x = parseFloat(group.querySelector('.vec-x').value);
        const y = parseFloat(group.querySelector('.vec-y').value);
        const zInput = group.querySelector('.vec-z');
        const value = zInput ? { x, y, z: parseFloat(zInput.value) } : { x, y };
        saveSceneNodeProperty(scenePath, nodePath, propName, value, type);
      });
    });
  });

  // Color inputs
  document.querySelectorAll('.color-input-group').forEach(group => {
    const propName = group.dataset.prop;
    const type = parseInt(group.dataset.type);
    const colorInput = group.querySelector('input[type="color"]');
    const alphaInput = group.querySelector('.color-alpha');

    const saveColor = () => {
      const hex = colorInput.value;
      const r = parseInt(hex.substr(1, 2), 16) / 255;
      const g = parseInt(hex.substr(3, 2), 16) / 255;
      const b = parseInt(hex.substr(5, 2), 16) / 255;
      const a = parseFloat(alphaInput.value);
      saveSceneNodeProperty(scenePath, nodePath, propName, { r, g, b, a }, type);
    };

    colorInput.addEventListener('change', saveColor);
    alphaInput.addEventListener('change', saveColor);
  });
}

async function saveSceneNodeProperty(scenePath, nodePath, propName, value, valueType) {
  console.log(`Saving property: ${propName} =`, value);

  try {
    const result = await sendCommand('set_scene_node_property', {
      scene_path: scenePath,
      node_path: nodePath,
      property_name: propName,
      value: value,
      value_type: valueType
    });

    if (result.ok) {
      console.log(`Property ${propName} saved successfully`);
    } else {
      console.error('Failed to save property:', result.error);
      alert('Failed to save: ' + (result.error || 'Unknown error'));
    }
  } catch (err) {
    console.error('Failed to save property:', err);
    alert('Failed to save: ' + err.message);
  }
}

// Toggle property section visibility
window.togglePropertySection = function(header) {
  const section = header.closest('.property-section');
  section.classList.toggle('collapsed');
};

// Jump to script in scripts view
window.jumpToScript = function(scriptPath) {
  // Switch to scripts view and select the script
  window.switchView('scripts');
  // Find and select the node
  const scriptNode = nodes.find(n => n.path === scriptPath);
  if (scriptNode) {
    setTimeout(() => openPanel(scriptNode), 100);
  }
};

// Jump to scene in scenes view
window.jumpToScene = function(scenePath) {
  // Switch to scenes view and expand the scene
  closePanel();
  window.switchView('scenes');
  // Trigger scene expansion after view switch
  setTimeout(() => {
    window.expandSceneFromPanel && window.expandSceneFromPanel(scenePath);
  }, 100);
};
