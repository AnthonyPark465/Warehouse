# Shelf boundary measurement

## Coordinate and data flow

The old scanner committed one centre-screen raycast immediately, flattened every
point to `y = 0.006` in the selected AR plane anchor, and calculated width and
depth from world-aligned X/Z extrema. This amplified hand motion and foreground
hits, discarded measured elevation, and made rotated or irregular shelves look
larger than their usable surface.

The replacement keeps one coordinate system through review:

1. ARKit raycasts and, when present, scene depth produce world-space samples.
2. Samples are transformed once into the selected `ARPlaneAnchor` local space.
3. A rolling 0.8 second window is depth-clustered and robustly filtered before a
   corner can be placed.
4. A least-squares plane is fitted to all accepted corners. Polygon analysis is
   performed in anchor-local X/Z; small Y residuals are projected to that plane.
5. Raw, suggested, and explicitly approved boundaries remain in metres and are
   tagged `planeAnchorLocal` while scanning.
6. After the user confirms the shelf front, the approved boundary is transformed
   once into shelf-local centimetres (`x=width`, `y=up`, `z=opening-to-back`).

Relocalization, app backgrounding, or a coordinate-epoch change invalidates an
unfinished scan. Points from different epochs are never combined.

## Capture and correction

Open straight-sided boundaries use an explicit guided state machine: find and
lock the base plane, aim, scan one local patch, review a corner candidate, accept
or rescan it, add more corners, close, and review geometry. A selected accepted
corner can be rescanned without rebuilding unrelated corners. Accepted positions
are frozen in the locked plane and only straight segments join them. Camera motion
between button presses produces no boundary geometry.

The LiDAR estimator first tries two robust termination-edge fits on base-plane
points (tabletops/platforms). It then tries two adequately supported adjacent
planes (inside shelves/boxes). Both reject poor coverage, correlated frames,
large residuals, nearly parallel supports, and remote intersections. Plane-derived
corners are marked inferred and require explicit approval. Glass, mirrors, wire,
reflective metal, dark featureless material, occlusion, and very small spaces must
fail safely or use the labelled lower-confidence manual path.

LiDAR devices require at least 7 stable samples per corner; standard world
tracking requires 11. Invalid ranges and non-finite values are removed, samples
are split at 3 cm depth gaps, and the largest depth cluster wins (nearest breaks
ties). Coordinate medians and median absolute deviation reject spatial outliers.
The placement button remains disabled until RMS spread is at most 0.8 cm on
LiDAR or 1.2 cm without LiDAR.

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
space, device/corner metadata, approval, and revision. `PlacementRepository`
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

1. Use a known 80 × 40 cm shelf. Start a shelf scan and move slowly until tracking
   is normal.
2. Aim at each inner usable corner clockwise. Confirm the button stays disabled
   until the status says **Ready to place**.
3. Create one deliberately unstable corner, then select and rescan only that corner.
4. Review automatic, rectangular, and irregular intent. Verify no suggestion is
   applied until **Accept Suggested Correction** is pressed.
5. Enter matching expected dimensions, then dimensions over 15% different; the
   latter must require verification/rescan.
6. Keep the raw shape once and accept the correction once. Confirm the chosen
   geometry, confidence, units, and revision are preserved.
7. Measure a 5 cm clear height. It must be accepted and displayed as 5.0 cm.
8. Confirm the opening-to-back arrow, finish, and verify every proposed product
   corner stays inside the approved outline plus its separate safety margin.
9. Repeat rotated, in landscape, after background/resume, and on a non-LiDAR
   device. Backgrounding or relocalization during an unfinished scan must require
   a fresh coordinate-consistent scan.
