# Manual AR Product Measurement

## Architecture

The Add Product form remains the owner of the final product draft. It can now
receive dimensions from three sources:

- Manual Region Product Scan (`ARSCNView`, ARKit depth/raycasts/anchors, voxel
  fusion, and SceneKit rendering)
- Existing automatic LiDAR/Object Capture scanning
- Manual dimension entry

`ManualARSessionView` owns the gravity-aligned AR session, centre raycasts, preview marker,
real-world `ARAnchor`s, and lightweight SceneKit rendering.
`ManualARMeasurementState` owns stages and user actions.
`ManualMeasurementGeometry` owns plane and polygon validation.
`LiDARVoxelFusionEngine` owns the product segmentation and measurement. The
result is converted to the existing `ObjectScanCapture` and
`ProductObjectScan` path so Add Product and Firestore do not need a parallel
persistence workflow.

## Region versus product geometry

Boundary points are fitted to a least-squares plane using the smallest
eigenvector of their covariance matrix. Points are projected into the plane's
local 2D basis before validation and polygon calculations. The polygon plus the
bottom and top markers defines a polygonal-prism region of interest. Those
coordinates only crop incoming AR points; the polygon width, length, and
top-to-bottom distance are never reported as the product dimensions.

ARKit raycast translations are retained in their shared session world space.
Height is the absolute projection of the top-to-bottom world vector onto the
normalised gravity-aligned world-up axis (`abs(dot(top - bottom, up))`), which
is `abs(top.y - bottom.y)` for this session's explicit `.gravity` alignment.
Horizontal marker offset and interface orientation therefore do not add to height.
For the top marker, LiDAR scene depth is sampled at the centre reticle so the
nearest visible product surface wins over the floor behind it. Non-LiDAR devices
use finite/estimated surfaces and never use an infinite plane for the top marker.
If no candidate is above the bottom marker, placement
is disabled rather than reporting the background or floor as product height.

During the product scan, registered scene-depth samples (or lower-density AR
feature points without LiDAR) are filtered to the prism before fusion. Repeated
voxels are retained, the support plane is removed, connected product geometry
is isolated, and a robust oriented bounding box supplies the product length,
width, and height. The UI renders the cyan region separately from the green
detected points and orange calculated product box. A product reaching a side or
top limit is treated as possible clipping and shows a warning. A complete orange
product box can still be finished so the user is not trapped in capture.

Live capture progress reports accumulated in-region voxels on every integrated
frame. Measurement is recalculated every fourth frame, while the most recent
detected points, dimensions, and orange box remain displayed between calculations.
The Finish Product Scan button becomes available as soon as a complete orange
product box has valid dimensions and enough retained points. The user may finish
then or continue scanning for a stable estimate. A box touching the scan-region
boundary remains eligible but displays a warning because it may be clipped.

ARKit coordinates remain in metres. Product records remain in centimetres for
compatibility with the existing model.

Valid region boundaries do not have a warehouse-size minimum or maximum.
Duplicate markers must be at least 1 mm apart. The bottom-to-top region span has
a technical safety range of 1 mm through 25 m. Product size is independent of
that span; a 5 cm-tall product is explicitly covered by fusion tests.

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
3. Mark a region around the base clockwise, close and confirm it, then set
   bottom and top scan limits. Make the cyan prism larger than the product.
4. Start Product Scan and move around the product until the green detected
   points and orange product box stabilise. If overflow is reported, enlarge
   the region rather than accepting a clipped measurement.
5. Compare detected length, width, and height with a tape measure. Record device
   model, LiDAR availability, target distance, lighting, raw error, and adjusted
   result.
6. Save and reopen the product. Confirm final dimensions, raw dimensions,
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
- Scan confidence is an application-level coverage and stability indicator; it
  is not an accuracy guarantee from ARKit.
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
