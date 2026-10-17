/**
 * Script and file management tools for Godot MCP Server
 * Tools for editing scripts, managing files, and validating code
 */

import type { ToolDefinition } from '../types.js';

/** edit_script's argument names before 0.6.1 (nested under `edit`). */
const LEGACY_EDIT_KEYS: Record<string, string> = {
  file: 'path',
  old_snippet: 'old_text',
  new_snippet: 'new_text',
  context_before: 'context_before',
  context_after: 'context_after',
};

export const scriptTools: ToolDefinition[] = [
  {
    name: 'edit_script',
    description: "Edit an existing GDScript (.gd) file in place by replacing old_text with new_text, and save. The text can be any size — a single line, a function, or the whole file for a full rewrite. If old_text matches more than once, pass context_before/context_after to disambiguate; if it can't be found, read_file the relevant range and retry with an exact match. ONLY for .gd files; not for .tscn scene files (use the scene/node tools). After editing, consider validate_script and run_scene + get_errors.",
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Script to edit (res://path/to/script.gd)'
        },
        old_text: {
          type: 'string',
          minLength: 1,
          description: 'Exact text to replace, including whitespace and indentation'
        },
        new_text: {
          type: 'string',
          description: 'Replacement text (empty string deletes old_text)'
        },
        context_before: {
          type: 'string',
          description: 'Optional unique text right before old_text, when old_text appears more than once'
        },
        context_after: {
          type: 'string',
          description: 'Optional unique text right after old_text'
        }
      },
      required: ['path', 'old_text', 'new_text']
    },
    // Before 0.6.1 the arguments were nested: {edit: {file, old_snippet, new_snippet, ...}}.
    fromLegacy: (args) => {
      if (!('edit' in args)) return args;
      const { edit, ...rest } = args;
      if (Object.keys(rest).length > 0) return "pass either the flat arguments (path, old_text, new_text) or the older 'edit' object, not both";
      if (typeof edit !== 'object' || edit === null || Array.isArray(edit)) return "'edit' must be an object";
      const out: Record<string, unknown> = {};
      for (const [key, value] of Object.entries(edit as Record<string, unknown>)) {
        if (key === 'type') {
          if (value !== 'snippet_replace') return "edit.type must be 'snippet_replace'";
          continue;
        }
        if (!(key in LEGACY_EDIT_KEYS)) return `unknown key 'edit.${key}' (use the flat arguments: path, old_text, new_text, context_before, context_after)`;
        out[LEGACY_EDIT_KEYS[key]] = value;
      }
      return out;
    },
    // The plugin reads the nested shape; keep sending it so older plugins work.
    toWire: (args) => {
      const edit: Record<string, unknown> = { type: 'snippet_replace' };
      for (const [legacy, current] of Object.entries(LEGACY_EDIT_KEYS)) {
        if (current in args) edit[legacy] = args[current];
      }
      return { edit };
    }
  },
  {
    name: 'validate_script',
    description: 'Validate a GDScript file for syntax errors using Godot\'s built-in parser. Good for ordinary project scripts after editing. For @tool/editor-plugin addon scripts this isolated parser path may return valid:false with diagnostics_available:false because dependencies and editor context are not fully loaded; in that case, use get_errors/get_console_log after enabling or reloading the addon for actionable details.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Path to the GDScript file to validate (e.g., res://scripts/player.gd)'
        }
      },
      required: ['path']
    }
  },
  {
    name: 'create_folder',
    description: 'Create a directory (with parent directories if needed).',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Directory path (res://path/to/folder)'
        }
      },
      required: ['path']
    }
  },
  {
    name: 'delete_file',
    description: 'Permanently delete a file from the project. REQUIRES confirm=true as an explicit safety gate \u2014 omitting confirm returns an error. Creates a .bak backup alongside the original by default (disable with create_backup=false). REFUSES if the file is currently open in the editor (any scene tab or script editor tab); close the tab first, or pass force=true to bypass the check (not recommended \u2014 deleting the active scene out from under the editor can crash Godot). Use ONLY when deletion is explicitly requested; NEVER as a way to "edit" or "reset" a file (use edit_script instead). Does not delete directories.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Path to the file to delete (e.g. res://scenes/old.tscn)'
        },
        confirm: {
          type: 'boolean',
          description: 'REQUIRED. Must be explicitly set to true \u2014 safety gate to prevent accidental deletes. Calls without confirm=true fail with an error.'
        },
        create_backup: {
          type: 'boolean',
          description: 'If true (default), saves a .bak copy next to the original before deletion so the file can be recovered. Set false to delete without backup.'
        },
        force: {
          type: 'boolean',
          description: 'If true, bypass the "file is open in editor" guard. Use ONLY if you know the file is not the active scene. The guard exists because deleting the active scene tab from under the editor can crash Godot.'
        }
      },
      required: ['path', 'confirm']
    }
  },
  {
    name: 'delete_folder',
    description: 'Recursively delete a directory and ALL of its contents from the project. REQUIRES confirm=true. For a non-empty folder you must ALSO pass recursive=true — otherwise the call refuses and reports the file/sub-folder count. The whole deletion lands as a SINGLE undo entry: one mcp_undo restores every file (empty sub-directories are not restored — only files are tracked). Three safety guards each REFUSE rather than half-delete: (1) refuses if any file inside is open in an editor tab — close the tabs or pass force=true (deleting an open scene can crash Godot); (2) refuses if any external file contains a literal "res://..." string pointing into this folder (preload, ext_resource, FileAccess.open targets, autoload entries — see below) — repoint them or pass force_orphan=true (leaves broken references); (3) refuses if the contents are too large to snapshot for undo without evicting existing undo history — pass allow_no_undo=true to delete without an undo entry. Refuses to touch res:// root or the godot_mcp addon. For a single file use delete_file instead. Returns {ok, path, deleted_files, deleted_count, removed_dirs, total_bytes, undo_available, message} and, on partial failure, partial:true with delete_errors.\n\nREFERENCE-SCAN BEHAVIOR (important): The external-reference guard does a literal substring search for "res://" path strings across .tscn / .tres / .gd / .cs / .gdshader / project.godot. It is intentionally conservative — any literal path-string match counts, including runtime FileAccess.open() targets that you may consider safe to delete (the script will just re-create the file on its next run). The scanner cannot statically distinguish load-bearing references from benign strings. If the referenced list looks like runtime/regenerable targets, pass force_orphan=true rather than trying to fight the scan.\n\nFRESHLY-CREATED FILES: If you are deleting a folder containing files you just wrote in this session (via create_script etc.), Godot may not have written the auto-generated .uid sidecars yet, and they would be missed by the undo snapshot. Call rescan_filesystem before delete_folder when full undo fidelity matters.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Folder to delete (e.g. res://enemies/old). res:// is prepended if missing.'
        },
        confirm: {
          type: 'boolean',
          description: 'REQUIRED. Must be explicitly true — safety gate against accidental deletes. Calls without confirm=true fail with an error.'
        },
        recursive: {
          type: 'boolean',
          description: 'REQUIRED for a non-empty folder. Must be true to delete a folder that contains any files or sub-folders. Default false.'
        },
        force: {
          type: 'boolean',
          description: 'If true, bypass the "file open in editor" guard. Deleting an open scene/script can crash the editor — prefer closing the tabs. Default false.'
        },
        force_orphan: {
          type: 'boolean',
          description: 'If true, delete even when files inside are still referenced from outside the folder. This WILL leave broken references. Default false.'
        },
        allow_no_undo: {
          type: 'boolean',
          description: 'If true, delete a folder too large to snapshot without recording an undo entry. The deletion then cannot be reverted with mcp_undo. Default false.'
        }
      },
      required: ['path', 'confirm']
    }
  },
  {
    name: 'write_file',
    description: 'Write UTF-8 text content to any file in the project. Creates the file if missing; REFUSES to clobber an existing file unless overwrite=true. Parent directories are auto-created (override with create_dirs=false). Refuses to write to plugin source (anywhere under res://addons/godot_mcp/ except res://addons/godot_mcp/cache/) unless force=true. Refuses paths containing ".." or "." traversal segments (would escape the project tree).\n\nUse this for non-GDScript text: .gdignore, .gitignore, README.md, .json configs, .gdshader files, custom .tres data, fixture files for tests, any plain-text content. For GDScript with boilerplate (class_name / extends), prefer create_script which adds those automatically and validates the path is .gd.\n\nThe write is captured by the undo system: a single mcp_undo restores the prior content (when overwriting) or deletes the file (when creating new). Binary content is NOT supported — for binary files write a GDScript helper that produces the file and run it via run_scene, or copy/move via rename_file.\n\nEditor sync after write: the call replaces the ResourceLoader cache entry for .tscn/.tres/.gdshader/.scn so the next load() sees the new content (sets cache_evicted:true on success), force-reloads any Script resource for .gd writes (sets script_reloaded:true), and reloads an open scene tab whose .tscn was just written (sets scene_reloaded:true). The refresh runs unconditionally for the recognized extensions — flags reflect whether each step succeeded, not whether a stale cache happened to exist beforehand, because Godot keeps resources alive in places ResourceLoader.has_cached() cannot see (open tabs, EditorFileSystem index). The script editor\'s in-memory tab buffer is NOT swapped (Godot exposes no public API for that) — if you wrote to a .gd that is currently open in the editor, the user may need to refocus the tab to see the new source. When any refresh action ran successfully, an editor_refresh:{cache_evicted, scene_reloaded, script_reloaded} field is included in the response.\n\nReturns {ok, path, existed, bytes_written, message} (plus editor_refresh when applicable).',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'File path (res://... — res:// is prepended if missing).'
        },
        content: {
          type: 'string',
          description: 'Text content to write. Encoded as UTF-8. Pass an empty string to create a zero-byte file.'
        },
        overwrite: {
          type: 'boolean',
          description: 'REQUIRED to replace an existing file. Default false — calls against an existing path without overwrite=true return file_exists:true and refuse.'
        },
        create_dirs: {
          type: 'boolean',
          description: 'If true (default), missing parent directories are auto-created. If false, missing parent dirs return an error.'
        },
        force: {
          type: 'boolean',
          description: 'Bypass the plugin-source-protection guard. Required to overwrite anything under res://addons/godot_mcp/ except res://addons/godot_mcp/cache/. Default false.'
        }
      },
      required: ['path', 'content']
    }
  },
  {
    name: 'rename_file',
    description: 'Rename or move a project file. By default also rewrites every literal reference to the old path in other text-format project files (.tscn, .tres, .gd, .cs, .gdshader, project.godot) and updates any matching `autoload/*` entry in ProjectSettings, so scenes and preloads keep working. When Godot exposes a reliable scene-dirty API, clean open scene tabs that referenced the renamed file are reloaded (close + reopen), while dirty tabs are preserved and returned in scenes_skipped_dirty. On Godot versions without that API, open scene reload is skipped with scene_reload_warnings to avoid discarding unsaved changes; the files are still correct on disk, but the user may need to manually reopen the tab to clear stale editor paths. Pass update_references:false to skip both reference rewrite and reload. Returns references_updated:[{file, replacements}], scenes_reloaded:[paths], and optionally scenes_skipped_dirty or scene_reload_warnings.',
    inputSchema: {
      type: 'object',
      properties: {
        old_path: {
          type: 'string',
          description: 'Current file path'
        },
        new_path: {
          type: 'string',
          description: 'New file path'
        },
        update_references: {
          type: 'boolean',
          description: 'Update references in other files (default: true)'
        }
      },
      required: ['old_path', 'new_path']
    }
  },
  {
    name: 'list_scripts',
    description: 'List all GDScript files in the project with basic metadata.',
    inputSchema: {
      type: 'object',
      properties: {}
    }
  }
];
