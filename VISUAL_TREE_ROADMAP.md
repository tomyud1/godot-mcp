# Visual Tree Roadmap

## Completed
- [x] Inline variable/signal editing
- [x] @onready toggle
- [x] Function code editing with syntax highlighting
- [x] Usage detection before delete
- [x] Floating usage panel with navigation
- [x] Right-click context menu
- [x] New script creation
- [x] Draggable/resizable panels
- [x] Scene View tab (Phase 4 - Core)
  - Scene overview with cards showing scene info
  - Click scene → expand to full node hierarchy tree
  - Visual node tree with parent-child connections
  - Sibling order indicators (for 2D draw order)
  - Click node → dynamic properties panel
  - Inline editing of all node properties
  - Property controls: toggles, sliders, vectors, colors, enums
  - Back navigation to scene overview

## In Progress
- [ ] Function deletion with usage check

## Planned

### Phase 2: Visual Connections
- Drag from signal → function to create `.connect()` code
- Visual ports on node edges when hovering

### Phase 3: Script Management
- Right click to add a new node (script)
- Script templates (Node2D, State Machine, Singleton, etc.)
- Delete/rename scripts

### Phase 4: Scene View (Enhancements)
- Drag to reorder siblings (change draw order)
- Right-click context menu on scene nodes (add child, delete, rename)
- Drag scripts onto scene nodes to attach
- Cross-scene signal visualization

### Phase 5: Advanced
- Minimap
- Node grouping
- Full-text search in function bodies
- Refactoring (rename across files)
- Undo/redo
- Git integration (modified files indicator)

### Phase 6: Polish
- Documentation generation
- Dependency analysis (circular deps, unused scripts)
- Code snippets library
