# Pre-release verification — remaining tests

Only what changed between the last Claude session and this one. Everything previously marked ✅ (connect_signal persistence, add_node child-key validation, get_guide, delete_file on background tab) stays fixed and does not need retesting unless you suspect a regression.

Prereq: rebuild and restart the dev MCP, then call `get_godot_status` and confirm the server version has actually changed since the last session (the `0.4.x` number or a dev marker). If it still reports the same version as before the rebuild, an old primary is still running on port 6505 / 6506 — kill it and retry.

---

## A. `wait` is non-blocking and safely clamped (I7 minor — previously crashed)

The old `wait` used `OS.delay_msec`, which froze the editor AND the WebSocket pump. On large inputs (30 s and up) the MCP server's 30 s transport timeout fired before Godot could respond, leaving the session broken. The new `wait` yields via `SceneTree.create_timer(...).timeout` and clamps at 20 000 ms.

1. `wait({ ms: 250 })` → expect `ok: true`, `waited_ms: 250`, no `clamped` field.
2. `wait({ seconds: 0.5 })` → `waited_ms: 500`.
3. `wait({ ms: 100, seconds: 5 })` → `waited_ms: 100` (ms wins).
4. `wait({})` → `ok: false`, error mentioning `ms` / `seconds`.
5. `wait({ seconds: 999 })` → **`ok: true`**, `waited_ms: 20000`, `clamped: true`, `requested_ms: 999000`, `note` mentioning the 20 000 ms cap. **Must return cleanly within ~20 s; must not break the session.**
6. `wait({ ms: 1000000 })` → same as step 5, `waited_ms: 20000`, `clamped: true`, `requested_ms: 1000000`.
7. Immediately after step 6, call any other tool (e.g. `get_godot_status`) to confirm the session is still alive. **If step 6 or 7 fails with "Godot is not connected" or similar, the fix is incomplete.**
8. While a long wait is in flight (e.g. `wait({ ms: 15000 })`), the Godot editor UI should remain responsive (you can click around, select nodes, etc.). This is a visual sanity check — no more frozen editor during waits.

## B. `delete_file` refuses to delete open tabs (B2 — previously crashed on active scene)

The old guard only covered some cases. The new one refuses any file open anywhere in the editor.

1. In Godot, open `res://verify_b.tscn` (create one via `create_scene` first) so it becomes the active scene tab.
2. `delete_file({ path: "res://verify_b.tscn", confirm: true })`. **Expect** `ok: false`, `error` naming "active scene tab", `open_in_editor: true`, `is_active: true`. **File must still exist on disk.**
3. `read_file({ path: "res://verify_b.tscn" })` should still succeed.
4. Open a second scene so `verify_b.tscn` becomes a background tab (still open). Re-run `delete_file` → expect `ok: false`, `where: "scene tab"`, `is_active: false`.
5. Close `verify_b.tscn` completely. Re-run `delete_file` → expect `ok: true`, the file is gone.
6. Script case: create `res://verify_b.gd` via `create_script`, open it in the editor's script panel, then `delete_file({ path: "res://verify_b.gd", confirm: true })`. **Expect** `ok: false`, `where: "active script editor tab"` (or `"script editor"` if it isn't the focused script).
7. Force path: with any file still open, `delete_file({ path: ..., confirm: true, force: true })` should proceed (the description warns this can still crash for an active scene tab — use only when you're sure the tab is safe to drop).
8. Cleanup.

## C. `get_guide` (confirm still working after the dispatch refactor)

The `tool_executor` / `plugin.gd` call path changed to support the async `wait` tool. Guide retrieval should be unaffected — quick sanity check.

1. `get_guide({})` → 5 guides listed.
2. `get_guide({ slug: "testing-loop" })` → markdown returned.
3. `get_guide({ slug: "bogus" })` → `ok: false` with `available_slugs` present.

## D. Regression smoke — sync tools still work after the coroutine refactor

`_on_tool_requested` now `await`s `execute_tool`. That means every tool goes through a coroutine path, even the sync ones. Do a quick smoke test across a few sync tools to confirm results still arrive correctly (this would fail by returning `null` / a Signal object if the dispatch regressed):

1. `get_godot_status({})` → returns the status dict.
2. `list_scripts({})` → returns `scripts` list.
3. `create_scene({ scene_path: "res://verify_d.tscn", root_type: "Node2D" })` → returns `ok: true`, `path: "res://verify_d.tscn"`.
4. `read_scene({ scene_path: "res://verify_d.tscn" })` → returns the root node structure.
5. `delete_file({ path: "res://verify_d.tscn", confirm: true })` (with the file not currently open) → succeeds.

## E. Release housekeeping (do this only after A–D all pass)

1. Decide the version. Given the scope of what has landed in this cycle (runtime autoload, MCP resources, `get_guide`, ~10 new tools, async wait, project-rename safety) a minor bump to `0.5.0` is the right call.
2. Update all four version touch points to the agreed value:
   - `mcp-server/package.json` (`version`)
   - `mcp-server/server.json` (`version` and `packages[0].version`)
   - `addons/godot_mcp/plugin.cfg` (`version`)
   - `CHANGELOG.md` — rename `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD`
3. `cd mcp-server && npm run build` — must succeed.
4. `cd mcp-server && npx vitest run` — expect 52 / 52 passing.
5. `get_godot_status.server_version` reports the new version after the new build loads.

---

### Pass criteria

Every step in A–D either matches the **Expect** line or fails with an actionable error. A step that returns `{ok: true}` but leaves state unchanged (or that reports success and then breaks the next tool call) is a **failure**. The whole point of this verification pass is catching exactly the "reports success, actually crashed the session" pattern that the previous round surfaced.
