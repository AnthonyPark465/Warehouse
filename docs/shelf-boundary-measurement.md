# Shelf boundary measurement

## Active constrained-compartment flow

The retired automatic path captured a fixed centre-pixel patch, mixed multiple
visible surfaces, and selected line/plane intersections near the reticle. At close
range the patch covered too little physical area; hard-coded depth confidence and
nearly stationary frames could still inflate evidence. The resulting corner was
therefore vulnerable to foreground objects and crosshair bias.

The replacement keeps one locked world coordinate epoch through review:

1. Valid depth under the broad region cue creates a local 3D target volume.
2. Sampling radius is derived from focal length and depth, so physical coverage
   does not collapse close to the shelf.
3. Bottom, back, left, right, top, and front-opening evidence are collected in
   separate labeled buffers. Evidence is never pooled across labels.
4. Confidence, tracking, coordinate epoch, target containment, connectedness,
   orientation, height, and accepted-plane relationships filter each buffer.
5. Robust plane fitting is refined with inliers and reports RMS/max residual,
   two-axis coverage, independent views, and uncertainty.
6. Three accepted planes define each corner. Width, height, and depth come from
   opposing planes, never a tap, the reticle, or camera trajectory.
7. The approved result is transformed once into shelf-local metres/centimetres
   (`x=width`, `y=up`, `z=opening-to-back`) for placement.

Relocalization, app backgrounding, or a coordinate-epoch change invalidates an
unfinished scan. Points from different epochs are never combined.

## Capture and correction

Constrained compartments use an explicit guided state machine: find compartment,
confirm target, scan one labeled surface, review/accept or rescan, calculate
intersections, review geometry, verify the usable opening, and then select access
direction. Rescanning one surface invalidates and recomputes only corners and
dimensions supported by that plane.

The active compartment estimator fits only the surface the user is currently
scanning. It requires meaningful camera translation/view-angle change and
deduplicates correlated spatial samples. Connected-component selection prefers
the component near the selected surface seed. A second similarly supported
component is reported as ambiguous rather than silently chosen.

The default device operating range is configurable (currently 0.15–5 m). A frame
needs at least 1.5 cm camera translation or 4° viewing change to add independent
evidence. Plane acceptance currently requires at least 24 deduplicated inliers,
7 cm physical coverage on both fitted axes, at least four independent views,
RMS at most 8 mm, maximum residual at most 25 mm, plausible orientation/location,
and uncertainty within the centralized accuracy policy. These are initial safety
limits pending device validation, not accuracy claims.

The floor is rejected during bottom capture when it is below/disconnected from
the selected shelf region. During back/side capture, horizontal components and
planes geometrically incompatible with accepted bottom/back evidence are rejected.
Products and cables must be disconnected, smaller/inconsistent, or incompatible;
when ambiguity remains, the scan fails for user choice/rescan.

Rectangle likelihood is not based on four points alone. It combines corner-angle
error, opposite-side parallelism, diagonal lengths and midpoint agreement,
planarity, and scan confidence. A deterministic oriented rectangle fit averages
the measured opposite-edge directions and extents. Optional expected dimensions
are constraints, not silent snapping; disagreement above 15% forces a rescan.
Suggested corrections are removed if any point moves over 3.5 cm, average movement
exceeds 2 cm, or dimensions change over 12%.

Irregular and concave polygons retain their vertices and topology. The software
does not replace them with a convex hull. One unambiguous four-point bow-tie may
be reordered for review; other self-intersections are rejected. Holes and
disconnected usable regions require separate shelf compartments and are not
represented by a single boundary.

## Review, persistence, and placement

The review shows dashed raw geometry against solid suggested geometry, one-decimal
dimensions, angles, confidence, movement, and reason codes. The operator chooses
rectangular, irregular, or automatic intent and whether points mean the inner
usable area, opening, or outer shelf. They must keep the original, accept the
suggestion, or rescan a selected corner. A draft can never be used for placement.

`ShelfGeometryRecord` stores immutable raw input, optional suggestion, approved
geometry, intent, boundary meaning, confidence, reason codes, units, coordinate
space, device/corner metadata, approval, and revision. Schema-v7 scanned boundary
evidence additionally stores target volume, labeled captures, bounded observations,
inlier IDs, planes, residual/coverage/view metrics, uncertainties, coordinate
epoch, corner provenance/supports, opening/interior dimensions, and approvals.
`PlacementRepository`
archives the previous record and uses a Firestore transaction/version check.
Existing products are revalidated; an incompatible correction is rejected instead
of silently moving products.

The placement engine tests the complete product footprint against the approved
polygon and applies the 1 cm safety inset separately. Concave cutouts remain
unusable. Shelves written before geometry version 2 continue through the legacy
rectangular path; new version-2 shelves require explicit approval.

## Confidence and limitations

Scan confidence weights corner sampling confidence (55%), plane residual (30%),
and usable area evidence (15%). Rectangle confidence weights angles (25%),
parallelism (25%), diagonal evidence (20%), planarity (15%), and scan confidence
(15%). Correction confidence adds movement cost and is diagnostic; it never
approves a correction.

ARKit still cannot guarantee centimetre accuracy on glass, mirrors, featureless
black/white surfaces, wire racks, flexible surfaces, motion blur, or thermal/
tracking degradation. Image-edge refinement and automatic divider/door extraction
are not connected to AR capture. Robust circle fitting and large-zone overlap
checks exist as deterministic models but are not live capture modes. Curved/non-planar shelves, holes and disconnected
regions remain unsupported in the shipping UI. The UI blocks or asks for a rescan
rather than manufacturing precision. Physical validation is still required on
both LiDAR and non-LiDAR devices.

## Manual device test

1. Use a known 80 × 40 × 50 cm empty shelf and confirm a broad target volume.
2. Scan bottom/back/left/right/top/front separately without aiming at corners.
3. Verify accepted/ignored points and the fitted translucent plane before each
   acceptance; deliberately include the floor below and one foreground box.
4. Rescan only left; only corners/dimensions supported by left may change.
5. Add a front lip and verify automatic fit is blocked until the smaller opening
   is independently verified.
6. Test taper and warp; neither may be silently rectangularized.
7. Repeat across phone distance/view angle, dark/glossy/wire materials, and after
   tracking loss/relocalization. Record signed error, repeatability, rejection,
   and overestimation for each condition.
8. Confirm uncertainty and operational clearance are shown/subtracted separately,
   and a remaining fit margin below twice uncertainty requires manual verification.
