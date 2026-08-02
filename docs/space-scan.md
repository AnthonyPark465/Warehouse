# Space Scan

Space Scan is selected independently from **Scan shelf with AR** in the Place
workflow. Active acquisition is guided corner-by-corner. The camera path and raw
frame stream never become the storage boundary. The obsolete continuous and
sectioned trace models remain decodable only for legacy records.

## Workflow

1. Select **Scan open space** and classify the base as floor, tabletop,
   workbench, raised platform, counter, custom horizontal surface, or unknown.
2. Lock the base plane, aim at one physical corner, and press **Scan Corner**.
   A bounded depth patch is accumulated for 1–2 seconds across independent frames.
3. Review the fixed candidate, uncertainty, method, and direct/inferred provenance.
   Accept it or rescan it. Inferred plane-intersection corners always require an
   explicit acceptance.
4. Continue in boundary order without declaring a corner count. After three
   accepted corners, use **Add Corner**, **Undo Last Corner**, **Close Shape**, or
   **Rescan Selected Corner**. Accepted points remain frozen in the locked plane.
5. Review the raw straight-segment polygon and any optional rectangle correction,
   then explicitly approve one. Corrections are never silently applied.
6. Either measure bottom/top with AR or enter a validated height in centimetres.
7. Set the main approach direction and approve the scan.
8. Review the extruded bottom/top/wall outline, height, surface type, and separate
   geometry confidence. Save the approved record or calculate placement.

Open spaces are stored in shelf-local centimetres with an origin on the base,
orthogonal in-plane axes, a positive vertical axis, explicit top definition, and
one or more access directions. Firestore stores current geometry in `spaces` and
archives replaced versions transactionally.

The placement adapter reuses the production placement engine. It enforces the
approved outer polygon, constant top height, bottom support plane, safety margin,
existing-object collision rules, access/insertion rules, and every excluded
polygon. An exclusion is tested for corner containment, edge intersection, and
full enclosure, so a small hole underneath a large product is not missed.

## Accuracy and conservative dimensions

Schema version 6 records bounded local depth evidence, fitted edges or planes,
original and accepted candidates, residual, coverage, independent frame count,
view diversity, uncertainty, tracking, coordinate epoch, provenance, approval,
and coordinate space. Repeated nearby frames do not count as independent evidence.
Nearly parallel edges or planes cannot manufacture an intersection.

The acceptance policy allows up to 2 cm uncertainty at 1 m, 4 cm at 3 m, 5 cm
at 5 m, 8 cm at 8 m and 10 cm at 20 m. Above 5 cm is approximate-planning-only,
never fit-critical evidence. Above 5% of a measured dimension requires a manual
dimension. Review displays measured, uncertain and conservative usable dimensions
separately. Placement clearance is an additional 0.5 cm per side and is not
double-counted as uncertainty. A fit within twice the uncertainty requires local
or manual verification.

Global approximate geometry cannot authorize close-fit placement. The large-zone
model requires an accepted local measurement at the placement site.

## Conservative limits and implementation status

The active LiDAR implementation supports tabletop/platform termination-edge
intersections and inside shelf/box supporting-plane intersections. If neither is
reliable it asks for a rescan or lower-confidence manual dimensions. It does not
claim automatic semantic room reconstruction. ARPlane classification,
mesh/depth agreement and stability contribute to capture, but automatic wall
intersection, image-edge extraction, automatic table-leg/column detection,
RoomPlan, variable-height ceilings, multiple disconnected regions, and automatic
corridor/regulatory exclusions remain future work. Excluded-region geometry is
fully modeled, persisted, visualized and honored by placement, but its current UI
must be populated by an importing/onboarding workflow rather than automatic mesh
segmentation.

Circle acquisition is explicitly follow-up work; the app does not approximate a
circle with noisy corner detection. Robust circle fitting and overlapping-zone
alignment remain non-live core models.

Physical validation is required on representative LiDAR devices and materials.
Glass, mirrors, thin edges, featureless surfaces, moving obstacles and incomplete
viewpoints must be manually confirmed or rejected; simulator tests cannot validate
their optical behavior.

## Device test

1. Scan a known rectangular floor zone and a tabletop, including one rotated
   relative to the room axes.
2. Confirm the point button is disabled during motion/tracking loss and that
   relocalization invalidates unfinished points.
3. Keep a concave raw boundary, then repeat with a near-rectangle correction.
4. Enter `120`, `75.5`, `0`, a negative value and an extremely large height;
   only the first two should proceed.
5. Measure a physical top and verify the displayed height against a tape measure.
6. Confirm the access arrow points from the approach side into the space.
7. Save, reload, and verify centimetre scale, surface type, boundary, exclusions,
   height, approval and geometry version.
8. Attempt placement crossing the outer edge, an exclusion, and the top. Each
   must be rejected. Repeat on non-LiDAR hardware if that deployment is required.
9. Move the camera without pressing **Scan Corner** and verify no boundary point
   appears. Scan one corner, move elsewhere, and verify the accepted marker does
   not move. Exercise accept, rescan, undo, selected-corner replacement, and close.
10. Verify review shows each corner's provenance, RMS residual and uncertainty,
    plus conservative dimensions and the separate 0.5 cm-per-side clearance.
