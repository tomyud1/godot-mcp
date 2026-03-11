# Changelog

## [0.2.7] - 2026-03-11

### Fixed
- **Zombie server port conflicts** — the server now auto-kills any existing process on port 6505 before starting; MCP clients (Claude Desktop, Cursor) often leave old server processes alive when restarting, which silently blocked the new instance from binding
- **EADDRINUSE error now loud and clear** — instead of silently falling back, the server logs an actionable error message explaining exactly what happened and how to fix it

### Removed
- **Mock mode** — tools no longer return fake data when Godot isn't connected; they return a clear error with instructions to connect

### Changed
- **Pinned `@modelcontextprotocol/sdk` to `~1.25.2`** — version 1.27.x introduced stdio transport instability for npx users
- **Faster Godot plugin reconnect** — backoff reduced from 3–30s to 2–10s

## [0.2.6] - 2026-03-08

### Added
- **`list_settings` tool** — browse project settings by category; returns current values, types, and valid options (enums, ranges)
- **`update_project_settings` tool** — write project settings by path; tool description guides the AI to use `list_settings` first
- **`configure_input_map` tool** — add, remove, or replace input actions and key/button bindings with live editor UI refresh
- **`setup_autoload` tool** — register, unregister, or list autoload singletons

### Fixed
- **Input Map editor refreshes live** — calls the editor's internal `_update_action_map_editor()` after changes so the Project Settings UI stays in sync

## [0.2.5] - 2026-03-06

### Changed
- **StringName dictionary keys** across all GDScript files — avoids per-frame string allocations for dictionary lookups
- **Typed for loops** — explicit type annotations on loop variables throughout all tool files
- **Bulk file read in `search_project`** — reads whole file and does a quick `find()` before line-by-line scanning, skipping non-matching files entirely
- **`_SKIP_EXTENSIONS` Dictionary** — O(1) extension filtering in `_collect_files_recursive` (was O(n) array scan)
- **`_SKIP_PROPS` Dictionary** — O(1) property filtering in `get_node_properties` and `get_scene_node_properties`
- **`PackedStringArray`** for `list_dir` results, `_collect_files`, and `_dump_node` tree building
- **`MAX_TRAVERSAL_DEPTH` guard** — prevents runaway recursion in `_collect_files_recursive` (cap at 20 levels)
- **`MAX_PACKETS_PER_FRAME` cap** — limits WebSocket packet processing to 32 per frame to prevent editor stalls
- **`127.0.0.1` instead of `localhost`** — avoids DNS lookup on every connection attempt
- **`_parse_value` improvement** — uses `value is Dictionary` instead of `typeof()` check, single `.get()` for type field

### Fixed
- **`SERVER_VERSION` constant** now matches `package.json` (was stuck at `0.2.0`)

## [0.2.4] - 2026-02-23

### Changed
- **Published to official MCP registry** — `godot-mcp-server` is now listed at `registry.modelcontextprotocol.io` as `io.github.tomyud1/godot-mcp`
- **Updated npm README** — fully reflects current features, tools, visualizer screenshot, and npx-based install
- **Added `server.json`** — MCP registry manifest for automated discovery
- **Updated `package.json`** — added `mcpName` and `repository` fields required by the MCP registry

## [0.2.3] - 2026-02-23

### Changed
- Minor package metadata update (intermediate release during registry setup)

## [0.2.2] - 2026-02-23

### Fixed
- **`create_scene` schema now valid for strict MCP clients** — added missing `items` field to the `nodes` array property, fixing Windsurf/Cascade rejecting the tool with "array schema missing items"

## [0.2.1] - 2026-02-17

### Changed
- **Moved plugin to repo root** — `addons/godot_mcp/` is now at the repo root instead of nested under `godot-plugin/`, matching the Godot Asset Library expected layout
- **Added `.gitattributes`** — Asset Library downloads now only include the `addons/` folder
- **Updated install instructions** — README and SUMMARY reflect the new path

## [0.2.0] - 2026-02-11

### Fixed
- **Console log and error tools now work reliably** — reads directly from the editor's Output panel instead of the buffered log file on disk, which was returning stale/incomplete data
- **`get_errors` returns newest errors first** — previously returned oldest errors from the start of the log
- **`get_errors` uses proper Godot error patterns** — matches `ERROR:`, `SCRIPT ERROR:`, `WARNING:`, etc. instead of naively matching any line containing the word "error"
- **`clear_console_log` actually clears the Output panel** — previously was a no-op that returned a fake "acknowledged" message
- **`validate_script` bypasses resource cache** — creates a fresh GDScript instance from the file on disk so edits are validated correctly, not stale cached versions
- **`validate_script` returns actual error details** — extracts parse errors from the Output panel instead of just saying "check Godot console"

### Changed
- **Renamed `apply_diff_preview` to `edit_script`** — clearer name for the code editing tool
- **`scene_tree_dump` description corrected** — now accurately says it dumps the scene open in the editor, not a "running" scene
- **Removed dead code** — cleaned up unused `_console_buffer` and `MAX_CONSOLE_LINES`

### Removed
- **Removed `search_comfyui_nodes` tool** — was a non-functional stub that cluttered the tool list
- **Hidden RunningHub tools from MCP** — `inspect_runninghub_workflow` and `customize_and_run_workflow` are not exposed until properly documented (GDScript implementations preserved)

## [0.1.0] - 2025-01-28

### Added
- Initial release
- 32 MCP tools across 6 categories
- Godot editor plugin with WebSocket bridge
- Interactive browser-based project visualizer
