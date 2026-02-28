# Godot MCP

**Give your AI assistant full access to the Godot editor.**

Build games faster with Claude, Cursor, or any MCP-compatible AI — no copy-pasting, no context switching. AI reads, writes, and manipulates your scenes, scripts, nodes, and project settings directly.

> Godot 4.x · 32 tools · Interactive project visualizer · MIT license

---

## Quick Start

### 1. Install the Godot plugin

Inside the Godot editor, click the **AssetLib** tab at the top → search **"mcp"** → find **"Godot AI Assistant tools MCP"** → Install.

That's it — no manual file copying needed.

### 2. Install the MCP server

**Option A: Pre-built binary (recommended, no runtime needed)**

Download the binary for your platform from [GitHub Releases](https://github.com/tomyud1/godot-mcp/releases) and place it somewhere on your PATH (e.g., `~/.local/bin/` on Linux/macOS).

**Option B: Via npm (requires Node.js)**

Install [Node.js](https://nodejs.org/en/download) (LTS version), then use `npx` in the config below — it downloads the server automatically.

### 3. Add the server config to your AI client

**Using the pre-built binary:**

**Claude Desktop** — Settings → Developer → Edit Config:
```json
{
  "mcpServers": {
    "godot": {
      "command": "godot-mcp-server"
    }
  }
}
```

**Claude Code** — run in terminal:
```bash
claude mcp add godot godot-mcp-server
```

**Using npm:**

**Claude Desktop** / **Cursor** — Settings → Developer → Edit Config:
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

**Claude Code** — run in terminal:
```bash
claude mcp add godot -- npx -y godot-mcp-server
```

Works with any MCP-compatible client (Cline, Windsurf, Cursor, etc.)

### 4. Restart your AI client

Close and reopen Claude Desktop / Cursor / your client so it picks up the new config.

### 5. Restart your Godot project

Hit **Restart Project** in the Godot editor. Check the **top-right corner** — you should see **MCP Connected** in green. You're ready to go.

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

### Limitations

AI cannot create 100% of a game by itself — it struggles with complex UI layouts, compositing scenes, and some node property manipulation. It's still in active development, so feedback is very welcome!

---

## Architecture

```
┌─────────────┐    MCP (stdio)    ┌─────────────┐   WebSocket    ┌──────────────┐
│  AI Client   │◄────────────────►│  MCP Server  │◄─────────────►│ Godot Editor │
│  (Claude,    │                  │  (Go binary  │   port 6505   │  (Plugin)    │
│   Cursor)    │                  │   or Node)   │               │              │
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

## Development

**Go server (recommended):**
```bash
cd mcp-server-go
make build
```
Binary is at `mcp-server-go/bin/godot-mcp-server`. Cross-compile for all platforms with `make build-all`.

**Node.js server:**
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
