# Prompt: Suggest 3D Enhancements for godot-mcp

You are working on a 3D game in Godot and using an open source tool called **godot-mcp** (https://github.com/petter-alern/godot-mcp) — an MCP server that lets AI agents control the Godot editor via a WebSocket bridge. It has 42 tools for creating scenes, adding nodes, editing scripts, and managing projects. But its **3D support has critical gaps** that make working in 3D space frustrating and incomplete.

I want your help identifying **specific open source contributions** we could make to godot-mcp to dramatically improve 3D workflows. Below is everything you need to know.

---

## How godot-mcp Works

The architecture is: `AI Client --(MCP/stdio)--> Node.js Server --(WebSocket :6505)--> Godot Editor Plugin (GDScript)`

- The **MCP server** (TypeScript) defines tool schemas and routes requests
- The **Godot plugin** (GDScript) receives tool invocations and executes them using Godot's editor APIs
- Adding a new tool requires changes in 3 places: tool definition (TypeScript), tool handler (GDScript), and the tool executor registry (GDScript)

---

## Current 3D Gaps (from codebase audit)

These are the confirmed limitations right now:

1. **No mesh assignment**: You can create a `MeshInstance3D` node, but you CANNOT give it a mesh (BoxMesh, SphereMesh, loaded .glb/.obj). The `modify_node_property` tool blocks Resource-type properties, and no specialized `set_mesh` tool exists. You literally cannot build visible 3D geometry.

2. **No material support**: No way to create or assign `StandardMaterial3D`, set albedo color, metallic, roughness, emission, or any shader parameters. Scenes are untextured.

3. **No Transform3D/Quaternion/Basis parsing**: The value parser handles Vector3 but not Transform3D, Quaternion, or Basis. You can set position/rotation/scale individually but can't set a full transform or use quaternion rotations (which avoid gimbal lock).

4. **No environment or lighting helpers**: No tools for WorldEnvironment, sky setup, or configuring lights (shadows, energy, color temperature).

5. **No 3D asset import pipeline**: No tool to import .glb/.gltf/.obj files or configure import settings. The only asset tool generates 2D PNGs.

6. **No spatial querying**: No way to get global positions, bounding boxes, distances between nodes, or a spatial overview of a 3D scene. `read_scene` returns local position/rotation/scale but not global transforms.

7. **No snapping or alignment helpers**: Zero support for grid snapping, surface alignment, or coordinate system conversion utilities.

8. **2D bias in tool descriptions**: Tool examples default to 2D types (Sprite2D, Camera2D). The hardcoded property list for scene reading includes 2D props (z_index, modulate) but omits 3D ones (global_transform, visibility_range).

---

## What the Godot Community Struggles With in 3D

From community discussions, proposals, and issue trackers:

- **Snapping is the #1 pain point**: No vertex/surface snapping until very recently (Godot 4.7 added basic vertex snap with B key). Grid snapping has bugs — gizmos drift, positions go off-grid. Snap distance is hardcoded at 10 units.
- **No ProBuilder equivalent**: Unity has ProBuilder for rapid 3D level prototyping. Godot has nothing comparable. CSG nodes are buggy and prototype-only.
- **GridMap is severely limited**: Cubic selection only, broken undo, camera rotation bugs, no dedicated maintainer.
- **Mesh asset workflow takes too many clicks**: Changing a material requires 3+ clicks per mesh. Swapping mesh variants takes 6 steps and can't batch across selections.
- **Objects spawn at camera position**: Not at logical world positions, making initial placement awkward.

Key proposals: godotengine/godot-proposals#755 (object snapping, 73+1), #3518 (TileMap3D), #10992 (GridMap overhaul), #2879 (ProBuilder-like tool), #2883 (mesh asset workflow).

---

## Relevant Research on AI + 3D Spatial Reasoning

Recent papers show how AI agents can reason about 3D placement:

- **FirePlace (2025)**: Decomposes natural language placement into geometric constraints (Parallel, CloseTo, Contact, NoOverhang, etc.) and solves them. Uses an MLLM to analyze scenes and select anchor objects.
- **Scenethesis (2025)**: Hierarchical placement (anchor -> parent -> child) with physics-aware optimization using Signed Distance Fields. Achieves 0.8% collision rate vs 6-35% for competitors.
- **QuatRoPE (2025)**: Encodes 3D positions into token embeddings so attention can compute pairwise spatial relationships.
- **Key finding**: LLMs struggle with fine-grained spatial output (distances, angles) but excel at semantic understanding. The best approaches combine LLM common sense with explicit geometric solvers.

### Practical 3D Placement Techniques an AI Agent Could Use

- **Grid snapping**: `round(pos / grid_size) * grid_size` — trivial but essential
- **Surface placement via raycasting**: Cast ray down, use collision point + normal to orient objects
- **AABB overlap checks**: Validate no two objects interpenetrate after placement
- **Support hierarchy**: Floor -> table -> lamp. Place top-down through parent-child relationships
- **Modular sizing**: Power-of-2 grid sizes (1m, 0.5m, 0.25m) for architectural elements
- **Coordinate conversion**: `to_global()` / `to_local()` for relative placement ("on top of", "next to")
- **Orthonormalization**: Clean up floating-point drift after complex transform chains

---

## Your Task

Based on your experience building this game in Godot and the gaps listed above, suggest **concrete open source contributions** we could make to godot-mcp. For each suggestion:

1. **What tool or capability to add** — name it, describe what it does
2. **Why it matters** — which pain point it solves, for us and the community
3. **Rough scope** — is it a small PR (new tool, ~100 lines each side) or a larger feature?
4. **Priority** — what would unblock us the most right now vs. nice-to-have?

Think about:
- What do you keep wishing the AI agent could do but can't?
- Where do you lose the most time manually placing/configuring 3D objects?
- What spatial reasoning capabilities would make the AI actually useful for 3D level design?
- Are there patterns from our game that would generalize well to other Godot 3D projects?
- Could we implement constraint-based placement (inspired by FirePlace) as an MCP tool?
- Should there be a "3D scene analyzer" tool that gives the AI a spatial understanding of what's already in the scene?

Prioritize suggestions that solve real problems we're hitting, not hypothetical ones. The best contributions will be ones that meet our needs AND help the broader Godot community.
