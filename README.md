# Lump of Gold

Proof of concept: a 3D sculpt stored entirely in three small 2D textures, rebuilt into a mesh
on demand, and carved by writing into the textures.

**Live demo (runs in the browser):** https://wolfpox.github.io/lump-of-gold/

The browser build is single-threaded, so the page pauses briefly while the mesh rebuilds
(about 1–2 s at 1×; 4× takes much longer in a browser). Export downloads a zip with
`lump.glb` and the three `.dds` images.

## Relief editor (current main scene: `relief.tscn`)

The plan this is heading toward (cards, vectors, baked maps, assembly, roadmap) is in
[`docs/DESIGN.md`](docs/DESIGN.md).

Draw a flat silhouette and line art, build height on it with soft brushes, then flip to the
back, which shares the same outline and is a second canvas. Code is in `relief/`.

- Layers (512×512 floats): shared silhouette mask, a sculpt layer per side, line art per side.
- Shape modifiers per side (non-destructive, live): Inflate (Poisson "balloon" from the
  outline), Inflate profile, Plate height, Edge falloff width + shape (round/soft/chamfer/cove),
  and a shared Core thickness.
  Surface = `edge(sd) * max(core/2 + plate + inflate * phi^profile + sculpt, 0)`.
- Brushes: Raise, Lower/Carve, Smooth, Flatten, Reset to base, Silhouette ±, Line art ±.
  Flow builds up per dab; Opacity caps what a single stroke can reach. Pen pressure drives flow.
- Keys: F flip side, [ ] brush size (or mouse wheel on the canvas), X mirror symmetry,
  1–9 tools, Ctrl+Z undo, Ctrl+S save (`out/relief.lump`). Drop an image on the window to
  use it as line art.
- The 3D view displaces a 512×512 grid on the GPU, so it is real-time at full resolution.
- **Game view (G):** builds the real low-poly mesh for a triangle budget per side (outline
  traced and simplified, interior filled by error-driven vertex insertion, front and back share
  the rim) and lights it with full-resolution normals and ambient occlusion from the
  heightfield, i.e. what a baked normal map + AO map will look like in Godot. Wireframe and
  "flat shading" toggles show what the mesh alone looks like. Code: `relief/relief_mesher.gd`,
  `relief/relief_game.gdshader`, AO bake `relief/relief_ao.gdshader`.

The earlier three-view texture sculpt demo is still `main.tscn`.

## Run the demo locally

Open the folder in Godot 4.7 and press F5, or:

    flatpak run org.godotengine.Godot --path "/mnt/storage/Games/Gamedev/Lump of Gold"

Left-drag to orbit, mouse wheel to zoom, click the lump to carve. "Mesh detail" rebuilds the
same textures at 1×/2×/4× resolution. "Export" writes `out/demo/lump.glb` plus the three
`.dds` textures.

## How it works

- Three 64×64 RGBA16 images: FRONT (looks along Z), SIDE (along X), TOP (along Y). 96 KB total.
- Each texel describes the column of space behind it:
  - **R**: where the middle of the solid is along that column.
  - **G**: how thick it is (positive) or how far outside the outline (negative).
  - **B**: carves. Either one pocket (centre + width) or 16 on/off bits, one per depth slice,
    which allows several pockets in one column.
  - **A**: a small lookup byte that says how to read B, which boolean operation to apply,
    how this view combines with the others, sharp/soft, and material.
- The three views are intersected (like carving a block from front, side and top drawings),
  then the carves are subtracted. That gives overhangs, undercuts, tunnels and hidden voids.
- The mesh is extracted from that field at any grid resolution. The textures never change
  when you change mesh detail.
- Carving finds the image whose axis best matches the camera, works out the depth of the
  click inside that texel's column, and writes a pocket into B and A for the texels under the
  brush. If a texel already holds a different pocket, it switches itself to slab-bit mode and
  ORs both pockets in.

Code: `lump/enc.gd` (channel layout), `lump/texture_set.gd` (decode + reconstruction),
`lump/field.gd` (combining views and carves), `lump/carver.gd`, `lump/mesher.gd`.
Automated checks: `tests/run_poc.gd`.

The web build is produced by `.github/workflows/pages.yml` on every push to `main`
(Godot 4.7.2, Compatibility renderer, single-threaded web template).
