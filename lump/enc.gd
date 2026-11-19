class_name LumpEnc
extends RefCounted
## Channel layout of one Lump view texture: Image.FORMAT_RGBA16, four unsigned 16-bit
## channels per texel, stored losslessly as DDS.
##
##   R  M   Mid-depth of the solid span along the view axis.  unorm16, [0, 1] volume units.
##   G  H   Signed half-thickness.  snorm16, [-1, 1].  > 0 inside the silhouette (half the
##          span), < 0 outside (minus the distance to the silhouette).  The sign gives the
##          silhouette, the magnitude the thickness: one value, two meanings.  Because it
##          crosses zero linearly, interpolation puts the silhouette edge at sub-texel precision.
##   B  Carve payload.  What the 16 bits mean is chosen per texel by the op byte in A:
##        SPAN  mode : hi byte = pocket centre tc (unorm8), lo byte = pocket half-width th
##                     (snorm8; < 0 = outside the footprint, ramping so edges are sub-texel).
##        SLAB  mode : 16 slab bits.  Bit k set = slice k of the frame is carved.  Carving is
##                     bitwise: union = OR, subtract = AND NOT, intersect = AND.
##        THROUGH op : lo byte = footprint ramp (snorm8), the hole runs the full column.
##   A  hi byte = op byte (lookup table index):
##        bits 0-1  carve op    NONE / SUBTRACT / SMOOTH SUBTRACT / THROUGH
##        bits 2-3  combine op  how this view joins the others: INTERSECT / SMOOTH INTERSECT /
##                              UNION / IGNORE
##        bit  4    mode        SPAN / SLAB (how to read B)
##        bit  5    frame       RELATIVE (fractions of this texel's own span, follows the form
##                              like a tangent-space normal map) / ABSOLUTE (volume units)
##      lo byte = flags:
##        bits 0-1  blend radius class -> BLEND_TEXELS
##        bit  2    sharp crease (mesher solves a QEF instead of using the mass point)
##        bits 3-5  material id (0-7)
##        bit  6    H curve: G holds H*H / (2*HSQ_REF) inside the silhouette instead of H.
##                  A rounded rim has H ~ sqrt(distance), which interpolation handles badly;
##                  its square is ~linear in distance, so the rim lands at sub-texel precision.
##                  Picking the curve that makes the stored quantity smooth is the geometry
##                  version of a gamma curve.
##
## Discrete fields (ops, mode, flags) are never filtered.  Each corner texel is decoded first
## and the decoded values are then interpolated: continuous values by parameter, op choices as
## one-hot weights, slab carves as per-corner distance fields.

const VIEW_FRONT := 0  # looks along z: u = x, v = y, w = z
const VIEW_SIDE := 1   # looks along x: u = z, v = y, w = x
const VIEW_TOP := 2    # looks along y: u = x, v = z, w = y
const VIEW_NAMES: Array[String] = ["front", "side", "top"]

const CARVE_NONE := 0
const CARVE_SUB := 1
const CARVE_SMOOTH := 2
const CARVE_THROUGH := 3

const COMB_ISECT := 0
const COMB_SMOOTH_ISECT := 1
const COMB_UNION := 2
const COMB_IGNORE := 3

const MODE_SPAN := 0
const MODE_SLAB := 1

const FRAME_REL := 0
const FRAME_ABS := 1

const SLABS := 16
const BLEND_TEXELS: Array[float] = [0.0, 1.0, 2.0, 4.0]

## Pocket footprint edge ramp, in texels: half-width reaches its full value this far inside.
const RAMP_TEXELS := 1.5
## Through-hole footprint ramp: the signed footprint distance saturates this many texels out.
const THROUGH_TEXELS := 4.0
## Range of an ABSOLUTE-frame pocket half-width (volume units) packed into snorm8.
const ABS_TH_RANGE := 0.25


static func q_unorm16(x: float) -> int:
	return clampi(roundi(x * 65535.0), 0, 65535)

static func d_unorm16(q: int) -> float:
	return q / 65535.0

static func q_snorm16(x: float) -> int:
	return clampi(roundi(clampf(x, -1.0, 1.0) * 32767.0) + 32768, 1, 65535)

static func d_snorm16(q: int) -> float:
	return (q - 32768) / 32767.0

static func q_unorm8(x: float) -> int:
	return clampi(roundi(x * 255.0), 0, 255)

static func d_unorm8(q: int) -> float:
	return q / 255.0

static func q_snorm8(x: float) -> int:
	return clampi(roundi(clampf(x, -1.0, 1.0) * 127.0) + 128, 1, 255)

static func d_snorm8(q: int) -> float:
	return (q - 128) / 127.0


const HSQ_REF := 0.25

static func pack_a(carve_op: int, comb_op: int, mode: int, frame: int, blend_class: int, sharp: int, mat: int, hsq: int = 0) -> int:
	var op_byte := (carve_op & 3) | ((comb_op & 3) << 2) | ((mode & 1) << 4) | ((frame & 1) << 5)
	var flags := (blend_class & 3) | ((sharp & 1) << 2) | ((mat & 7) << 3) | ((hsq & 1) << 6)
	return (op_byte << 8) | flags

static func a_hsq(a: int) -> int:
	return (a >> 6) & 1

static func encode_h(h: float, hsq: int) -> float:
	return h * h / (2.0 * HSQ_REF) if hsq == 1 and h > 0.0 else h

static func decode_h(g: float, hsq: int) -> float:
	return sqrt(2.0 * HSQ_REF * g) if hsq == 1 and g > 0.0 else g

## Snaps a pocket to what a texel can store, so baker and carver make identical decisions.
## Returns Vector3(tc, th, active) using the decoded quantized values.
static func quant_pocket(tc: float, th: float, frame: int) -> Vector3:
	var b := pack_b_span(tc, th, frame)
	var thq := b_span_th(b, frame)
	return Vector3(b_span_tc(b), thq, 1.0 if (b & 255) > 128 else 0.0)

## Encoded half-width code (0..255) for ordering pockets the way the texture sees them.
static func pocket_code(th: float, frame: int) -> int:
	return pack_b_span(0.5, th, frame) & 255

static func a_carve_op(a: int) -> int:
	return (a >> 8) & 3

static func a_comb_op(a: int) -> int:
	return (a >> 10) & 3

static func a_mode(a: int) -> int:
	return (a >> 12) & 1

static func a_frame(a: int) -> int:
	return (a >> 13) & 1

static func a_blend(a: int) -> int:
	return a & 3

static func a_sharp(a: int) -> int:
	return (a >> 2) & 1

static func a_mat(a: int) -> int:
	return (a >> 3) & 7


## th is in frame units: a fraction of the span (RELATIVE) or volume units (ABSOLUTE).
static func pack_b_span(tc: float, th: float, frame: int) -> int:
	var ths := th if frame == FRAME_REL else th / ABS_TH_RANGE
	return (q_unorm8(tc) << 8) | q_snorm8(ths)

static func b_span_tc(b: int) -> float:
	return d_unorm8((b >> 8) & 255)

static func b_span_th(b: int, frame: int) -> float:
	var t := d_snorm8(b & 255)
	return t if frame == FRAME_REL else t * ABS_TH_RANGE

static func pack_b_through(ramp: float) -> int:
	return (128 << 8) | q_snorm8(ramp)

static func b_through_ramp(b: int) -> float:
	return d_snorm8(b & 255)


## The frame a carve lives in: start and length along w.  RELATIVE uses the texel's own span,
## clamped to a minimum of one texel so the sign survives outside the silhouette.
static func frame_s0_len(frame: int, m: float, h: float, texel: float) -> Vector2:
	if frame == FRAME_ABS:
		return Vector2(0.0, 1.0)
	var hh := maxf(h, texel)
	return Vector2(m - hh, 2.0 * hh)


## Footprint ramp shared by baker, carver and ground truth: full half-width th inside, crossing
## zero exactly at the footprint edge (sd = 0) and going negative outside.
static func ramp_th(th: float, sd: float, texel: float) -> float:
	return minf(th, -sd * th / (RAMP_TEXELS * texel))


## Slab bits covering a pocket [tc - th, tc + th] in frame units.
static func rasterize_slabs(tc: float, th: float) -> int:
	if th <= 0.0:
		return 0
	var mask := 0
	for k in SLABS:
		var t := (k + 0.5) / SLABS
		if t >= tc - th and t <= tc + th:
			mask |= 1 << k
	return mask


static var _runs_cache: Dictionary = {}

## Consecutive carved slab runs of a mask, as [a0, b0, a1, b1, ...] in frame units (0..1).
static func slab_runs(mask: int) -> PackedFloat32Array:
	if _runs_cache.has(mask):
		return _runs_cache[mask]
	var out := PackedFloat32Array()
	var k := 0
	while k < SLABS:
		if mask & (1 << k):
			var s := k
			while k < SLABS and (mask & (1 << k)):
				k += 1
			out.append(float(s) / SLABS)
			out.append(float(k) / SLABS)
		else:
			k += 1
	_runs_cache[mask] = out
	return out


static func popcount16(x: int) -> int:
	var c := 0
	for k in 16:
		c += (x >> k) & 1
	return c
