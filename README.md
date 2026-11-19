# Lump of Gold

Proof of concept: a 3D sculpt stored entirely in three small 2D textures, rebuilt into a mesh
on demand, and carved by writing into the textures.

**Live demo (runs in the browser):** https://wolfpox.github.io/lump-of-gold/

The browser build is single-threaded, so the page pauses briefly while the mesh rebuilds
(about 1–2 s at 1×; 4× takes much longer in a browser). Export downloads a zip with
`lump.glb` and the three `.dds` images.

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
