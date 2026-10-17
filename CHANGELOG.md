# Changelog

## [0.6.1] - 2026-10-17

A reliability release built from agent feedback: several tools reported success while changing nothing. Fixed at the root with three shared foundations instead of per-tool patches, and the tool list shrinks from 75 to 69 because six specialized tools are no longer needed. Every existing call keeps working.

### Added

- **One type-guided path for writing properties (`utils/property_writer.gd`).** Every tool that writes a property or passes a method argument now goes through it: `create_scene`, `add_node`, `instance_scene`, `set_node_properties`, `call_method` (editor and runtime) and the visualizer. The property's declared type decides how a JSON value is read:
  - **Resources by path or inline.** A Texture2D/Shape/Mesh/Material/AudioStream/... property accepts `"res://icon.png"`, `{type:"Resource", path}`, or an inline resource such as `{type:"RectangleShape2D", size:{x:32, y:16}}` whose other keys are its properties (nested resources work). The loaded or created resource must match the property's class.
  - **Colon paths into held resources:** `{"shape:radius": 12, "material:albedo_color": "red"}`, including into a resource assigned in the same call.
  - **Strict, friendly values.** Enums by name (`"Nearest"`, `"TEXTURE_FILTER_NEAREST"`) or number; colors as `"#ff8800"`, `"red"` or `{r,g,b,a}`; vectors as `{x,y}` or `[x,y]`. Missing or unknown components, non-integral ints, and values of the wrong kind are errors. A String property keeps `"res://..."` as text.
  - **Typed arrays and dictionaries** (`Array[Texture2D]`, typed `Dictionary`) are built with the right element types.
  - **Writes are read back.** A value Godot adjusted (clamped, wrapped) is returned in `adjusted`; a write Godot ignored is an error. Properties are applied in Godot's declared order, so `{frame, hframes}` works in any key order.
  - **Errors name the exact property and suggest close names** (`nodes[1].properties.texure: 'texure' is not a property of Sprite2D (did you mean 'texture'?)`).
- **Argument checking for every tool call (server).** Calls are checked against each tool's schema before anything reaches Godot. Unknown arguments, missing required ones, wrong types and invalid enum values are rejected with a suggestion and a `usage` line; `batch_execute` sub-commands are checked the same way with `commands[i]` in each message. JSON-stringified objects, numeric/boolean strings and `null` for optional arguments are still accepted.
- **Schema/plugin agreement test** (`plugin-args.test.ts`): fails if a schema declares an argument the plugin never reads, or the plugin reads one the schema doesn't declare. It found five undeclared arguments on its first run (below).
- **`set_node_properties` can edit a resource file directly**: pass a `.tres`/`.res` as `scene_path` (undoable like a scene).
- **`query_runtime_node` returns the node's state by default:** with no `properties` it lists every script variable plus every stored property that differs from its class default (a Label's `text`, `velocity`, ...), and `global_position`. Explicit names support colon paths; unknown names are errors with suggestions. Large arrays and strings are truncated.
- **Plugin version handshake.** The plugin reports its version and Godot version on connect; `get_godot_status` shows `plugin_version`, `godot_version`, and a `warning` when plugin and server versions differ.
- **Headless plugin test suite** (`tests/godot/run.sh`): runs against a real Godot binary in game mode and inside the editor (placeholder scripts, real EditorPlugin). 91 + 80 checks.

### Changed

- **Six tools hidden in favor of `set_node_properties`:** `modify_node_property`, `set_resource_property`, `set_collision_shape`, `set_sprite_texture`, `set_mesh`, `set_material`. They no longer appear in the tool list but remain callable (also inside `batch_execute`), now run through the shared writer, and their responses include a `deprecation_notice` with the equivalent call.
- **Consistent argument names.** `run_scene.scene` → `scene_path`, `list_dir.root` → `path`, `map_project.root` → `path`, `connect_signal`/`disconnect_signal` `from_node`/`to_node` → `from_node_path`/`to_node_path`. The old names are still accepted. The plugin keeps receiving the old names, so any plugin version works with any server version.
- **`edit_script` takes flat arguments:** `{path, old_text, new_text, context_before?, context_after?}`. The older `{edit: {file, old_snippet, new_snippet}}` shape is still accepted.
- **`create_scene` and `add_node` build the whole node tree in memory first** and report every problem in one response; the scene file is written only when everything is valid. `add_node` now returns the new node's `node_path`. `create_scene`'s default root name is the file name in PascalCase, as its description always claimed (it was "Node").
- **`send_input` rejects unknown key names, unknown actions and unknown event fields** instead of sending nothing. Key events now set both `keycode` and `physical_keycode`.
- **`call_method` decodes arguments by the method's parameter types**; for `set(property, value)` the value is decoded by that property's type.
- **Serialized values:** embedded resources are returned as `{type:"Resource", class, embedded:true}` instead of `null`; Node values, Vector4, Rect2i, Plane, Transform2D, NodePath and packed arrays are now serialized.
- Guides rewritten for the new property model (`scene-editing`), plus autoload and coroutine notes (`testing-loop`), new troubleshooting entries, and a tool index without tools that don't exist.

### Fixed

- **`create_scene` / `add_node` / `instance_scene` silently dropped resource values** like `"texture": "res://x.png"` while reporting success.
- **`call_method` returned `ok: true` but changed nothing** when passed `{type:"Resource", path}` (e.g. `set_texture`, `set("texture", ...)`).
- **`set_sprite_texture` reported success on nodes without a `texture` property.** (It always worked on any node *with* one, such as PointLight2D; that's now documented.)
- **`run_scene` ignored a misspelled scene argument and launched the main scene**; `create_scene` ignored unknown top-level keys. Both are now argument errors.
- **Edits to a shared `.tres` through a node were silently lost** on save (`set_resource_property` on a resource saved with `save_resource_to_file`). They are now refused with directions; edit the file itself with `set_node_properties`.
- **Unknown shape/mesh/material parameters were ignored** (e.g. `extents` on a 4.x shape); they're now errors with suggestions.
- **Undeclared arguments added to schemas:** `read_file.max_bytes`, `search_project.max_results` and `case_sensitive`, `list_dir.include_hidden`; the old spellings `set_editor_selection.node_path` and `close_editor_tabs.scenes` are accepted as aliases.
- Stale versioning note (said 0.5.0).

### Packaging

- The plugin folder now contains `LICENSE`, so the Asset Store / Asset Library download includes it.
- Published on the new Godot Asset Store as **Godlink MCP**; README install steps cover the Asset Store (4.7+), AssetLib (4.6 and older) and manual install.
- Requires Godot 4.4 or newer (the plugin already used typed-Dictionary syntax from 4.4).

## [0.6.0] - 2026-08-24

### Breaking Changes

- **`set_node_properties` is now atomic.** Any validation failure aborts the whole call with `ok: false`; the `failed` field is gone (superseded by `validation_errors`). Previously each property applied independently and returned `ok: true` even on partial failure. See *Changed*.
- **Every tool now returns a top-level `ok` field.** `plugin.gd` / `mcp_runtime.gd` used to strip it from successful responses, so agents inferred success from the absence of `error`. Code keying off `error` is unaffected; code checking `result.ok` starts working. See *Changed*.
- **`create_script` rejects non-`.gd` paths** instead of silently writing them — returns `wrong_extension: true` and points at the new `write_file`. Missing extensions still auto-complete to `.gd`. See *Changed*.
- **`find_nodes_in_group` removed**, superseded by `find_nodes`. Migration: `find_nodes({scene_path, in_group: group})`. See *Removed*.
- **`close_scene_tabs` renamed to `close_editor_tabs`** with no schema alias (it was never released, so this only affects anyone tracking `main`). The `scenes` arg key is still accepted at runtime as an undocumented alias for `paths` for one cycle.

### Added

- **Unified undo/redo (`mcp_undo`, `mcp_redo`, `mcp_undo_history`)** — every mutating MCP tool now snapshots the affected files before running, into a disk-backed ring buffer at `res://addons/godot_mcp/cache/undo/` (capped at 200 entries / 100 MB total, oldest evicted). `mcp_undo` rolls back the most recent change(s), `mcp_redo` reapplies what was undone, and `mcp_undo_history` lists both stacks with tool name, args summary, files affected, and age — so the AI can decide how far to revert.
  - Coverage is automatic via a registry in `tool_executor.gd`: scene mutations (`add_node`, `remove_node`, `modify_node_property`, `set_node_properties`, `attach_script`, `connect_signal`, `set_resource_property`, …), script edits (`edit_script`), file ops (`create_script`, `create_folder`, `delete_file`, `rename_file`, `create_scene`, `save_resource_to_file`, `generate_2d_asset`), and project mutations (`update_project_settings`, `configure_input_map`, `setup_autoload`).
  - On undo, scenes/scripts open in the editor are auto-reloaded so the user sees the restored state immediately.
  - Tool failures **do not** auto-rollback — partial mutations are left in place so the AI/user can decide what to do; the discarded snapshot is just dropped.
  - **Important UX caveat (documented in the tool description):** Godot's native Ctrl+Z does **not** reach AI-applied changes. The MCP plugin operates by load→mutate→save on disk rather than touching the editor's live in-memory tree, so there is no `EditorUndoRedoManager` action to undo. Reverting AI work goes through `mcp_undo` (the user asks the agent).
  - Cap-reached warning is emitted once per editor session (no spam on every subsequent mutation).
- **`batch_execute` tool** — run an ordered list of MCP tool calls as a single composite operation. Cuts round-trip latency, response tokens, and per-call error handling on common multi-step workflows ("add a node, set 5 properties, attach a script, connect 2 signals" becomes 1 call instead of 9). The whole batch commits as ONE undo entry, so a single `mcp_undo` reverts everything.
  - **Modes:** `atomic: true` (default) rolls back every earlier successful sub-command from snapshots if any step fails — the batch either fully applies or appears never to have happened. `atomic: false` with `stop_on_error: true` (default in non-atomic mode) stops at first failure and commits the partial result. `atomic: false, stop_on_error: false` runs every command regardless and reports every failure.
  - **Disallowed inside a batch:** `batch_execute` (no nesting), `mcp_undo` / `mcp_redo` / `mcp_undo_history` (would corrupt the in-progress entry), `wait` (coroutine), `run_scene` / `stop_scene` (process lifecycle isn't snapshotable). Pre-validated structurally up front — typos and disallowed tools surface before any mutation.
  - **Response:** `{ok, atomic, stop_on_error, succeeded, total, results, failed_at?, failed_command?, error?, failures?, rolled_back?, rollback_errors?, undo_entry_id?}`. `failures: [{index, name, error}]` lists EVERY failure (relevant for `stop_on_error: false`); the top-level `failed_at`/`failed_command`/`error` describe just the first.
  - **Sub-commands reuse the normal tool dispatch path** — same validation, same error shape, same snapshot recording — so behavior is consistent with calling each tool individually, just collapsed into one transaction with one undo entry.
  - **Companion `batching` guide** at `godot-mcp://guide/batching` (also reachable via `get_guide({slug: "batching"})`) covers the mode matrix, the disallowed-tools list, three worked examples (atomic build, partial-success bulk rename, read+mutate), and pitfalls.
  - Test registry test extended to recognize built-in tools dispatched via the `match tool_name:` block in `tool_executor.gd` (was previously failing for `mcp_undo`/`mcp_redo`/`mcp_undo_history` since the v0.5.0 undo work; `batch_execute` would have inherited that gap).
- **`call_method` tool** — invoke any method on any node, in either the editor's on-disk scene or the running game. The write counterpart to `query_runtime_node` (which only reads). One tool subsumes the workflows that previously required ~10 specialized "play", "stop", "restart" tools, and unlocks driving the game from the AI (`Player.take_damage(50)`, `Inventory.add_item("sword", 1)`, `AnimationPlayer.play("intro")`) — capabilities that weren't reachable through `send_input` because they need structured arguments or aren't bound to input actions.
  - **Two modes** controlled by `runtime`:
    - `runtime: false` (default, editor mode) — loads the `.tscn` from disk, finds the node, invokes the method, ALWAYS saves the scene back. Snapshot taken so `mcp_undo` reverts the file. Use for methods that mutate persistent state where no property accessor exists: `Curve2D.add_point(pos)`, `CollisionObject2D.set_collision_layer_value(layer, on)`, `Node.add_user_signal(name)`, etc.
    - `runtime: true` — routes the call through the MCPRuntime helper inside the running game. Finds the live node in the active `SceneTree`, invokes the method, returns the serialized result. Requires `run_scene` first.
  - **node_path resolution** mirrors existing tools: editor mode is relative to scene root (`"Player"`, `"UI/HUD/Label"`, `"."`); runtime mode accepts absolute (`/root/Main/Player`) or current_scene-relative paths (same rules as `query_runtime_node`).
  - **Argument parsing** reuses `VariantCodec` so `args` accept primitives, arrays, and the same `{type:"Vector2",x,y}` / `{type:"Color",r,g,b,a}` / `{type:"Resource",path:"res://..."}` discriminated form used by `modify_node_property`.
  - **Editor-mode user-script method guard.** Godot's editor instantiates scenes with `GEN_EDIT_STATE_MAIN`, which attaches scripts and lets `@export` vars round-trip but does NOT dispatch user-defined method bodies for non-`@tool` scripts — `callv("take_damage", [50])` would silently return null instead of running the body. Editor-mode `call_method` now detects this case (script attached, `script.is_tool() == false`, target method appears in `script.get_script_method_list()`) and refuses with `reason: "non_tool_script_method"` + a hint pointing the AI to runtime mode. Without this guard the agent gets a `return_value: null` and reasonably concludes "the method ran, it just returns void," when in fact the body never executed. Built-in / C++ class methods (`set_modulate`, `add_to_group(name, true)`, `Curve2D.add_point`, …) are unaffected — they don't dispatch through the script.
  - **Method validation** — `node.has_method()` check; on miss returns `closest_matches` (top-5 most-similar method names via `String.similarity()`) plus an `available_methods_sample` (filters out engine-private `_`-prefixed methods). Arity is pre-checked against `MethodInfo` (with default-arg awareness) and reports a formatted `method_signature` on mismatch so the AI can self-correct in one round-trip.
  - **Destructive denylist** — `queue_free`, `free`, `set_script`, `remove_child`, `replace_by`, `reparent` require `confirm: true`. In runtime mode, calls directly on `/root/<name>` (likely autoloads or the active scene root) also require confirm. Applies in both modes; the tool description steers the AI toward `attach_script` / `detach_script` / `remove_node` for the equivalent intent without bypassing scene-tool invariants.
  - **Coroutine handling** — methods containing `await` return a `GDScriptFunctionState`. Such calls are dispatched fire-and-forget (`is_coroutine: true, awaited: false`); the return value is not captured but side effects still run. Follow up with `wait` + `query_runtime_node` to observe results. Awaiting properly across the WebSocket is deferred — the in-game timeline can stall on signals that never fire, and the current shape lets the AI compose its own observation window.
  - **Return value** — `Object` / `Node` returns serialized as `{type:"Object", class, name?, node_path?, serializable:false}` (follow up with `query_runtime_node` to inspect properties); `Resource` returns as `{type:"Resource", class, resource_path?}`. Primitives and standard variant types reuse `VariantCodec.serialize_value` for consistency with the rest of the tool surface. `expect_return: false` skips serialization entirely for void / fire-and-forget calls.
  - **Routing** — `routeIsRuntime()` in the TS bridge now picks up `args.runtime === true` and ships the call to the runtime slot; otherwise the editor's `tool_executor` handles it like any other scene-mutating tool (snapshot-aware, batchable). `call_method` is registered in `_MUTATING_TOOLS` with `snapshot_args: ["scene_path"]` so editor-mode calls participate in undo automatically; runtime-mode calls bypass the executor entirely and don't snapshot (matching the rest of the runtime tools).
- **`delete_folder` tool** — recursively delete a directory and all its contents in one call, with the whole deletion captured as a SINGLE undo entry. Closes [#52](https://github.com/tomyud1/godot-mcp/issues/52) where the AI couldn't clear large directories because the per-file `delete_file` loop ballooned the request and the agent gave up partway through.
  - **Self-snapshotting design** — new `self_snapshots: true` registry kind in `tool_executor.gd._MUTATING_TOOLS`. Unlike every other mutating tool (whose affected file set is known up front from args), `delete_folder` walks the tree at dispatch time and calls `record_deletion` itself for each file before removing it. The dispatcher hands the snapshot entry id via `args["__entry_id"]`, then commits or discards based on tool result like everything else — so the existing undo / batch_execute / atomic-rollback machinery works for free.
  - **Three safety guards, all refuse cleanly rather than half-delete:** (1) refuses if ANY file inside is open in a scene tab or script editor tab — close them first or pass `force: true` (deleting an open scene can crash Godot); (2) refuses if files inside are referenced as literal `res://...` strings from outside the folder (preload, ext_resource, FileAccess.open targets, autoload entries) — repoint them or pass `force_orphan: true`; (3) refuses if the contents would exceed half the undo cap (default 50 MB threshold) — pass `allow_no_undo: true` to delete without recording an undo entry, preserving existing undo history.
  - **Reference scan is intentionally conservative** — any literal `res://...` substring match counts, including runtime targets that get re-created on next run, because the scanner cannot statically distinguish load-bearing references from benign strings. Error wording and the tool description explain this and point at `force_orphan: true` as the right escape hatch for known-runtime-only references.
  - **Recursive flag required for non-empty folders** — empty-folder delete works without `recursive`; non-empty needs explicit `recursive: true` to avoid surprises. Empty folders aren't undoable (only files are tracked), documented in the response shape.
  - **Protected paths** — refuses to touch `res://` root or anything that overlaps `res://addons/godot_mcp` (the plugin itself, ancestors, or descendants), so a stray AI delete can't brick the editor mid-session.
  - **Returns** `{ok, path, deleted_files, deleted_count, removed_dirs, root_removed, total_bytes, undo_available, message}` (plus `partial: true` + `delete_errors` if some files couldn't be removed; the undo entry is committed for whatever WAS removed so `mcp_undo` still works on the successful subset).
- **`write_file` tool** — generic UTF-8 text writer for arbitrary project files. Fills the gap where `create_script` was the only path to write a text file, forcing AI agents to misuse it for `.gdignore`, `.gitignore`, `README.md`, `.json` configs, `.gdshader` files, custom `.tres` data, fixture content, etc. (`create_script` now rejects non-`.gd` paths and points at this tool — see Changed.)
  - **Create + overwrite modes, both undo-integrated.** Registry entry `{"snapshot_args": ["path"]}` reuses the existing dispatcher pipeline: `record_snapshot` picks `KIND_SNAPSHOT` for overwrites (undo restores prior content) or `KIND_CREATED` for new files (undo deletes the file) automatically — no new code in the undo manager. Overwrite is gated behind `overwrite: true`; calls against an existing path without it return `file_exists: true` and refuse.
  - **Path-traversal guard** — rejects any path containing `.` or `..` as a standalone path segment so AI-generated paths can't silently escape `res://` after `ProjectSettings.globalize_path` resolves them. Dots inside filenames (`with.dots.in.name.txt`, `.gdignore`) are unaffected.
  - **Plugin-source guard** — refuses writes anywhere under `res://addons/godot_mcp/` except `res://addons/godot_mcp/cache/` (the legitimate write target for the snapshot store), unless `force: true` is passed. Overwriting live plugin files mid-session can crash the editor.
  - **Editor sync after write** — replaces the `ResourceLoader` cache entry for `.tscn` / `.tres` / `.gdshader` / `.scn` so the next `load()` reads fresh bytes (sets `cache_evicted: true`), force-reloads any cached `Script` resource for `.gd` writes (sets `script_reloaded: true`), and reloads any open scene tab whose `.tscn` was just rewritten (sets `scene_reloaded: true`). The refresh runs unconditionally for the recognized extensions because Godot's editor keeps resources alive in places `ResourceLoader.has_cached()` cannot see (open tabs, `EditorFileSystem` index). `CACHE_MODE_REPLACE` is idempotent — when nothing was cached it just loads fresh. The script editor's in-memory tab buffer is NOT swapped (Godot exposes no public API), so a `.gd` open in the editor may need a tab refocus to display new source.
  - **Auto-create parent directories** by default (`create_dirs: true`); pass `false` to refuse missing parents instead.
  - **Text only** — binary content (textures, audio) needs a runtime helper script; documented in the tool description.
  - **Returns** `{ok, path, existed, bytes_written, message}` plus `editor_refresh: {cache_evicted, scene_reloaded, script_reloaded}` when any refresh action ran successfully.
- **`find_nodes` tool** — general scene-scoped node search. Filters AND together: `name_pattern` (case-insensitive, auto-detects glob via `*`/`?` else substring), `type` (Godot class — matches subclasses, so `Node2D` matches `Sprite2D`; also matches globally-registered script `class_name`s), `in_group`, and `recursive` (default true). `scene_path` is optional and defaults to the editor's currently edited scene. Returns one entry per match with `path`, `name`, `type`, and `groups`. Unknown `type` strings return an error instead of silent zero matches so typos surface immediately. With no filters, returns every node in the scene as a structured alternative to `scene_tree_dump`.
- **`close_editor_tabs` tool** — unified scene + script tab closer (renamed from the never-released `close_scene_tabs`; old name removed entirely, no alias on the schema). Default closes every open tab of every kind; pass `kind: "scene" | "script" | "any"` to restrict and/or `paths: ["res://a.tscn", "b.gd"]` (with or without `res://`) to target specific tabs. Built primarily for test automation — letting the agent reset the editor to a known state between runs without restarting Godot, and to clear the `delete_file` / `delete_folder` editor-open guard without using `force: true`.
  - **Scenes** use `EditorInterface.close_scene()` (Godot 4.5+) — older versions get a structured error pointing at the version requirement. Unsaved scene edits are DISCARDED silently (matches Godot's native close-tab behavior; save first via the editor or `save_resource_to_file` if pending edits matter).
  - **Scripts** — Godot does not currently expose a public API to close script tabs from script. Requested script paths are returned in `scripts_closed_not_supported` with the reason and a workaround pointer (close manually via the X on the tab, or use `force: true` on the next file mutation to bypass the editor-open guard) rather than being silently skipped — when Godot adds the API, this tool will start actually closing them with no schema change.
  - **Returns** `{ok, scenes_closed, scripts_closed_not_supported, not_open, remaining_scenes, remaining_scripts, message}` plus `scenes_failed` (with per-path Godot error codes) when any close fails.
  - **Legacy `scenes` arg key** is accepted at runtime as an alias for `paths` for one transition cycle, deliberately not advertised in the JSON schema so agents don't learn to depend on it.
- **`get_editor_selection` + `set_editor_selection` tools** — read and write the editor's Scene-dock selection so the user can say "fix this" / "change the color here" / "delete that one" without typing a node path. `get_editor_selection` returns `{ok, scene_path, selection:[{path,name,type}], count}` (empty array if nothing is selected — informational, not an error); paths are scene-relative and match the format produced by `find_nodes` / `scene_tree_dump`, so they pass straight to `modify_node_property` / `attach_script` / `remove_node` / etc. `set_editor_selection` accepts `node_paths` (array of strings, or a single string for convenience) and `mode: "replace" | "add"`; pre-validates every path against the live edited scene tree and refuses the whole call if any path is unresolved (no partial selection mutation). Companion `selection-workflow` guide at `godot-mcp://guide/selection-workflow` lists the trigger phrases ("this node", "fix this", "change the color here", "the highlighted one", …) and the two main `set_editor_selection` use cases (focus the gizmo on a freshly-`add_node`'d node; highlight what the AI just found). Tool descriptions also embed the trigger phrasing so the AI picks the tool up without having to read the guide.
- **`get_performance_monitors` tool** — runtime-only snapshot of Godot's `Performance` singleton from inside the RUNNING game. Returns `fps`, `frame_time_ms`, `physics_process_time_ms`, configured `physics_ticks_per_second`, current and peak static memory (both `_bytes` and `_mb`), renderer counts (`draw_calls`, `objects_in_frame`, `primitives_in_frame`), engine-wide instance counts (`total_objects`, `nodes`, `orphan_nodes`), and any user-registered `Performance.add_custom_monitor` entries under `custom_monitors`. Three intended call sites: post-`run_scene` framerate verification, localizing user-reported lag (low fps vs high draw_calls vs growing memory vs orphan_nodes leak), and before/after measurement for optimization claims. Routed through the MCPRuntime autoload (added to `RUNTIME_ONLY_TOOLS`), so calling it without `run_scene({wait_for_runtime: true})` returns the existing "Runtime helper not connected" structured error rather than misleading editor-side numbers. Surfaced in the `testing-loop` guide and the `tool-index`.
- **`get_scene_node_properties` is now an MCP tool.** The handler already existed in the editor plugin's tool executor but was never exposed in the published tool list, so the AI couldn't discover it. Returns the FULL property list for a node in a .tscn (including `@export`'d script vars and inherited properties), each entry carrying current value, declared variant type, hint metadata, and a category grouping. Fills the gap `read_scene` doesn't cover — `read_scene` uses a curated subset (position, modulate, text, …) for quick overviews, while this returns everything. Use it to verify `add_node` / `set_node_properties` actually wrote what they claimed (especially for script `@export` vars), or to look up the real name of a property when the AI guesses wrong ("color" vs "modulate"). Surfaced in the `set_node_properties` hint text and in `read_scene`'s description.

### Changed

- **`add_node` / `create_scene` / `set_node_properties` now pre-validate the entire input spec before mutating** (roadmap #7 — validate-then-mutate). One reusable walker (`_validate_node_spec`) checks: every `node_type` exists in ClassDB; every `script` path exists on disk AND loads as a Script; every key in `properties` is a real property on the target class (plus any @export'd properties on the attached script when present); `children` is a well-formed array of Dictionaries; recurses through every descendant. On failure, the response is `ok: false` with a `validation_errors: [...]` array of **path-pointed** messages — e.g. `children[2].properties.text: property does not exist on Sprite2D`, `nodes[1].children[0].script: file does not exist: 'res://missing.gd'` — and ZERO mutation occurs (no scene load for `add_node`, no file creation for `create_scene`, no scene save for `set_node_properties`). Catches the most common AI failure mode (typoed property names like `color` for `modulate`, `text` on Sprite2D, etc.) that was previously silently swallowed by `add_node`/`create_scene` and only surfaced post-hoc as a partial failure on `set_node_properties`.
- **`set_node_properties` is now atomic by default** (behavior change from per-property tolerance). Old behavior: each property was applied independently, the response carried `applied: [...]` + `failed: [...]` and `ok: true` even when some failed. New behavior: any pre-validation failure aborts the whole call with `ok: false`. Removes the ambiguous mixed-result shape and the silent partial-application state. The `applied` field is still returned on success; the `failed` field is gone (its purpose is subsumed by `validation_errors`).
- **`get_runtime_status` now reports the Godot engine version.** Adds `godot_version` (e.g. `"4.5.0.stable"`) and `godot_version_info` (the full `Engine.get_version_info()` dict — `major`, `minor`, `patch`, `string`, `build`, `hex`, …). Lets agents bind test reports / bug repros to a specific Godot build without asking the user to open the About dialog. No removals; existing fields are unchanged.
- **`get_editor_selection` now emits a stable `reason` field on every response** — `"ok"` (selection has entries), `"none_selected"` (scene open, nothing selected), or `"no_scene_open"` (no tab open). The human-readable `message` is also now present for both empty states (previously the scene-open / nothing-selected case omitted it, while the no-tab-open case included one). Agents can branch on `reason` instead of string-matching `message`. The `selection` array, `count`, and `scene_path` fields are unchanged.
- **`set_editor_selection.node_paths` schema now advertises both forms** via `oneOf: [string, array<string>]`. The server has always tolerated a bare string for the single-target convenience case, but the published schema only documented the array form — strict MCP clients could have rejected the bare-string call before it reached the wire. Schema and runtime now agree.
- **`run_scene.startup_timeout_ms` is now clamped to 25000ms** (5s buffer below the TS bridge's 30s per-tool transport timeout). Callers passing larger values used to occasionally trip a transport-level "tool timed out" failure that ate `run_scene`'s structured response. Clamping is non-fatal: the response now includes `startup_timeout_clamped: true`, `requested_startup_timeout_ms`, `effective_startup_timeout_ms`, and a `note` explaining the cap. Behavior for values ≤ 25000 is unchanged.
- **Response shape — every tool now ships its top-level `ok` field to callers.** Previously `plugin.gd` and `mcp_runtime.gd` stripped `ok` from successful responses (the agent had to infer success from the absence of an `error` field) and dropped the full structured body for runtime failures (only the bare error string survived). Now `ok: true` / `ok: false` is always present on the JSON the agent reads, and runtime failures carry the full structured body too. Callers that already worked off `error`/`error_code` are unaffected; callers that check `result.ok` start working correctly. Sub-finding from a live `batch_execute` test run that flagged "successful batches lacked top-level `ok: true`."
- **Composite/built-in tools (`batch_execute`, `mcp_undo`, `mcp_redo`, `mcp_undo_history`) now always route through the success transport path** regardless of their internal `ok` value. Their `ok: false` is a SEMANTIC result (e.g. "the batch had 2 failures", "the undo stack is empty"), not a transport failure — so previously they were getting wrapped in the generic `{error, tool, args, hint}` MCP envelope, losing the structured body. Now the full response (`failures`, `succeeded`, `total`, `failed_at`, `undone_count`, etc.) flows through intact and `isError: true` is no longer set on those four.
- **TS bridge catch block stops stripping `ok`/`error` from merged details** — when a regular tool returns `ok: false`, the agent now sees the tool's own structured `ok: false` + detailed `error` string at the top level, plus the existing structured fields (`open_in_editor`, `where`, `clamped`, …). Previously these two were filtered out under the assumption they added no info; the live test showed the opposite.
- **`batch_execute` no longer commits empty undo entries.** Read-only batches (e.g. just `read_scene` or `get_scene_node_properties`) used to leave a 0-file entry on the undo stack. Now any batch that recorded no snapshots is discarded at finalize time and `undo_entry_id` is omitted from the response.
- **`batching` guide example arg names corrected** — `parent` → `parent_path` (for `add_node`) and `property` → `property_name` (for `modify_node_property`). The previous example silently fell back to scene root for `add_node` since the wrong key was just ignored.
- **`edit_script` description** — dropped the "SMALL, SURGICAL (1-10 lines)" framing that was steering models away from the tool for medium and large edits ([#48](https://github.com/tomyud1/godot-mcp/issues/48)). The implementation has always supported any snippet size, including a full-file rewrite (pass the whole file as `old_snippet`). Description now says so explicitly and points at `context_before`/`context_after` and `read_file` as the recovery path when a match can't be found.
- **`create_script` now rejects non-`.gd` paths instead of silently writing them.** The docs always said GDScript-only, but the implementation accepted any extension — agents trying to write `.gdignore` / `.json` / `README.md` were getting them written through `create_script` and discovering only at runtime that the boilerplate-insertion semantics didn't match plain text. With `write_file` now available for arbitrary text, the boundary is clean: explicit non-`.gd` extensions return `wrong_extension: true` and point at `write_file`; missing extensions still auto-complete to `.gd` (legacy convenience preserved); `.GD` etc. are accepted (`.to_lower().ends_with(".gd")` is case-insensitive). Tool description on the server side carries the same boundary statement so the agent picks the right tool up front.
- **`scene_tree_dump` — opt-in pagination + depth + subtree scoping.** Adds four optional args, all backward compatible (zero-arg call still returns the full tree):
  - `subtree_root` — scene-relative node path (e.g. `"UI/HUD"`, `"."` or empty = scene root). Depth resets to 0 at that node, so you get just that subtree.
  - `max_depth` — stop traversal at depth N from the (subtree_)root. `0` = only the root itself; omit or pass a negative value for unlimited. Useful for "give me the top-level layout of a deep scene."
  - `offset` / `limit` — paginate by flat DFS preorder index. `offset` skips the first N nodes; `limit` caps how many are emitted after.
  - Response always now includes `total_node_count` (total nodes in the bounded scope). When `offset`/`limit` actually clipped output, the response also returns `truncated: true` and `next_offset` so the AI can fetch the rest. `max_depth` clipping is treated as intentional scoping, not truncation. Unknown `subtree_root` returns a structured error. Source of truth remains the editor's live in-memory scene (reflects unsaved edits), matching prior behavior.

### Fixed

- **`mcp_undo` of `create_folder` no longer leaves the created directory on disk.** Pre-existing bug surfaced by `delete_folder`'s batch tests: `KIND_CREATED` records assumed file content, so the undo path called `FileAccess.file_exists(dir_path)` (returns false for a directory) and silently skipped the removal. Inside an atomic `batch_execute` the same bug meant a `delete_folder + create_folder` batch undone in one step would restore the deleted files but leave the new folder. Fix: `_record_created` in `tool_executor.gd` now stamps `is_dir: true` on the manifest record when the path is a directory at record time; `undo_one`, `redo_one`, and `rollback_pending` in `undo_manager.gd` route `is_dir` records to `DirAccess.remove_absolute` (undo) / `make_dir_recursive_absolute` (redo) instead of the file-content path. Backward-compatible: manifests written before the fix detect the directory at restore time, so existing undo entries restored after upgrade still work.
- **`rescan_filesystem` no longer hard-errors when a scan is already in progress.** Returned `ok: false, "A filesystem scan is already in progress. Wait and retry."` whenever Godot's `EditorFileSystem.is_scanning()` was true, which is common right after a batch of mutations (the editor's own queued scan is still running). Test automation that just wants "make sure the editor sees disk" was broken by the hard error. Now returns `ok: true, already_scanning: true, message: "...in-flight scan will pick up recent disk changes"` — the busy in-flight scan covers what our scan would have done, and the `script_path_cache` is cleared either way so stale basename → `res://` resolutions don't survive a rescan call regardless of which scan ends up running.
- **`delete_folder` external-reference refusal now explains the conservative scan intent.** Previous error wording ("...references to files inside it exist outside the folder") read like a simple "find load-bearing references and refuse" guard. The scan is intentionally a literal `res://...` substring match — it can't statically tell apart `preload(...)` from `FileAccess.open("res://.../runtime.bin", WRITE)` (where the path is a write target that gets recreated each run, safe to orphan). Test feedback showed the AI was repeatedly trying to "fix" the listed reference instead of reaching for `force_orphan: true`. Error now spells out the literal-scan behavior, lists the kinds of paths that count (preload, ext_resource, FileAccess.open targets, hardcoded path strings, autoload entries), and includes a `hint` field steering reviewed-as-safe references toward `force_orphan: true`. Tool description carries the same explanation up front.
- **`delete_folder` description now warns about freshly-created `.uid` sidecars not being captured.** When the AI calls `delete_folder` on a directory containing files it just wrote in the same session (via `create_script` / `write_file`), Godot's `EditorFileSystem` may not have written the auto-generated `.uid` sidecar yet, so the snapshot misses it and `mcp_undo` restores the source file without its UID. Description now points at `rescan_filesystem` as the synchronization step before delete when full undo fidelity matters.
- **`add_node` / `create_scene` crashed (returned `"Tool returned no status"`) when `children` / `groups` / `properties` / `nodes` were passed with the wrong shape.** Typed locals (`var children: Array = args.get(...)`) blow up at the assignment in GDScript 4 if the actual value is e.g. a String — the function exits before the pre-validator runs. Locals are now Variant; the validator emits a clean path-pointed error (`children: must be an Array, got String`) and zero mutation occurs. Same root cause patched in both tools.
- **`add_node` (and `create_scene`'s nested children) silently dropped `@export`-defined script properties.** `set_script()` was called AFTER `_set_node_properties()`, so setting `my_custom_prop` on a bare Node2D (before the script attached) silently no-op'd because the var didn't exist yet. The pre-validator correctly accepted `my_custom_prop` as a valid script `@export`, then runtime dropped it — `ok: true` with no actual change. Reordered: script attaches first, properties apply against the now-scripted node. Both `add_node`'s top-level path and `_create_node_recursive` (used by `add_node.children` and `create_scene.nodes`).
- **`set_node_properties` accepted `texture: 1` / similar Resource-type misuses on fresh nodes.** Old guard was `if old_value is Resource and not (parsed is Resource)`, which only fired when the property already had a Resource value — missing the common case of a freshly-created Sprite2D where `texture` is null. New check reads the declared variant type from `property_list` metadata: any `TYPE_OBJECT` property receiving a non-Object, non-null value is rejected at pre-validation with a `validation_errors` entry pointing at the right specialized tool (`set_resource_property`, `set_sprite_texture`, …). The old heuristic stays as a belt-and-suspenders second pass.
- **`validate_script` reported `valid: false` for perfectly valid scripts.** The `Script.can_instantiate()` check returned false for free-floating GDScripts without a `resource_path` (typical of just-saved files), even for trivial `extends Node2D` + `@export var foo` scripts that work fine once attached via `node.set_script(...)`. Parsing success is now the primary signal — `valid: true` whenever `script.reload()` returns OK. The `can_instantiate` boolean is still surfaced in the response for callers that genuinely need to know (e.g. autoload registration), but it no longer drives `valid`.
- **`validate_script` now explains addon/parser-context failures instead of returning a generic dead end.** For `@tool` / editor-plugin scripts whose preload dependencies cannot be resolved by the isolated parser path, Godot can return `error_code: 43` with no line details. The response now includes `diagnostics_available: false` and a hint to use `get_errors` / `get_console_log` after addon reload for actionable diagnostics.
- **`get_errors` now reliably captures runtime debugger errors for issue [#49](https://github.com/tomyud1/godot-mcp/issues/49).** The tool reads the Debugger > Errors tree in addition to the Output panel, classifies warnings vs errors by row icon, extracts stack traces, and resolves bare `foo.gd:line` debugger frames to full `res://...` paths. The basename resolver now prioritizes the most recently run scene and uses scene-context-aware caching, fixing wrong-file reports when two scripts share the same basename.
- **`get_errors` now supports `wait_ms` for immediate post-`run_scene` checks.** Debugger rows can appear a few frames after the editor flips to playing; callers can pass `wait_ms: 300` (capped at 1000ms) to avoid false "0 errors" results while still returning well under the transport timeout.
- **`get_console_log` now detects Output panel filters.** When the Output panel's Info filter is off, regular `print()` lines are hidden before the tool can scrape them; the response now includes `output_panel_filters`, `info_filter_hint`, and a top-level hint asking the user to toggle Info back on. Error-prefixed Output lines still point callers to `get_errors` without overwriting the Info-filter hint.
- **`rename_file` no longer leaves broken references after moving scripts/resources.** By default it rewrites literal `res://old_path` references in text-format project files (`.tscn`, `.tres`, `.gd`, `.cs`, `.gdshader`, `project.godot`), updates matching autoload settings in `ProjectSettings`, moves `.uid` sidecars, and rebinds `ResourceUID` so UID-backed scene references resolve to the new path immediately.
- **`rename_file` no longer corrupts MCP undo snapshots.** The reference-rewrite scan now skips `res://addons/godot_mcp/cache/`, preserving historical `project.godot` backups under the undo cache so `mcp_undo` restores the original paths.
- **`rename_file` no longer silently discards unsaved scene edits while trying to refresh open tabs.** Scene tab reloads are guarded by Godot's dirty-state API when available. On Godot versions that do not expose a reliable dirty-state check (for example 4.6.2), automatic reload is skipped with `scene_reload_warnings` instead of closing the tab and losing unsaved work; files are still correct on disk and UID-backed scenes continue to run cleanly.
- **Generic error wrapper no longer injects `mode: 'live'` into every tool failure response.** The TS server's catch block in `index.ts` used to merge `{error, tool, args, mode: 'live', hint}` onto every failure payload before spreading the tool's own structured response on top. For tools that don't echo a `mode` field on error (`set_editor_selection` validation failures, anything that fails before its happy-path response is assembled), the wrapper's `mode: 'live'` survived — colliding semantically with `set_editor_selection`'s `mode: "replace" | "add"` (and similar fields on `set_node_groups` and others). The wrapper is meant to *augment* tool responses with diagnostic context, not invent fields that overlap with domain semantics. `mode: 'live'` is also redundant on failure paths because the earlier connection check guarantees we wouldn't get here if Godot wasn't connected. The separate `mode: 'live' | 'waiting'` field on `get_godot_status` (which actually means "is Godot's WebSocket connected") is unaffected — that one is meaningful in context.
- **`run_scene({wait_for_runtime: true})` could spuriously report `runtime_connected: false`.** The polling loop used `OS.delay_msec()`, which freezes the editor's main thread; that in turn freezes `MCPClient._process()`, which is the only place the editor reads incoming WebSocket frames. The `runtime_status: true` push from the TS bridge then sat unread until the polling loop ended — so even when the runtime helper had already connected to the server, `run_scene` returned with `runtime_connected: false`. The agent would only see the truth on the next `get_runtime_status` call (which arrived after the next `_process()` tick). Same root cause that was fixed in the `wait` tool previously. `run_scene` now yields to the SceneTree via `await create_timer().timeout`, so the WebSocket pump keeps running and the connection flag flips as soon as the message lands.
- **`run_scene` is now a registered coroutine** (added to `_COROUTINE_TOOLS` with an explicit dispatch case in `_dispatch_only`), required for the `await` change above to return a `Dictionary` rather than a `GDScriptFunctionState`. `run_scene` remains in `_DISALLOWED_IN_BATCH` (it was already excluded; this just keeps it consistent).

### Removed

- **`find_nodes_in_group` tool** — superseded by `find_nodes`. Migration: replace `find_nodes_in_group({scene_path, group})` with `find_nodes({scene_path, in_group: group})`. Same `scene_path` rules (now also optional — defaults to the active scene) and the same per-match shape (`path`, `name`, `type`), plus `groups` on every match.

### Docs

- **README Star History** — added a Star History chart (powered by [star-history.com](https://www.star-history.com/)) at the bottom of the README, with light/dark variants via `<picture>`. Verified the chart endpoint serves an `image/svg+xml` 200, so it renders on GitHub.

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
