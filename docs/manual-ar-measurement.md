# Manual AR Product Measurement

## Architecture

The Add Product form remains the owner of the final product draft. It can now
receive dimensions from three sources:

- Manual AR Boundary (`ARSCNView`, ARKit raycasts/anchors, and SceneKit rendering)
- Existing automatic LiDAR/Object Capture scanning
- Manual dimension entry

`ManualARSessionView` owns the AR session, centre raycasts, preview marker,
real-world `ARAnchor`s, and lightweight SceneKit rendering.
`ManualARMeasurementState` owns stages and user actions.
`ManualMeasurementGeometry` owns plane, polygon, oriented-rectangle, and height
math. The result is converted to the existing `ObjectScanCapture` and
`ProductObjectScan` path so Add Product and Firestore do not need a parallel
persistence workflow.

## Geometry

Boundary points are fitted to a least-squares plane using the smallest
eigenvector of their covariance matrix. Points are projected into the plane's
local 2D basis before validation and polygon calculations. The footprint
rectangle is found by evaluating the convex hull at every hull-edge angle and
keeping the minimum-area result. Height is the signed perpendicular distance
from the top marker to the fitted base plane; the bottom marker is used for
plane and footprint validation.

ARKit coordinates remain in metres. Product records remain in centimetres for
compatibility with the existing model.

Valid manual boundaries do not have a warehouse-size minimum or maximum.
Duplicate markers must be at least 1 mm apart. Height has a separate technical
safety range of 1 mm through 25 m; a 5 cm height is explicitly supported.

## Tolerance

The configurable adjustment is applied independently to each dimension:

`adjusted = measured × (1 + percentage) + fixed centimetres`

Defaults are 2% and 0.5 cm. Raw dimensions, tolerance components, and final
dimensions are stored separately. Users can choose to save raw dimensions as
the final warehouse dimensions without losing the configured tolerance.

## Permissions and requirements

- Minimum deployment target: iOS 17.0.
- Camera permission is required. `NSCameraUsageDescription` is already generated
  from `project.yml` and explains barcode, photo, and measurement camera use.
- AR world tracking is required.
- LiDAR is optional. A non-LiDAR device uses standard ARKit estimated/existing
  plane raycasts and displays a reduced-accuracy warning.
- No additional permission is required for LiDAR or ARKit.

## Physical iPhone test procedure

Use a LiDAR-equipped iPhone Pro first, then repeat the core cases on a supported
non-LiDAR iPhone.

1. Build and run on the phone, open Inventory > Add Product > Measure with AR,
   and grant camera access.
2. Scan slowly until tracking reports ready and the centre target turns green.
3. Mark the base clockwise, close it, confirm the base, then place bottom and
   top points. Move around after every placement and verify markers remain
   attached to their physical points.
4. Compare raw length, width, and height with a tape measure. Record device
   model, LiDAR availability, target distance, lighting, raw error, and adjusted
   result.
5. Save and reopen the product. Confirm final dimensions, raw dimensions,
   tolerance, method, quality, rotation permission, and manual boundary metadata.

Test these shapes:

- Rectangular and square boxes
- Triangular and irregular footprints
- Tall narrow and very flat objects

Test these environments:

- Beside another product, on a shelf, on a table, and close to a wall
- Reflective or dark surfaces
- Low light and cluttered backgrounds
- A product whose bottom edge is partially hidden

Test these actions and recovery paths:

- Three points and four or more points
- Undo, reset, replace every marker type, and invalid/self-crossing boundaries
- Move after placement; interrupt/resume the AR session; background/foreground
- Camera denial, no detected surface, limited tracking, and non-LiDAR warning
- Manual entry, tolerance editing, raw-versus-adjusted selection, save, and cancel

## Known limitations

- AR measurements are estimates and cannot claim tape-measure accuracy.
- Reflective, transparent, featureless, dark, distant, or occluded edges can
  produce weak raycasts even on LiDAR devices.
- Tracking confidence is an application-level quality indicator based on
  tracking, raycast type/distance, LiDAR availability, and plane consistency;
  it is not an accuracy guarantee from ARKit.
- The translucent polygon uses the user's boundary order and ear-clipping
  triangulation. Highly intricate outlines should still be checked visually.
- Simulator tests cover geometry and app integration only. Camera tracking,
  anchors, haptics, interruption recovery, and accuracy require a physical phone.

## Recommended follow-ups

- Add repeated raycast sampling and variance scoring at each placement.
- Add tap-to-select marker replacement directly in the AR scene.
- Store calibration results per device model and environment.
- Add optional RoomPlan/shelf context without using it to choose product edges.
- Feed rotation permission and adjusted dimensions into future 3D bin-packing.
