# Shelf-aware placement

## Existing architecture

- `ScanView` identifies product barcodes and opens detail or registration.
- `AddProductView` owns product creation and reuses manual AR measurement,
  LiDAR fusion, and Object Capture. `ProductRepository` writes product masters.
- `PlacementView` owns the placement flow. The original capacity-ranking API
  remains available for legacy mapped locations.
- `LiDARSurfaceScannerView` uses ARKit scene reconstruction and RealityKit to
  measure and render a shelf boundary and clear height.
- `InventoryStore` listens to Firestore; stock and barcode services already use
  transactions.

## Integrated workflow

1. Scan a product. Saved raw dimensions, uncertainty, weight, retrieval data,
   orientation, and stacking rules populate the workflow.
2. Scan the shelf boundary and clear height.
3. Stand at the opening, aim toward the back, and tap **Set as Shelf Front**.
   Inspect the arrow, reverse or redefine it, then confirm it.
4. The scanner projects the boundary onto the chosen width/depth basis. Depth
   zero is the opening, positive depth is back, and +Y is up.
5. Off the main thread, the engine validates scan/occupancy, expands dimensions
   by uncertainty and clearance once, creates geometry-derived candidates, and
   filters hard constraints.
6. Valid candidates compare lexicographically: critical blocking, priority
   cost, required moves, accessibility, safe height, front proximity,
   stability, then space efficiency. Candidate IDs make ties deterministic.
7. RealityKit displays a translucent target box and insertion line in the live
   session. A shelf-local diagram and natural-language guidance remain after it
   closes.
8. Product and location barcodes remain the final operational check.
   `ARPlacementVerifier` can also assess observed position/yaw and return a
   concrete correction.

## Geometry and constraints

The engine starts with a tolerance-adjusted oriented box. Each permitted box
orientation becomes axis-aligned in shelf-local coordinates. Candidate origins
come from compartment corners, boundaries, obstacle/product faces, and valid
supporter tops.

Hard filters cover containment, occupied/obstacle collision, load ratings,
support ratio, centre-of-mass projection, both products' stacking rules,
heavy-item reach policy, swept straight insertion, scan/state consistency, and
critical-product obstruction. Accepted results record removal paths and blockers.

## Persistence and concurrency

`PlacementRepository` stores shelves, placements, and expiring reservations.
Reservation and confirmation re-read `ShelfState.version` in Firestore
transactions. Confirmation atomically adds occupancy/support/obstruction data,
increments the version, writes the result, and deletes the reservation.

## Conservative assumptions

- Internal units are centimetres and kilograms.
- Missing weight, fragility, stacking, or capacity never grants permission.
- Unknown geometry remains a rectangular box; irregular meshes are not treated
  as freely rotatable boxes.
- The current scan produces one compartment. Multiple compartments and obstacle
  models are supported by the engine and persistence layer.
- Reach is configurable and shelf-relative when user height is unavailable.

## Known limitations

- The LiDAR UI captures the boundary and clear height but does not yet extract
  divider/door/support volumes automatically. They can be loaded through
  `ShelfState.obstacles`; do not enable precision for unreconciled shelves.
- The model supports secondary access directions; the UI configures one primary
  front.
- Motion checking validates straight insertion at the final orientation. It
  does not search a six-degree-of-freedom insert-then-rotate path.
- Rectangular overlap approximates combined support area.
- Live AR final-position detection is not automated; the verifier is ready for
  supplied position/yaw, while the UI still requires barcode confirmation.
- Reorganization and temporary holding-area sequencing are not implemented.
- Reservation transactions exist at the service layer but are not invoked for
  the current unsaved, in-session shelf until shelf onboarding is connected.

## Manual test

1. On a LiDAR iPhone, create a product with dimensions and handling rules.
2. Open **Place**, scan it, and verify saved values populate.
3. Scan a shelf: mark the boundary, finish it, then set bottom and top.
4. Aim through the opening, set the shelf front, test reverse/redefine, confirm.
5. Verify the green target and yellow insertion line, then close the scanner and
   compare the diagram, distances, rotation, warnings, and instructions.
6. Request an alternative and verify deterministic behavior.
7. Select a result, scan product then shelf barcodes. Wrong scans must fail.
8. Repeat for exact fit, low confidence, front obstacle, full floor with valid
   support, non-stackable support, overweight item, and critical rear item.
