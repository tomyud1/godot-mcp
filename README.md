# Godot MCP

**Give your AI assistant full access to the Godot editor.**

Build games faster with Claude, Cursor, or any MCP-compatible AI — no copy-pasting, no context switching. AI reads, writes, and manipulates your scenes, scripts, nodes, and project settings directly.

> Godot 4.x · 32 tools · Interactive project visualizer · MIT license

---

## Quick Start

### 1. Add the MCP server to your AI client

The server is hosted on npm — no cloning or building required.

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

Works with any MCP-compatible client.

### 2. Install the Godot plugin

Copy the `addons/godot_mcp/` folder into your Godot project's `addons/` directory. Then enable it: Project → Project Settings → Plugins → **Godot MCP** → Enable.

Or install directly from the **Godot Asset Library**: AssetLib → search "Godot MCP" → Install.

### 3. Restart Project

Check the **top-right corner** of the editor. You should see **MCP Connected** in green. You're ready to go — start talking to your AI about your game.

---

## What Can It Do?

### 32 Tools Across 6 Categories

| Category | Tools | Examples |
|----------|-------|---------|
| **File Operations** | 4 | Browse directories, read files, search project, create scripts |
| **Scene Operations** | 11 | Create scenes, add/remove/move nodes, set properties, attach scripts, assign collision shapes and textures |
| **Script Operations** | 6 | Apply code edits, validate syntax, rename/move files with reference updates |
| **Project Tools** | 9 | Read project settings, input map, collision layers, console errors, scene tree dumps |
| **Asset Generation** | 1 | Generate 2D sprites from SVG |
| **Visualization** | 1 | Interactive browser-based project map |

### Interactive Visualizer

Run `map_project` and get a browser-based explorer at `localhost:6510`:
- Force-directed graph of all scripts and their relationships
- Click any script to see variables, functions, signals, and connections
- Edit code directly in the visualizer — changes sync to Godot in real time
- Scene view with node property editing
- Find usages before refactoring
<img width="1710" height="1107" alt="image" src="https://github.com/user-attachments/assets/a9faf163-8b8b-43da-93ec-c7a651e8ac60" />

### LIMITATIONS

AI cannot create 100% of the game by iteself.
- It struggles with creating UI elements, manipulating node properties, create and compositing scenes.
- Its still in a testing phase, so I will appreciate any feedback!

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

- **Local only** — runs on localhost, no remote connections
- **Single connection** — one Godot instance at a time
- **No undo** — changes save directly (use version control)
- **No runtime control** — can't press play or simulate input
- **AI is still limited in Godot knowledge** — it can't create 100% of the game alone, but it can help debug, write scripts, and tag along for the journey

---

## Full Documentation

See [SUMMARY.md](SUMMARY.md) for the complete tool reference, feature list, and detailed pain point analysis.

---

## Development

To build from source instead of using npm:

```bash
cd mcp-server
npm install
npm run build
```

Then point your AI client at `mcp-server/dist/index.js` instead of using `npx`.

---

## License

MIT

---

**[npm package](https://www.npmjs.com/package/godot-mcp-server)** · **[Report Issues](https://github.com/tomyud1/godot-mcp/issues)**
