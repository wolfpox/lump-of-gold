# Relief Cards: design plan

A tool for building segmented, game-ready character parts from flat drawings. Each part is a
two-sided relief **card**, placed in an assembly the way it will sit in the final model, then
exported as a low-poly mesh with baked detail maps.

This document is the source of truth for where the project is going. Update the roadmap status
when a step lands.

---

## 1. Target

- **Segmented characters, PS1/N64 style.** Separate rigid parts (each finger segment, palm,
  forearm, bicep, ...) that a rig moves without joints or blended meshes. No seamless body.
- **Parts don't need to be low-poly in themselves.** The overall composition is what stays
  simple. Detail comes from baked maps: normals, ambient occlusion, curvature, surface
  properties. This is expected to be the biggest visual win.
- **Out of scope:** rigging, joints, animation. The tool positions parts in their final
  relation and exports them; Godot does the rest.
- **Export target:** Godot 4 (`.glb` + textures). Everything must import cleanly into Godot.

Pipeline:

```
Draw  ->  Build height  ->  Place in assembly  ->  Bake (low mesh + maps)  ->  Export .glb
outline,   layers, inflate,    transform + pivot      normal, AO, curvature,      one mesh
line art   brushes, 2 sides    at the joint           height, thickness           per part
```

## 2. The card (core unit)

```
CARD
├─ Shape          outline as vector curves with add/subtract, sharp at any scale
├─ Height layers  a stack, like image layers but for height
│   ├─ gradients      linear = ramp, radial = dome, distance-from-edge = edge falloff
│   ├─ vector strokes ridges and grooves with a width + height profile
│   ├─ inflate        round volume from the outline              (BUILT)
│   └─ raster sculpt  brushes for organic detail                 (BUILT)
│   each layer: blend mode (add / max / min / subtract=carve) + its own mask
├─ Surface layers colour, roughness, metal; can use baked maps as masks
├─ Two sides      front and back stacks sharing one outline     (BUILT)
├─ Placement      transform in the assembly + pivot (the joint location)
└─ Base           flat; later bent along a spline (twist, taper) or wrapped (cylinder/sphere)
```

What exists today (`relief/`) is one card: flat, unplaced, raster layers only.

### The one hard limit

A card is one outline with a front height and a back height. **It can't fold back over itself
along its own facing direction** (a fingertip curling toward the viewer, a whole head seen all
round). Such shapes become:

- several overlapping cards (normal for this style),
- a spline-bent card, or
- later, a wrapped base (height pushed out from a cylinder or sphere instead of a plane).

Overlaps at joints are a feature: a ball-shaped "cap" card (inflated disc) hides gaps at elbows
and knees the way old games did.

## 3. Vectors: why they are the foundation

- **Curves are the source of truth; textures become a cache.** The 512² layers are rendered
  from the vectors at whatever resolution is needed. Preview and export can use different
  resolutions from the same drawing.
- **Exact edge distance.** Distance to a curve is computed mathematically. This replaces the
  current raster signed-distance pipeline (feature transform + sub-pixel contour points + blur,
  see section 9), which exists only because the outline is a raster mask.
- **Gradients are height primitives.** Radial = dome, linear = ramp, distance-from-edge = edge
  falloff. Layering them with max/min gets far before any brushwork.
- **Layers.** Blend modes (add, max, min, subtract) plus per-layer masks, non-destructive.
- **Flow lines (user question: can we steer which way slopes go?).** Yes, three forms:
  1. **Ridge / valley / contour strokes** with a height: the solver fills smooth slopes between
     those lines and the outline (diffusion-curve style). Use a biharmonic (smoother) solve so
     lines don't produce tent-like creases.
  2. **Slope direction hints:** strokes or painted regions meaning "downhill goes this way",
     as gradient constraints in the same solve.
  3. **Anisotropic inflate and smoothing along the flow:** round across, long along (fingers);
     a Smooth brush that only smooths along the flow keeps folds and muscle direction crisp.

  1 and 2 are planned as one "guide curves" layer feeding the same solver as inflate, so they
  stay non-destructive. The solver will need to move to the GPU when it gains these constraints.
- **Editing UI:** a good pen tool (handles, snapping, boolean shape ops) is a lot of work.
  **Import SVG first** (draw in Inkscape/Illustrator), build in-app vector tools once the
  pipeline is proven.

## 4. Baked maps

Normally a bake projects a high-poly sculpt onto a separately unwrapped low-poly mesh with ray
casting, cages and seam fixes. **A card's high and low versions share the same 2D layout (the
card's canvas), so every map comes straight from the heightfield and the bake can't misfire.**

| Map | Source | Used for |
|---|---|---|
| Normal | full-res height vs the low mesh at the same point | sculpted detail on a cheap mesh |
| Ambient occlusion | horizon tracing over the heightfield | creases, contact shading |
| Curvature / cavity | how sharply the height bends | edge wear, dirt in creases, ridge highlights |
| Height | the composed heightfield | parallax, masks |
| Thickness | front height + back height | light through ears, fingers, leaves |

- **Self-AO by default.** Parts move under the rig, so AO from a neighbouring part would be wrong
  once animated. Neighbour AO is opt-in for parts that never move relative to each other.
- **Steep rims stretch texels.** Where an inflated edge drops straight to the outline, the flat
  canvas gives it few texels. Softer edge profiles or a capped slope help.
- AO is measured above the surface's own slope (HBAO style), not above flat. Measuring above
  flat made every steep rim read as occluded.

## 5. Low-poly mesh

- Spend triangles on the **outline and side profile**: the one thing a normal map can't fake.
- Fill the interior by **error-driven insertion**: add the vertex where the mesh is furthest from
  the true height, repeat to a triangle budget or error target. The budget is a ceiling; flat
  areas cost almost nothing.
- **Budget per part** (e.g. ~150 triangles for a finger segment, ~500 for a palm).
- Front and back **share the rim vertices**, so each part is closed.
- Known issue: triangulation is unconstrained Delaunay with outside triangles dropped by
  centroid test. Deep concave notches can get gaps or slivers. Fix with a constrained
  triangulation (CDT) when it matters.

## 6. Assembly view

- **Tree of cards and groups**, e.g. Arm > Forearm, Hand > Palm, Index > Segment 1-3; transform
  per card relative to its parent.
- **Pivot per card** = joint location = mesh origin on export, so the part rotates correctly
  when attached to a bone in Godot. Optionally name parts after bones so a Godot script can
  attach them automatically.
- **Only the active card is editable.** The flat canvas shows the active card; the 3D view shows
  it in place with the others as context (dimmed or normal but not clickable). Isolate toggle.
- **Placement help:** click another card's surface to put this card's pivot there, aligned to
  that surface (knuckles onto the palm edge).
- **Linked duplicates and mirrored links:** design one finger segment and reuse it at different
  scales; the left hand is a mirrored link of the right. Edit once, all copies follow.
- **One texel density** for the whole assembly so all parts are equally sharp.
- **Atlas export:** all fronts and backs packed into one texture set, one material, one draw
  call per character.
- **Game view toggle:** the budget mesh lit with full-res normals + AO (BUILT for one card).

## 7. Cards in 3D: splines, bending, hair

- **Bent cards:** the card's length follows a 3D spline, its width follows the spline's side
  direction; a twist curve rotates it along the way and a width curve tapers it. Uses: hair
  locks (a drawn clump outline + height for volume, swept with twist: game "hair cards" but with
  real thickness and two sides), tails, capes, belts.
- A bent card is still one rigid part, or several segments if it needs to swing.
- **Self-intersection:** if a card is thicker than the spline's bend radius, the inner side
  folds through itself. Needs a limit, a warning, or thickness that thins in tight bends.
- **Splines as attachment rails:** parts snap to a point along a curve (finger splines starting
  at knuckle points on the palm edge; a finger is then a spline with an inflated round shape).

## 8. Roadmap

| # | Step | Status |
|---|---|---|
| 0 | Relief editor: shared outline, front/back canvases, brushes with flow + opacity, inflate and edge modifiers, real-time 3D | Built |
| 1 | Game view: triangle budget, real low-poly mesh, full-res normals + AO on it, wireframe / flat-shading toggles | Built |
| 2 | Export one card: low mesh + baked normal, AO, curvature maps to `.glb`; verify in Godot | **Next** |
| 3 | Assembly: card tree, gizmo, pivots, active-card editing, linked duplicates and mirroring | Planned |
| 4 | Surface layers: colour / roughness / metal painting with masks from AO and curvature | Planned |
| 5 | Vector shapes and gradient layers: outlines, gradient fills, ridge strokes (SVG import first) | Planned |
| 6 | Whole-character atlas export; spline-bent cards for hair | Planned |

Each step should end in something the user can open and try (see section 10).

### Open questions

- **Texture size per card side:** 128-256 px for a chunky look, or 512+ for crisp detail.
- **Atlas or separate textures:** one shared texture set per character, or one per part.
- **Bone attachment:** match part names to bone names for automatic attachment, or attach by hand.
- **Concave outlines** in the low mesh: when to switch to a constrained triangulation.

## 9. Current implementation (as of 2026-11-19)

Main scene `relief.tscn`; the earlier three-view texture demo is still `main.tscn`.

| File | Role |
|---|---|
| `relief/relief_main.gd` | Editor UI, input, strokes, undo, save/load, 3D view, AO viewports, game-view scheduling |
| `relief/relief_doc.gd` | Document layers; signed distance + Poisson inflate fields; CPU height function (mirror of the shader) |
| `relief/relief_brush.gd` | Brush engine (flow accumulates per dab, opacity caps the stroke; smooth works in place) |
| `relief/relief_common.gdshaderinc` | `surf()` height composition shared by all shaders, B-spline sampling, AO lookup |
| `relief/relief3d.gdshader` | Sculpt view: 512² grid displaced on the GPU, rim vertices snapped to the outline |
| `relief/relief2d.gdshader` | Flat canvas: hill-shaded current side, mask outline, line art, contours |
| `relief/relief_ao.gdshader` | Horizon AO bake per side, rendered in a SubViewport on change |
| `relief/relief_game.gdshader` | Game view: low-poly mesh lit with full-res normals + AO |
| `relief/relief_mesher.gd` | Low-poly mesh: outline trace + Douglas-Peucker, error-driven interior insertion, Delaunay |

Key formula (per side, shader and CPU must match):

```
z = edge_profile(sd) * max(core/2 + plate + inflate * phi^roundness + sculpt, 0)
```

- Layers are 512×512 `FORMAT_RF`; `phi` is 256². The back's layers use the same texel grid as
  the front (texel i = same column through the part); the back canvas only *displays* mirrored.
- Front faces +Z, back faces -Z, card is 1 unit wide, centred at the origin.
- `sd` and `phi` recompute in a WorkerThreadPool task (~1.5 s) after silhouette edits; the game
  mesh rebuilds in a task (~0.5 s) 200 ms after edits stop.
- Signed distance lessons: a plain pixel EDT leaves stair-step ripples that the round edge
  profile amplifies. The working pipeline: blur the mask lightly, find sub-pixel 0.5-contour
  points on edge pixels, feature transform to the nearest edge pixel, min distance over its 3×3
  neighbours' contour points, then a Gaussian-ish blur (distance fields are linear, so blur
  doesn't move slopes). Vector outlines (step 5) will replace all of this.
- Inflate: Poisson solve (laplacian(phi) = -1 inside, 0 on the edge) coarse-to-fine with
  red-black SOR, finished with plain Gauss-Seidel sweeps to remove checkerboard noise.

## 10. Working notes for future sessions

- **Show before testing.** The user wants a runnable visual demo early; long automated test runs
  come second.
- Run: `flatpak run org.godotengine.Godot --path "/mnt/storage/Games/Gamedev/Lump of Gold"`
  (Godot 4.7.2 flatpak, Compatibility renderer).
- After adding a new `class_name` script, run once with `--headless --import` or other scripts
  fail to parse it.
- Screenshot mode: `-- "--shot=$PWD/out/name.png"` paints demo strokes, waits until background
  work settles, saves, quits. Keywords in the file name switch extras: `sil` (silhouette
  stroke), `back` (back side), `game` (game view), `wire`, `flat`. Quote the path (the folder
  name has spaces) and save inside the project: the flatpak can't write to the host `/tmp`.
- `out/` and `tools/` are git-ignored (screenshots, timing scripts, saves at `out/relief.lump`).
- Pushes to `main` redeploy the web demo (`.github/workflows/pages.yml`); the user is fine with
  that. The web build of the relief editor is untested.
