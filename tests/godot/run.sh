#!/usr/bin/env bash
# Runs the plugin's headless test suite against a real Godot binary, first in
# game mode, then inside the editor.
#   GODOT=/path/to/godot tests/godot/run.sh
# The addon is copied in fresh each run (not symlinked) so Godot's import step
# can never write .uid/.import files into the real addon folder.
set -euo pipefail
cd "$(dirname "$0")"
GODOT="${GODOT:-godot}"
rm -rf addons _tmp project.godot
mkdir -p addons
cp -R ../../addons/godot_mcp addons/godot_mcp
rm -rf addons/godot_mcp/cache
cp -R editor_runner addons/mcp_test_runner
cp project.base.godot project.godot
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true

"$GODOT" --headless --path . --script res://run_tests.gd

# Editor mode: enable the runner plugin for this run only.
printf '\n[editor_plugins]\n\nenabled=PackedStringArray("res://addons/mcp_test_runner/plugin.cfg")\n' >> project.godot
"$GODOT" --headless --editor --path . 2>&1 | sed -n '/\[editor mode\]/,$p'
status=${PIPESTATUS[0]}
cp project.base.godot project.godot
exit "$status"
