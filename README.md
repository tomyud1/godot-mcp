# Godot MCP

**Give your AI assistant full access to the Godot editor.**

Build games faster with Claude, Cursor, or any MCP-compatible AI — no copy-pasting, no context switching. AI reads, writes, and manipulates your scenes, scripts, nodes, and project settings directly.

> Godot 4.x · Scene, script, and project tools · Interactive project visualizer · MIT license

---

## Quick Start

### 0. Install Node.js (one-time setup)

Download and run the installer from **[nodejs.org](https://nodejs.org/en/download)** (LTS version). It's a standard installer — no terminal needed.

### 1. Install the Godot plugin

Inside the Godot editor, click the **AssetLib** tab at the top → search **"mcp"** → find **"Godot AI Assistant tools MCP"** → Install.

Then go to **Project → Project Settings → Plugins** and enable the **Godot MCP** plugin.

### 2. Add the server config to your AI client

**Claude Desktop** — Settings → Developer → Edit Config → open the config file and paste:

Mac / Linux:
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

Windows:
```json
{
  "mcpServers": {
    "godot": {
      "command": "cmd",
      "args": ["/c", "npx", "-y", "godot-mcp-server"]
    }
  }
}
```

**Cursor** — Settings → MCP → Add Server:

Mac / Linux:
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

Windows:
```json
{
  "mcpServers": {
    "godot": {
      "command": "cmd",
      "args": ["/c", "npx", "-y", "godot-mcp-server"]
    }
  }
}
```

**Claude Code** — run in terminal:
```bash
claude mcp add godot -- npx -y godot-mcp-server
```

Works with any MCP-compatible client (Cline, Windsurf, etc.)

### 3. Restart your AI client

Close and reopen Claude Desktop / Cursor / your client so it picks up the new config.

### 4. Restart your Godot project

Hit **Restart Project** in the Godot editor. Check the **top-right corner** — you should see **MCP Connected** in green. You're ready to go.

---

## What Can It Do?

### Tool Registry

| Category | Tools | Examples |
|----------|-------|---------|
| **File Operations** | Registry-defined | Browse directories, read files, search project, create scripts |
| **Scene Operations** | Registry-defined | Create scenes, add/remove/move nodes, set properties, assign meshes/materials, spatial placement, grounding |
| **Editor View + Layout** | Registry-defined | Capture editor viewport screenshots, summarize collision-based room layouts, detect openings |
| **Lighting + Navigation** | Registry-defined | Configure sunlight, inspect light diagnostics, bake navmeshes |
| **Script + Project** | Registry-defined | Edit scripts, validate syntax, run scenes, inspect errors, manage settings/input |
| **Visualization + Assets** | Registry-defined | Project graph visualizer, scene graph explorer, generate 2D sprites |

For the exact current tool list and input schemas, see [docs/tool-catalog.md](./docs/tool-catalog.md).

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

## Working with it: ask for numbers, not pixels

If you're driving this with an agent, the most useful habit is **measuring
before looking**. A screenshot cannot show whether collision worked, whether
the frame rate held, or whether two UI panels overlap — and a full-resolution
frame is expensive in context.

| Instead of a screenshot, use | To answer |
|---|---|
| `probe_ui` | Where every on-screen Control is, exactly, and which ones overlap |
| `probe_camera` | Whether a Node3D is actually in shot, and how far away it is |
| `assert_runtime` | "Did pressing jump actually move the player?" as a pass/fail with evidence |
| `get_runtime_log` / `get_errors` | What actually happened, in words |

These return small JSON, work for agents that can't see images, and give exact
values rather than a picture you'd have to squint at.

`take_screenshot` is still the right call for art, colour, composition, and
animation. It always saves to disk and returns the path; add `return: "image"`
to also get the frame inline as a real image the model can see. Frames are
downscaled to 1568px on the long edge (where vision models clamp anyway) and
oversized PNGs are refused with their path instead of being inlined.

## Before you run the game

`rescan_filesystem` blocks until Godot has finished importing, so **one call is
enough** — it returns `synchronized: true` when your new files are visible to
`run_scene`. It used to return immediately and tell you to retry, which is why
agents used to hammer it dozens of times per session.

---

## Architecture

```
┌─────────────┐    MCP (stdio)   ┌──────────────┐   WebSocket   ┌──────────────┐
│  AI Client  │◄────────────────►│  MCP Server  │◄─────────────►│ Godot Editor │
│  (Claude,   │                  │  (Node.js)   │   port 6505   │  (Plugin)    │
│   Cursor)   │                  │              │               │              │
└─────────────┘                  │  Visualizer  │               │  MCP tools   │
                                 │  HTTP :6510  │               │  handlers    │
                                 └──────┬───────┘               └──────────────┘
                                        │
                                 ┌──────▼───────┐
                                 │   Browser    │
                                 │  Visualizer  │
                                 └──────────────┘
```

---

## Current Limitations

- **Local only** — runs on localhost, no remote connections
- **Single connection** — one Godot instance at a time
- **No undo** — changes save directly (use version control)
- **AI is still limited in Godot knowledge** — it can't create 100% of the game alone, but it can help debug, write scripts, and tag along for the journey

---

## Security

The server listens on three local ports (6505 editor bridge, 6506 proxy API,
6510 visualizer). Any of them can drive the editor, so each is restricted:

| Surface | Protection |
|---------|------------|
| Editor bridge (6505) | Rejects handshakes carrying an `Origin` header. Browsers always send one; Godot's `WebSocketPeer` never does — so a web page cannot drive your editor. No addon update needed. |
| Proxy API (6506) | Requires `Authorization: Bearer <token>`. `/health` stays open so other instances can discover the primary. |
| Visualizer (6510) | Per-session token in the page URL, re-checked on the WebSocket upgrade. Page loads are restricted to loopback origins. |

The token comes from `GODOT_MCP_TOKEN` if set, otherwise a `0600` file at
`~/.godot-mcp/auth-token` created on first run. All instances share it, so
multi-client setups work unchanged. If neither a token nor a writable home
directory is available the server **refuses to start** rather than run open.

Set your own token in CI or containers:

```bash
export GODOT_MCP_TOKEN="$(openssl rand -hex 32)"
```

Agent-supplied file paths are confined to `res://` (and `user://` where it
makes sense); `..` traversal and absolute paths outside the project are
rejected across every tool that takes a path. This is lexical — it does not
resolve symlinks, so a symlink you placed inside the project can still point
outside it.

Screenshots (`take_editor_viewport_screenshot`) accept `res://`, `user://`, and
relative paths by default. Absolute paths require an explicit
`allow_absolute_output: true`, because the tool creates the output directory as
well as writing the file.

`runtime_eval` executes arbitrary GDScript in the running game and requires an
explicit `confirm: true`, as does `delete_file`.

## Tests

```bash
cd mcp-server
npm test              # server-side: auth, result shaping, annotations, parity
npm run check:parity  # TS registry vs Godot handler table vs guides
npm run verify        # build + parity + tests
```

The GDScript checks run headlessly. `project.godot` in the repo root exists
solely to give them a project to run in — it is not a game:

```bash
godot --headless --import

# plain MainLoop — no editor
godot --headless --script addons/godot_mcp/utils/test_parse.gd        # every script parses
godot --headless --script addons/godot_mcp/utils/test_paths.gd        # confine() rules
godot --headless --script addons/godot_mcp/utils/test_tool_paths.gd   # tools actually gate
godot --headless --script addons/godot_mcp/runtime/test_probes.gd     # probes and assertions

# loads the plugin for real, in an editor
GODOT_MCP_SELFTEST=1 godot --headless --editor --quit-after 2500
```

All of the above run in CI on every push.

### Why the editor check exists

The `--script` checks run as a plain `MainLoop` and never load the
`EditorPlugin`. That misses everything only the editor provides:
`EditorPlugin` wiring, `EditorInterface` / `EditorFileSystem`, and `@tool`
coroutines awaiting `process_frame`.

A duplicate `var _gate` in `scene_tools.gd` passed every headless check and
only broke when the editor compiled the plugin — which would have shipped a
non-loading addon. The editor self-test is what catches that class of problem.

### Two traps that have bitten this repo

**`load()` does not tell you a script failed to parse.** It returns a non-null
`GDScript` for an unparseable file, so a check written as
`if load(path) == null` reports success on a file that does not compile. Use
`script.reload()` (returns `ERR_PARSE_ERROR`) or `can_instantiate()`.

**Exit codes.** `godot --headless` reports failure only through its exit code,
and two things silently swallow it — returning `true` from `_process` before
`quit(code)` applies, and a bare `quit()` which resets the code to `0`. One of
the check scripts also had a stale copy of its failure counter that made it
structurally incapable of failing. If you add a check, confirm it exits
non-zero by deliberately breaking an assertion.

A long comment header in `project.godot` has been observed to stop the editor
enabling plugins, which silently disables the editor self-test. Keep that file
minimal.


---

## Development

To build from source instead of using npm:

```bash
cd mcp-server
npm install
npm run build
```

Then point your AI client at `mcp-server/dist/index.js` instead of using `npx`.
If you add or rename tools, update both the TypeScript tool definitions and the Godot plugin handlers, then rerun `npm run build` and restart the MCP client so the refreshed tool list is advertised.

---

## Release notes

Narrative write-ups of each release live in [`release-notes/`](./release-notes/) (starting with [v0.5.0](./release-notes/v0.5.0.md)). For the full change history, see [`CHANGELOG.md`](./CHANGELOG.md).

---

## License

MIT

---

**[npm package](https://www.npmjs.com/package/godot-mcp-server)** · **[Report Issues](https://github.com/tomyud1/godot-mcp/issues)**
