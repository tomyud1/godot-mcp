# Changelog

## [0.5.0] - 2026-04-19

See [`release-notes/v0.5.0.md`](./release-notes/v0.5.0.md) for the narrative write-up.

### Added
- **Runtime helper autoload (`MCPRuntime`)** — the plugin now auto-registers a tiny autoload when enabled, which connects to the MCP server from INSIDE the running game and exposes runtime-only tools. Removed when the plugin is disabled. Non-MCP autoloads registered by the user are never touched.
- **`take_screenshot` tool** — capture a PNG of the viewport of the running game (not the editor). Saved under `res://addons/godot_mcp/cache/screenshots/` so it survives project renames; returns `resource_path`, `absolute_path`, and dimensions.
- **`send_input` tool** — synthesize a mouse button, mouse motion, key, or named InputMap action event into the running game, letting the agent drive UIs and gameplay directly.
- **`query_runtime_node` tool** — read arbitrary property values from a live node in the running game by node path, with optional globals (`visible_global_position`, `global_transform`, etc.).
- **`get_runtime_log` tool** — pull the most recent entries from the runtime's internal ring buffer; complements `get_console_log` / `get_errors` which read the editor's output.
- **`wait` tool** — editor-side sleep (`ms` or `seconds`) so the agent can pause between a state change and a follow-up check without blocking tool channels.
- **`get_runtime_status` tool** — unified status: is the game playing, which scene, uptime, and whether the runtime helper is connected. Complements `is_playing` (kept as a thin compatibility shim).
- **`run_scene` blocking options** — new `block_until_started` (default `true`), `wait_for_runtime`, and `startup_timeout_ms` arguments make `run_scene` a reliable building block for automated test loops.
- **`set_node_properties` tool** — apply many property changes to one node in a single call, with per-property success/failure reporting; cuts round trips for scene setup.
- **`set_node_groups` / `get_node_groups` / `find_nodes_in_group` tools** — manage and query Godot node group memberships directly, persisted into the scene file.
- **`set_resource_property` / `save_resource_to_file` tools** — generic editors for any Resource embedded in a node (e.g., `CircleShape2D.radius`, `StandardMaterial3D.albedo_color`, `AudioStreamPlayer.stream.loop`). Can persist inline resources as `.tres` files.
- **`get_resource_info` tool** — introspect any Resource on disk (textures, meshes, audio streams, packed scenes, materials, animations, shapes). Extends the previous PNG-only inspector.
- **`list_signal_connections` / `connect_signal` / `disconnect_signal` tools** — read and edit persisted signal wiring in `.tscn` files. `list_signal_connections` accepts `source: "scene_file"` or `"runtime"` so the agent can cross-check the editor representation against what's actually wired in the running game.
- **`add_node` now accepts `script`, `groups`, and `children`** — create an entire subtree (with scripts attached and groups assigned) in one call.
- **MCP resources (`godot-mcp://guide/...`)** — short markdown guides served over the MCP resources protocol: `testing-loop`, `scene-editing`, `asset-generation`, `troubleshooting`, and `tool-index`. Tool descriptions stay lean; deeper guidance is opt-in.
- **`get_guide` tool** — exposes the same markdown guides as a plain tool so they work in MCP clients that do not implement `resources/list` / `resources/read` (Claude Desktop, Cursor chat, etc.). Call with no args to list guides, or `{slug: "testing-loop"}` to read one.

### Changed
- **`generate_2d_asset`** — rewritten to render SVG via `Image.load_svg_from_buffer` instead of writing a temp file in `user://`. Removes the silent failure after project rename, eliminates the concurrent-call race on the shared temp path, and fixes the single-quote vs double-quote attribute parser. Added optional `width`, `height`, and `scale` arguments. Error messages now include the underlying Godot error code and the absolute path that failed.
- **`update_project_settings`** — detects `application/config/name` changes, pre-creates the new `user://` directory, and returns a structured warning describing the path change so the agent is not surprised when previously generated files "disappear."
- **`set_sprite_texture`** — `texture_type` now accepts `FromPath` as the canonical name for the load-from-path behavior; `ImageTexture` is kept as a deprecated alias, and a new `NewImageTexture` option forces an in-memory `ImageTexture` when that is actually needed.
- **`delete_file` description** — now clearly documents that `confirm: true` is required, and that a `.bak` backup is written next to the deleted file.
- **Tool descriptions** — trimmed noise across scene/script/project tools; the new MCP resources carry the long-form guidance that used to bloat individual schemas.

### Fixed
- **Project rename silently breaks asset generation and other writes** — renaming the project changes the `user://` resolution, and Godot does not always create the new folder. A new `MCPPaths.ensure_user_dir()` helper is now called from every writer that still touches `user://`, and the MCP plugin's own scratch space has been moved under `res://addons/godot_mcp/cache/` (project-relative, survives renames).
- **`generate_2d_asset` temp-file races** — multiple concurrent calls no longer clobber each other (there is no temp file anymore).
- **`generate_2d_asset` SVG dimension parser** — now accepts single- or double-quoted attributes; intrinsic dimensions are taken from the decoded `Image` when available, with the regex fallback only used for scaling math.
- **`get_godot_status` reported a stale hardcoded version** — the server now reads its version from `package.json` at startup, so `mode`, MCP `serverInfo`, and the status payload always match the actual installed package.
- **`modify_node_property` silently broke `connect_signal` when used to set the `script` property** — it rewrote the `.tscn` on disk but never updated the editor's live in-memory node, so `connect_signal` rejected the connection. The tool now refuses `property_name == "script"` with a clear error pointing to `attach_script`. Both tools' descriptions were updated to mention this constraint.
- **`run_scene` `startup_timeout_ms` was too short on slower machines** — default raised from 6000 to 10000 ms; the schema description recommends bumping further for autoload-heavy projects.
- **`run_scene` did not tell the agent the runtime root path** — the response now includes `scene_path` and `runtime_root` (e.g. `/root/Main`), computed from the actual root node name in the `.tscn`. This is the correct prefix for `query_runtime_node` arguments and removes a common "node not found" footgun where the agent assumed the path was based on the file name.
- **`get_resource_info` only worked for resources already saved to disk** — it now also accepts `{scene_path, node_path, resource_property}` to inspect a Resource that lives on a node (collision shape, material, audio stream, etc.) without requiring a `save_resource_to_file` round trip first.
- **`set_sprite_texture` did not report the resolved texture class** — the response now includes `texture_class`, `texture_path`, `width`, and `height`, so the agent can confirm whether `FromPath` produced a `CompressedTexture2D` vs. `ImageTexture` without an extra inspection call.
- **`wait` only accepted `ms`** — also accepts `seconds` (float). Either is fine; `ms` wins if both are passed.
- **`wait` froze the editor and blew past the transport timeout on large values** — the old implementation used `OS.delay_msec`, which blocks the editor's main thread (and therefore the WebSocket pump). Combined with the MCP server's 30 s per-request timeout, any wait of ~30 s or more caused the server to reject the pending Promise and Godot to write to a disconnected socket, manifesting as a crash / broken session. The tool now yields via `SceneTree.create_timer(...).timeout` instead (non-blocking), and the hard cap was lowered to 20 000 ms so clamped calls still return well under the transport timeout. Responses now also include `requested_ms` when `clamped: true`. The dispatch path in `tool_executor.gd` and `plugin.gd` was made coroutine-aware so the async tool is awaited correctly.
- **`add_node` silently accepted wrong keys inside `children`** — passing `{node_name, node_type}` (the same keys used at the top level) used to fall back to a generic `Node` with the default name. The tool now accepts BOTH `{name, type}` and `{node_name, node_type}` in child specs and rejects any unknown keys with a clear error instead of building a mangled subtree.
- **`connect_signal` did not persist to `.tscn`** — connections were being made with runtime-only flags, so `PackedScene.pack()` stripped them on save. The tool now forces `Object.CONNECT_PERSIST` on every connection and re-reads the saved scene state to verify the `[connection]` entry actually landed. Returns a clear error if the save silently dropped it instead of falsely reporting success.
- **`delete_file` crashed Godot when deleting a scene that was open in the editor** — the previous version only avoided the simplest case. The tool now refuses to delete any file that is open anywhere in the editor (scene tab OR script editor tab), naming which tab holds it and whether it is the active one. A new `force: true` opt-in bypasses the guard (for when you know the tab is safe to drop), but the guard itself now covers the active-scene-tab case that used to crash reliably.
- **Structured error details were dropped on the wire** — every tool that returned a `{ok: false, error, …extra fields}` dict (e.g. `delete_file`'s `open_in_editor` / `where` / `is_active`, `wait`'s `clamped` / `requested_ms`) had those extra fields stripped before the agent ever saw them. `mcp_client.gd` now ships the full result dict on failure too, the bridge attaches it to the rejected error as `details`, and `executeToolCall` merges those details into the visible response. The `ToolResultMessage` type and protocol are unchanged for successful calls.
- **Stale-primary replacement could SIGTERM Godot** — on macOS/Linux, `killProcessOnPort` used `lsof -ti :PORT`, which returns PIDs of *any* process with a socket on that port — including clients. Godot, as the WebSocket client on port 6505, was in that list. When a newer MCP server replaced an older primary (e.g. Claude app starting while Cursor's older server was running), the WebSocket port was killed twice: the first kill took out the old server, and the second kill landed on Godot, reliably crashing the editor. `lsof` is now filtered with `-sTCP:LISTEN` so only listeners are killed. The Windows branch already filtered for `LISTENING`.

### Tests
- **Tool-registry alignment now covers the runtime helper** — the alignment test scans both `tool_executor.gd` and `runtime/mcp_runtime.gd`, so every advertised MCP tool must be implemented in one of the two. A companion test enforces that every name in `RUNTIME_ONLY_TOOLS` lives ONLY in the runtime helper and is not duplicated in the editor map.
- **Bridge tests updated for the editor/runtime split** — the old "second simultaneous connection is rejected" test now sends explicit `godot_ready` hellos, accurately exercising the "reject a second editor" path. A new test verifies that a runtime connection is accepted alongside an existing editor connection.
- **`MANUAL_TEST_PLAN.md`** — 14-section end-to-end checklist for the new features (runtime loop, asset rendering modes, rename safety, resource editing, group and signal tools, MCP resources). Designed to be pasted into a Claude Desktop session wired to the dev MCP.

## [0.4.4] - 2026-04-16

### Fixed
- **`modify_node_property` schema missing `items` on array type** — the `value` parameter's `oneOf` included `{ type: 'array' }` without the `items` field required by strict JSON Schema validators, causing the tool to fail to register in clients like GitHub Copilot ([#44](https://github.com/tomyud1/godot-mcp/issues/44))

## [0.4.3] - 2026-04-14

### Added
- **`set_mesh` tool** — assign primitive meshes (BoxMesh, SphereMesh, CylinderMesh, CapsuleMesh, PlaneMesh, PrismMesh, TorusMesh, QuadMesh, TextMesh) or file-based meshes to MeshInstance3D nodes, making 3D geometry visible from MCP
- **`set_material` tool** — create and assign StandardMaterial3D (albedo, metallic, roughness, emission, transparency) or load materials from file; supports MeshInstance3D, CSG, and GeometryInstance3D nodes
- **`instance_scene` tool** — add scene instances (prefabs) as child nodes with live references to the source `.tscn`, enabling composable scene building from MCP
- **`get_node_spatial_info` tool** — query computed 3D spatial data (local/global transforms, positions, scales, rotation quaternions, subtree bounding boxes) for Node3D nodes
- **`measure_node_distance` tool** — measure world-space 3D distance and horizontal XZ distance between two Node3D nodes
- **`snap_node_to_grid` tool** — snap a Node3D position to a grid in local or global space, with per-axis control
- **VariantCodec** — shared serialization/parsing for Godot variant types, adding support for Quaternion, Basis, Transform3D, and AABB across all tools
- **TS/GDScript alignment test** — test suite now verifies that every MCP tool definition has a matching handler in the Godot plugin executor

### Fixed
- **Stale primary server breaks new tools after updates** — when a new MCP server instance detected an existing primary, it blindly proxied to it even if the primary was running old code. New instances now compare both version and tool count; mismatched primaries are automatically replaced ([#43](https://github.com/tomyud1/godot-mcp/pull/43))
- **`read_scene` root node self-reference** — the root node no longer reports a spurious `instance` field pointing to its own scene file; instance field now only appears on actual child instances
- **`add_node` name reporting** — `add_node` now uses readable names (`add_child(node, true)`) and reports the actual assigned name (which may differ from the requested name if there was a conflict)
- **`set_collision_shape` size parsing** — size parameter now uses the shared `_parse_value` instead of manual dict parsing, supporting the same type inference as other tools
- **`modify_node_property` now supports 3D types** — Quaternion, Basis, Transform3D, and AABB values can now be set via `modify_node_property`, not just vectors and colors
- **Duplicate `_parse_value`/`_serialize_value`** — extracted into shared VariantCodec, eliminating duplicated code between `scene_tools.gd` and `project_tools.gd`
- **Inherited scene instantiation** — `_load_scene` now uses `GEN_EDIT_STATE_MAIN_INHERITED` for inherited scenes and `GEN_EDIT_STATE_INSTANCE` for scene instances, fixing editor-aware PackedScene handling

## [0.4.2] - 2026-04-09

### Added
- **Automated test suite** — 49 tests using Vitest covering GodotBridge (lifecycle, connection management, WebSocket protocol), PrimaryHttpServer (lifecycle, all HTTP endpoints), proxy client (probe, tool forwarding, register/unregister), and tool registry (schema validation, uniqueness). Run with `cd mcp-server && npm test`. ([#37](https://github.com/tomyud1/godot-mcp/issues/37))
- **TESTING.md** — comprehensive test checklist (automated + manual pre-release) at the repo root, designed to be extended over time

### Fixed
- **Zombie process on non-EADDRINUSE startup failure** — if the WebSocket or HTTP server failed to start for a reason other than port conflict (e.g., invalid port, permission error), the process continued running but could never accept connections. Now the server exits with code 1 and a clear error message when the WebSocket server fails to bind. HTTP-only failure logs a warning but continues (direct client still works). Added `isListening()` to both `GodotBridge` and `PrimaryHttpServer` for post-startup health checks. ([#36](https://github.com/tomyud1/godot-mcp/issues/36))
- **`sendClientStatus` type safety** — added `ClientStatusMessage` to the `WebSocketMessage` union type and removed the `as unknown as WebSocketMessage` double cast in `GodotBridge.sendClientStatus()`. The message is now properly type-checked.

## [0.4.1] - 2026-04-04

### Added
- **AI agent connection status in editor toolbar** — the toolbar indicator now distinguishes between three states: `MCP: Connecting...` (yellow, no server), `MCP: No Agent` (orange, server running but no AI client attached), and `MCP: Agent Active` (green, AI client connected). Previously "Connected" showed green even when the server was running with no AI client open. Supports multiple simultaneous agents (`MCP: Agents (N)`).

### Fixed
- **`get_input_map` missing project-defined actions** — custom actions (`jump`, `sprint`, etc.) were never returned because the editor's `InputMap` object only contains built-ins and actions added during the current session; project-defined actions live in `ProjectSettings`. The fix merges both sources so all actions are returned.
- **`get_input_map` incorrect deadzone for project actions** — all actions were returning `0.2` (the built-in default) instead of the actual value from `project.godot`. Deadzones for project-defined actions are now read directly from `ProjectSettings` rather than from the editor's stale `InputMap`.
- **`configure_input_map` deadzone ignored** — deadzone parameter is now correctly applied and persisted to `project.godot`
- **`update_project_settings` corrupted input mappings** — `input/*` keys are now merged with existing settings (preserving the `events` array) instead of overwriting the whole entry; deadzone-only updates no longer wipe key bindings
- **`list_settings` stale data documented** — description now explicitly states that values reflect the editor's in-memory state and direct edits to `project.godot` on disk are not reflected until the editor restarts (`rescan_filesystem` does not help)

## [0.4.0] - 2026-04-01

### Added
- **Multi-session support (connect-or-spawn architecture)** — multiple AI clients (Claude, Cursor, Codex, etc.) can now use Godot tools simultaneously. The first instance becomes the primary server; subsequent instances automatically detect it and enter proxy mode, forwarding tool calls via HTTP. Zero configuration change — same stdio setup as before. ([#24](https://github.com/tomyud1/godot-mcp/issues/24))
- **HTTP bridge for proxy communication** — primary server exposes a lightweight HTTP API on port 6506 (configurable via `GODOT_MCP_HTTP_PORT`) with health check and tool forwarding endpoints
- **`GODOT_MCP_HTTP_PORT` env var** — configure the HTTP bridge port (default: 6506)
- **`GODOT_MCP_IDLE_TIMEOUT_MS` env var** — configure how long the primary server stays alive after all clients and Godot disconnect (default: 30000ms)

### Fixed
- **"Transport closed" on Windows/Codex** — primary mode no longer exits when stdin closes; the server stays alive for proxy clients and Godot, only shutting down after an idle timeout when all connections are gone ([#16](https://github.com/tomyud1/godot-mcp/issues/16))
- **Cross-platform `killProcessOnPort`** — replaced `execSync('sleep 1')` with async `setTimeout`, fixing the missing post-kill delay on Windows that caused `EADDRINUSE` race conditions
- **Smarter zombie detection** — the server now probes for a healthy primary before killing anything on the port; only genuinely unresponsive processes get terminated, preventing one AI session from killing another's server
- **Startup race condition** — when two instances start simultaneously and both try to become primary, the loser re-probes and falls back to proxy mode instead of killing the winner

## [0.3.0] - 2026-03-31

### Added
- **`classdb_query` tool** — query Godot's ClassDB for class properties, methods, signals, and inheritance; lets the AI verify real API signatures before writing code instead of guessing from training data (suggested by [@elfensky](https://github.com/elfensky), [#19](https://github.com/tomyud1/godot-mcp/issues/19))
- **`run_scene` / `stop_scene` / `is_playing` tools** — run, stop, and check scene status from the AI, enabling autonomous edit→run→debug loops without user intervention (suggested by [@elfensky](https://github.com/elfensky), [#18](https://github.com/tomyud1/godot-mcp/issues/18))
- **Configurable timeout and port** — `GODOT_MCP_TIMEOUT_MS` and `GODOT_MCP_PORT` environment variables to override the 30s tool timeout and 6505 WebSocket port (suggested by [@elfensky](https://github.com/elfensky), [#20](https://github.com/tomyud1/godot-mcp/issues/20))
- **`rescan_filesystem` tool** — trigger a full filesystem rescan from the AI after creating or modifying files externally
- **Tool description cross-references** — `get_errors`, `edit_script`, and `create_script` descriptions now guide the AI to use `classdb_query` for API verification and `run_scene` for testing after changes

### Improved
- **`get_errors` now reads both sources** — reads the Output panel *and* the Debugger > Errors tab in a single call, returning runtime errors with stack traces that were previously invisible; each error includes a `source` field (`"output"` or `"debugger"`) (debugger scraping based on [@byronhulcher](https://github.com/byronhulcher)'s approach, [PR #15](https://github.com/tomyud1/godot-mcp/pull/15))
- **Tool executor null guard** — tools that crash at runtime now return a clear error instead of silently timing out (based on [@elfensky](https://github.com/elfensky)'s approach, [PR #22](https://github.com/tomyud1/godot-mcp/pull/22))

### Fixed
- **WebSocket buffer sizes increased** — outbound buffer raised to 4 MB, inbound to 1 MB; fixes `map_project` and other large responses being silently dropped on non-trivial projects (reported by [@rconlan](https://github.com/rconlan), [#14](https://github.com/tomyud1/godot-mcp/issues/14))
- **WebSocket server binds to IPv4** — explicitly binds to `127.0.0.1` instead of letting the `ws` library default to `::` (IPv6); fixes silent connection failures on systems without IPv6 dual-stack (reported by [@elfensky](https://github.com/elfensky), [#17](https://github.com/tomyud1/godot-mcp/issues/17))
- **WebSocket reconnection fix** — creates a fresh `WebSocketPeer` on every reconnect attempt instead of reusing a closed peer that can get stuck in `STATE_CONNECTING` forever (Godot issue #81839) (based on [@elfensky](https://github.com/elfensky)'s fix, [PR #22](https://github.com/tomyud1/godot-mcp/pull/22))
- **Reconnection after failed retries** — the plugin now retries indefinitely with exponential backoff when the server is unreachable, instead of silently giving up after the first failed attempt
- **JSON string args auto-parsed** — tool arguments that arrive as JSON strings (e.g. `"{\"key\": \"value\"}"` instead of a Dictionary) are now automatically parsed at the executor level, fixing `update_project_settings` and protecting all tools from MCP clients that serialize nested objects as strings (reported by [@elfensky](https://github.com/elfensky), [#26](https://github.com/tomyud1/godot-mcp/issues/26))

## [0.2.8] - 2026-03-14

### Fixed
- **Server survives MCP client exit** — the server now shuts down when stdin closes, so closing Claude/Cursor properly terminates the process, releases port 6505, and lets the Godot plugin detect the disconnect (status turns red). Previously the server stayed alive as a zombie, blocking reconnection on next launch ([#10](https://github.com/tomyud1/godot-mcp/issues/10))

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
