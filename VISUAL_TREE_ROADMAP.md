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

## In Progress
- [ ] Function deletion with usage check
- [ ] Scene view tab

## Planned

### Phase 2: Visual Connections
- Drag from signal → function to create `.connect()` code
- Visual ports on node edges when hovering

### Phase 3: Script Management
- Right click to add a new node (script)
- Script templates (Node2D, State Machine, Singleton, etc.)
- Delete/rename scripts

### Phase 4: Scene View
- Separate "Scenes" tab
- Scene nodes showing hierarchy
- Click scene → dim unrelated, show connected scripts
- Breadcrumb navigation

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
