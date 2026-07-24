# LiDAR placement MVP

## What this version proves

The `Place` tab implements one complete operational path:

1. Scan a registered product barcode.
2. Enter package width, height, depth, weight, and pick frequency.
3. Scan the shelf with LiDAR and tap the intended horizontal surface. A
   translucent cyan rectangle and bright outline show the exact measured
   region while live width and depth measurements remain visible on screen.
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
- The sample locations in `PlacementView` demonstrate ranking only. They are
  not yet loaded from Firestore.
- The score is explainable and deterministic, but its weights have not been
  calibrated against real pick-time or order-history data.

## Production data model

Store these as separate collections so shelf geometry does not get mixed into
product inventory:

### `locations/{locationId}`

- `label`
- `barcode`
- `aisle`, `bay`, `level`
- `widthCM`, `heightCM`, `depthCM`
- `ratedWeightKG`
- `occupiedWeightKG`
- `walkingDistanceM`
- `active`
- `lastMeasuredAt`
- `measurementConfidence`

### `placements/{placementId}`

- `productId`
- `batchId`
- `locationId`
- `quantity`
- `packageDimensions`
- `weightKG`
- `recommendedScore`
- `productScannedAt`
- `locationScannedAt`
- `placedBy`

### `productRelationships/{pairId}`

- `productA`
- `productB`
- `coOrderCount`
- `affinityScore`
- `windowStart`
- `windowEnd`

## Recommended next build order

1. Add warehouse/location onboarding and printable location labels.
2. Persist location capacity and placements transactionally in Firestore.
3. Add product package dimensions, weight, stackability, and allowed
   orientations to the product master.
4. Derive product affinity from order lines rather than manual scores.
5. Store a simple aisle graph and compute actual walking distance.
6. Add reservations so two workers cannot receive the same free slot.
7. Pilot with one aisle and compare recommended versus actual pick time.
8. Calibrate score weights from pilot data before expanding warehouse-wide.

Do not start with machine learning. A constrained, explainable scoring model is
easier to validate, audit, and improve while the business is still collecting
reliable location and order data.
