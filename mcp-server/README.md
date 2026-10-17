# Godot MCP Server

**Give your AI assistant full access to the Godot editor.**

Build games faster with Claude, Cursor, or any MCP-compatible AI — no copy-pasting, no context switching. The AI reads, writes, and manipulates your scenes, scripts, nodes, and project settings directly inside the running Godot editor.

> Godot 4.4+ · 69 tools · Undo/redo · Interactive project visualizer · MIT license

---

## Quick Start

### 0. Install Node.js (one-time setup)

Download and run the installer from **[nodejs.org](https://nodejs.org/en/download)** (LTS version). It's a standard installer — no terminal needed.

### 1. Install the Godot plugin

No cloning or building required — runs directly via npx.

**Claude Desktop** — edit `~/Library/Application Support/Claude/claude_desktop_config.json`:
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

**Cursor** — add to MCP settings (Settings → MCP → Add Server):
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

Works with any MCP-compatible client (Claude Code, Cline, Windsurf, etc.)

### 2. Install the Godot plugin

Copy the `addons/godot_mcp/` folder from the [GitHub repo](https://github.com/tomyud1/godot-mcp) into your Godot project's `addons/` directory. Then enable it: **Project → Project Settings → Plugins → Godot MCP → Enable**.

Or install it from inside the Godot editor: the **Asset Store** tab (Godot 4.7+, search "[Godlink MCP](https://store.godotengine.org/asset/tomer-yud/godlink/)") or the **AssetLib** tab (Godot 4.6 and older, search "mcp") → Install.

### 3. Connect

Restart your Godot project. Check the **top-right corner** of the editor — you should see **MCP: Agent Active** in green. You're ready to go.

---

## What Can It Do?

### 32 Tools Across 6 Categories

| Category | Tools | Examples |
|---|---|---|
| **File Operations** | 4 | Browse directories, read files, search project, create scripts |
| **Scene Operations** | 11 | Create scenes, add/remove/move nodes, set properties, attach scripts, assign collision shapes and textures |
| **Script Operations** | 6 | Apply code edits, validate syntax, rename/move files with reference updates |
| **Project Tools** | 9 | Read project settings, input map, collision layers, console errors, scene tree dumps |
| **Asset Generation** | 1 | Generate 2D sprites from SVG |
| **Visualization** | 1 | Interactive browser-based project map |

### Interactive Visualizer

Run `map_project` and get a browser-based project explorer at `localhost:6510`:

- Force-directed graph of all scripts and their relationships
- Click any script to see variables, functions, signals, and connections
- Edit code directly in the visualizer — changes sync to Godot in real time
- Scene view with node property editing
- Find usages before refactoring

![Godot MCP Visualizer](https://github.com/user-attachments/assets/a9faf163-8b8b-43da-93ec-c7a651e8ac60)

---

## How It Works

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

The MCP server connects to the Godot editor via WebSocket through the Godot plugin. The AI never guesses at your project structure — it reads live state directly from the running editor.

---

## Current Limitations

- **Local only** — runs on localhost, no remote connections
- **One Godot editor at a time** — multiple AI clients can connect concurrently, but they all share a single Godot instance
- **Ctrl+Z does not reach AI changes** — the plugin writes to disk rather than the editor's live tree, so Godot's native undo has nothing to revert. Use the `mcp_undo` tool instead (ask the agent to undo).
- **AI has limited Godot knowledge** — it can help debug, write scripts, and build scenes, but can't create a complete game without guidance

---

## Build From Source

```bash
git clone https://github.com/tomyud1/godot-mcp
cd godot-mcp/mcp-server
npm install
npm run build
```

Then point your AI client at `mcp-server/dist/index.js` instead of using `npx`.

---

## License

MIT

---

**[GitHub](https://github.com/tomyud1/godot-mcp)** · **[Report Issues](https://github.com/tomyud1/godot-mcp/issues)**
