# Godot MCP — AI-Powered Godot Development

**Give your AI assistant full access to the Godot editor.** Build games faster with Claude, Cursor, or any MCP-compatible AI — no copy-pasting, no context switching, no friction.

> Works with Godot 4.x · Open source (MIT) · 32 tools · Visual project explorer included

---

## What Is This?

Godot MCP is a bridge between AI assistants and the Godot editor. It lets AI read, write, and manipulate your project directly — scenes, scripts, nodes, assets, settings — all through natural conversation.

```
You ↔ AI Assistant ↔ MCP Server ↔ Godot Editor
         (Claude, Cursor, etc.)    (WebSocket)     (Plugin)
```

Install the Godot plugin, point your AI client at the MCP server, and start building.

---

## Tools (32)

### File Operations (4 tools)
| Tool | What it does |
|------|-------------|
| `list_dir` | Browse project directories (`res://` paths) |
| `read_file` | Read any text file with optional line ranges |
| `search_project` | Full-text search across the project with glob filtering |
| `create_script` | Scaffold new GDScript files |

### Scene Operations (11 tools)
| Tool | What it does |
|------|-------------|
| `create_scene` | Create `.tscn` files with a node hierarchy |
| `read_scene` | Parse and inspect scene structure |
| `add_node` | Add nodes to existing scenes |
| `remove_node` | Remove nodes from scenes |
| `modify_node_property` | Set any node property (transforms, colors, physics, etc.) |
| `rename_node` | Rename nodes |
| `move_node` | Reparent nodes in the scene tree |
| `attach_script` | Attach a GDScript to a node |
| `detach_script` | Remove a script from a node |
| `set_collision_shape` | Assign collision shapes (Circle, Rectangle, Capsule, etc.) |
| `set_sprite_texture` | Assign textures to sprites (image, placeholder, gradient, noise) |

### Script Operations (6 tools)
| Tool | What it does |
|------|-------------|
| `apply_diff_preview` | Apply targeted code edits to GDScript files |
| `validate_script` | Check GDScript syntax without running |
| `list_scripts` | List all `.gd` files in the project |
| `create_folder` | Create directories |
| `delete_file` | Delete files (with safety checks) |
| `rename_file` | Rename/move files with optional reference updates |

### Project Tools (9 tools)
| Tool | What it does |
|------|-------------|
| `get_project_settings` | Read project configuration (window size, renderer, physics) |
| `get_input_map` | Inspect all input actions and their bindings |
| `get_collision_layers` | Read physics collision layer names |
| `get_node_properties` | Discover every property a node type supports |
| `get_console_log` | Read the editor output log |
| `get_errors` | Extract only errors from the console |
| `clear_console_log` | Clear the console |
| `open_in_godot` | Open a file in the editor (jumps to line for scripts) |
| `scene_tree_dump` | Dump the running scene tree for debugging |

### Asset Generation (4 tools)
| Tool | What it does |
|------|-------------|
| `generate_2d_asset` | Generate 2D sprites from SVG code |
| `search_comfyui_nodes` | Search 10,500+ ComfyUI nodes for AI art pipelines |
| `inspect_runninghub_workflow` | Inspect RunningHub workflow parameters |
| `customize_and_run_workflow` | Execute RunningHub workflows for asset generation |

### Visualization (1 tool)
| Tool | What it does |
|------|-------------|
| `map_project` | Build an interactive visual map of your entire project |

---

## Features

### Core
- **Live editor connection** — WebSocket bridge between MCP server and Godot editor. Changes happen in real time.
- **Works with any MCP client** — Claude Desktop, Cursor, RAGy, or anything that speaks MCP.
- **Mock mode** — Test and develop without Godot running.
- **Auto-reconnect** — Plugin reconnects automatically if the connection drops.

### Scene Manipulation
- Create scenes from scratch with full node hierarchies
- Add, remove, rename, move, and reparent nodes
- Set any node property with automatic type parsing (Vector2, Color, etc.)
- Attach/detach scripts, assign collision shapes and textures
- Read and inspect existing scene structures

### Script Intelligence
- Apply surgical code edits with snippet matching
- Validate GDScript syntax before saving
- Full project-wide text search
- Scaffold new scripts from templates
- Rename/move files with reference tracking

### Project Awareness
- AI can read your project settings, input map, and collision layers
- Console log and error access for debugging
- Scene tree dumps of the running game
- Property discovery — AI can look up what properties any node type supports

### Asset Pipeline
- Generate 2D placeholder sprites from SVG descriptions
- ComfyUI node search for AI art workflow building
- RunningHub integration for automated asset generation

### Interactive Visualizer
- **Browser-based project explorer** served at `localhost:6510`
- Force-directed graph of all scripts and their relationships
- Color-coded by folder, searchable, zoomable
- Click any script to inspect variables, functions, signals, and connections
- **Inline editing** — edit variables, function bodies, and signals directly in the visualizer
- **Scene view** — browse scene hierarchies and edit node properties
- **Find usages** — check where a function or variable is used before changing it
- Changes sync back to Godot in real time

---

## Godot Developer Pain Points

| Pain Point | Status | How |
|-----------|--------|-----|
| **"AI can't see my project"** — context switching between AI chat and editor | **Solved** | AI reads/writes your project directly through 32 tools |
| **"Scene files are unreadable"** — `.tscn` is a custom text format AI struggles with | **Solved** | Structured scene tools abstract away the format |
| **"I have to copy-paste code back and forth"** — manual AI workflow | **Solved** | AI edits scripts in-place, validates syntax, and opens files in editor |
| **"I don't know what properties a node has"** — memorizing the API | **Solved** | `get_node_properties` lets AI discover any node's full property list |
| **"Debugging is slow"** — checking console, finding errors | **Solved** | AI reads console logs, extracts errors, dumps the scene tree |
| **"I can't visualize my project structure"** — hard to see the big picture | **Solved** | Interactive visualizer maps scripts, scenes, and their connections |
| **"Setting up input maps / collision layers is tedious"** | **Solved** | AI reads and understands your input map and collision layers |
| **"I need placeholder art to prototype"** | **Solved** | SVG-based 2D asset generation, ComfyUI/RunningHub integration |
| **"Refactoring is scary"** — renaming breaks things | **Partially solved** | File rename with reference updates + find usages in visualizer |
| **"GDScript has no LSP-quality AI support"** | **Partially solved** | Syntax validation + property discovery, but no autocomplete or go-to-definition |
| **"AI generates code for the wrong Godot version"** | **Partially solved** | AI sees your actual project settings and node types, reducing hallucination |
| **"I need AI to playtest / run my game"** | **Not yet** | Scene tree dump works, but no automated play/test/input simulation |
| **"Shader editing is painful"** | **Not yet** | No shader-specific tools (files can be read/written as text) |
| **"Managing exports and builds"** | **Not yet** | No export/build pipeline tools |
| **"Tilemap and level design"** | **Not yet** | No tilemap-specific tools |
| **"Animation editing"** | **Not yet** | No AnimationPlayer/AnimationTree tools |
| **"Version control integration"** | **Not yet** | No built-in git tools (use your AI client's native git support) |
| **"Multi-file refactoring"** | **Not yet** | Single-file edits only; no cross-file rename symbol |

---

## Quick Start

**1. Add the MCP server to your AI client**

No installation needed — the server is on npm. Add to your AI client config:
```json
{
  "mcpServers": {
    "godot": {
      "command": "npx",
      "args": ["-y", "godot-mcp-server"]
    }
  }
}
```

**2. Install the Godot plugin**
Copy `godot-plugin/addons/godot_mcp/` into your project's `addons/` folder. Enable it in Project → Project Settings → Plugins.

**3. Restart Godot.** Check the top-right corner of the editor — you should see **MCP Connected** in green. You're ready to go.

---

## Architecture

```
┌─────────────┐    MCP (stdio)    ┌─────────────┐   WebSocket    ┌──────────────┐
│  AI Client   │◄────────────────►│  MCP Server  │◄─────────────►│ Godot Editor │
│  (Claude,    │                  │  (Node.js)   │   port 6505   │  (Plugin)    │
│   Cursor)    │                  │              │               │              │
└─────────────┘                  │  Visualizer  │               │  32 tool     │
                                 │  HTTP :6510  │               │  handlers    │
                                 └──────┬───────┘               └──────────────┘
                                        │
                                 ┌──────▼───────┐
                                 │   Browser     │
                                 │  Visualizer   │
                                 └──────────────┘
```

---

## Current Limitations

- **Local only** — WebSocket runs on localhost, no remote connections or auth
- **Single connection** — One Godot instance at a time
- **Editor only** — Plugin runs in `@tool` mode, not in exported games
- **No undo** — Changes are saved directly (use version control)
- **Regex-based parsing** — Script analysis may miss edge cases in complex GDScript
- **No runtime control** — Can't press play, simulate input, or automate testing
- **All AI is limited in Godot knowledge** - scene editing, GDScript, editing node properties, building and placing UI elements. It cant create 100% of the game alone but it can help debug, write scripts, and tag along for the journey :)
---

## What's Next (maybe)

- Animation tools (AnimationPlayer, tweens)
- Tilemap and level design tools  
- Shader editing support
- Automated playtesting and input simulation
- Multi-file refactoring
- Plugin marketplace / asset library integration
- improvements to current tools

---

## License

MIT — use it however you want.

**[GitHub](https://github.com/tomyud1/godot-mcp)** · **[npm](https://www.npmjs.com/package/godot-mcp-server)** · **[Report Issues](https://github.com/tomyud1/godot-mcp/issues)**
