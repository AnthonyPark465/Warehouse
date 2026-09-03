# Space Scan

Space Scan is selected independently from **Scan shelf with AR** in the Place
workflow. The active LiDAR path for a box, cabinet, shelf bay, or other constrained
compartment is surface-first. A screen point never becomes a final corner. Legacy
corner and border records remain decodable, but do not satisfy schema-v7 accuracy.

## Workflow

1. Find the compartment, point broadly at its middle, and confirm the cyan local
   target volume.
2. Point at the middle of the requested surface and scan exactly one label at a
   time: bottom, back, left, right, top, then front opening/frame.
3. Move slowly between meaningfully different camera positions or view angles.
   Elapsed time and raw frame/point totals do not count as independent evidence.
4. Review accepted points, ignored points, the translucent fitted plane, coverage,
   residuals, view diversity, and uncertainty. Accept or rescan that surface.
5. After the required planes are accepted, review the eight calculated plane
   intersections and their supporting-surface provenance.
6. Review maximum interior dimensions separately from the smallest verified
   usable opening. If a lip, frame, track, trim, taper, or overhang is not measured,
   automatic placement remains blocked rather than using the larger interior.
   The interior may be reused as the opening only after the user explicitly confirms
   that no lip, track, trim, or smaller frame exists.
7. Approve raw geometry. A proposed rectangular correction is a separate,
   explicitly approved operation and may not hide measured taper.
8. Continue to access direction and conservative placement review only after the
   usable opening and uncertainty gates pass.

Open spaces are stored in shelf-local centimetres with an origin on the base,
orthogonal in-plane axes, a positive vertical axis, explicit top definition, and
one or more access directions. Firestore stores current geometry in `spaces` and
archives replaced versions transactionally.

The placement adapter reuses the production placement engine. It enforces the
approved outer polygon, constant top height, bottom support plane, safety margin,
existing-object collision rules, access/insertion rules, and every excluded
polygon. An exclusion is tested for corner containment, edge intersection, and
full enclosure, so a small hole underneath a large product is not missed.

## Target volume and evidence

The initial seed uses valid scene depth within the configurable 0.15–5 m operating
range; 15 cm is a minimum, not a maximum. The initial volume is locked to one
coordinate epoch. Observations outside it are ignored. The depth-pixel radius is
calculated from focal length and seed depth to preserve physical coverage: close
targets use more pixels, while distant targets use fewer pixels within configured
bounds.

The active capture reads ARKit's per-pixel confidence map, requires normal
tracking, rejects mixed epochs, requires at least 1.5 cm camera translation or a
4° view change, deduplicates 1.2 cm voxels, selects connected evidence near the
surface seed, and robustly fits/refines one plane. Validation requires two-axis
coverage, inlier support, view diversity, plausible orientation/location,
residual limits, uncertainty, and consistency with already accepted planes.

Floor rejection is layered: volume containment, the selected label, orientation,
height relative to accepted bottom/top, connected components, seed proximity, and
relationships to accepted planes. Equal plausible components produce an ambiguity
and require selection/rescan. Flatness alone is never sufficient.

## Accuracy and conservative dimensions

Schema version 7 records target volume, label, bounded observations, accepted
inlier IDs, fitted plane, residuals, two-axis coverage, independent views,
uncertainty, coordinate epoch, approval, calculated corners, supporting planes,
opening/interior dimensions, and schema version. Nearly parallel planes and
intersections outside the target volume are rejected. Plane uncertainty is
propagated through the three-plane solve and into dimensions.

The acceptance policy allows up to 2 cm uncertainty at 1 m, 4 cm at 3 m, 5 cm
at 5 m, 8 cm at 8 m and 10 cm at 20 m. Above 5 cm is approximate-planning-only,
never fit-critical evidence. Above 5% of a measured dimension requires a manual
dimension. Review displays measured, uncertain and conservative usable dimensions
separately. Placement clearance is an additional 0.5 cm per side and is not
double-counted as uncertainty. A fit within twice the uncertainty requires local
or manual verification.

Global approximate geometry cannot authorize close-fit placement. The large-zone
model requires an accepted local measurement at the placement site.

## Fallbacks and safe rejection

The compartment workflow does not solve every open shape. A tabletop requires
multi-view tabletop evidence followed by true termination-edge evidence; filled
interior points may not be used as arbitrary boundary lines. An imaginary region
in a continuous floor has no LiDAR boundary and requires physical markers,
detectable walls/structures, manual dimensions, or explicitly lower-confidence
user points. These provenance types remain separate.

Curved, warped, reflective, perforated, transparent, contradictory, poorly
covered, or disconnected surfaces are rejected. A shelf lip or door track without
a separately verified passage measurement blocks automatic fit authorization.
Hidden corners are permitted only when three accepted planes constrain them and
the inferred result is explicitly approved.

Circle acquisition is explicitly follow-up work; the app does not approximate a
circle with noisy corner detection. Robust circle fitting and overlapping-zone
alignment remain non-live core models.

Physical validation is required on representative LiDAR devices and materials.
Glass, mirrors, thin edges, featureless surfaces, moving obstacles and incomplete
viewpoints must be manually confirmed or rejected; simulator tests cannot validate
their optical behavior.

## Physical-device validation

Use a tape/fixture reference and record signed error, absolute error, repeatability,
rejection rate, and dangerous overestimation separately for every case:

1. Empty rectangular box and empty shelf.
2. Elevated shelf with the floor visible below.
3. Deep shelf with partially hidden rear corners.
4. Shelf with a front lip or track; verify opening is smaller than interior.
5. Shelf containing one box/laptop/cable contaminant.
6. Dark, glossy, wire/perforated, and matte reference materials.
7. Repeat at several phone distances across the configured range.
8. Repeat with several approach and viewing angles.
9. Force tracking limitation and relocalization; no mixed-epoch surface may pass.
10. Save/reload schema-v7 evidence and confirm legacy records remain accuracy-unknown.

Simulator geometry tests are necessary but cannot establish centimetre accuracy.
Configuration thresholds must be tuned only from the recorded device results.
