# LiDAR placement MVP

## What this version proves

The `Place` tab implements one complete operational path:

1. Scan a registered product barcode.
2. Enter package width, height, depth, weight, and pick frequency.
3. Measure the storage space with the staged marker scanner
   (`StorageMarkerScannerView`): select the base surface, place four wall
   boundary markers, review (with bounded right-angle correction), enter the
   usable height, and confirm the previewed volume. See `docs/space-scan.md`
   for the geometry pipeline behind it.
4. Exclude locations that fail dimension, handling-clearance, or weight checks.
5. Rank feasible locations using space efficiency, walking distance, order
   affinity, weight-capacity utilization, demand velocity, and business scale.
6. Select a destination.
7. Scan the product barcode and then the location barcode.
8. Reject either scan when it does not match the recommendation.

The placement engine is pure Swift and does not depend on ARKit, SwiftUI, or
Firebase. Its rules can be tested locally and later executed on a server.

## Important limits

- LiDAR observes visible geometry; it does not reliably measure occluded space.
- A surface scan cannot determine a shelf's rated load.
- AR plane dimensions have measurement noise. The engine currently requires
  2 cm of handling clearance on each dimension.
- The scan identifies a surface, not a permanent warehouse location. Production
  onboarding must bind each measured surface to a printed location barcode.
- Operational shelves are loaded from Firestore (`PlacementRepository.fetchShelves`)
  and persisted transactionally with version checks.
- The score is explainable and deterministic, but its weights have not been
  calibrated against real pick-time or order-history data.

## Data model (as implemented)

Shelf geometry is kept out of product inventory, in its own collections:

- `shelves/{shelfId}` — the operational `ShelfState`: label, barcode, version
  (optimistic concurrency), boundary, coordinate system, compartments,
  obstacles, stored `products` (occupancy), scan quality, and the approved
  `geometry` record; superseded geometries archive to the shelf's
  `geometryVersions` subcollection.
- `spaces/{spaceId}` — approved `ScannedSpaceGeometry` scans
  (`SpaceRepository`, version-checked saves).
- `placements/{placementId}` — a confirmed `ProductPlacementResult`.
- `placementReservations/{shelfId}` — one 120-second reservation per shelf
  while a worker verifies and places.

A future `productRelationships/{pairId}` collection (co-order affinity) is
still unbuilt; affinity is currently a manual score.

## Recommended next build order

Done since this doc was written: transactional shelf/placement persistence,
per-shelf reservations, product package dimensions/weight/stacking metadata in
the product master, and un-placing stored products.

Still open:

1. Printable location labels bound to shelf barcodes.
2. Derive product affinity from order lines rather than manual scores.
3. Store a simple aisle graph and compute actual walking distance.
4. Pilot with one aisle and compare recommended versus actual pick time.
5. Calibrate score weights from pilot data before expanding warehouse-wide.

Do not start with machine learning. A constrained, explainable scoring model is
easier to validate, audit, and improve while the business is still collecting
reliable location and order data.
