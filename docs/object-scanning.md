# Object scanning in Add Product

## Available scan methods

The Add Product workflow keeps both native options:

- **LiDAR Fusion** uses public ARKit scene-depth, camera transforms, and
  RealityKit visualization for measurement.
- **Apple Object Capture** remains available as the guided photographic
  reconstruction option.

Neither implementation attempts to reproduce Polycam or any other proprietary
pipeline.

## LiDAR isolation pipeline

LiDAR Fusion and the manual region scan share one measurement pipeline,
`LiDARMeasurementSession`. Its stages, thresholds, evidence record and
failure states are documented in
[manual-ar-measurement.md](manual-ar-measurement.md).

What is specific to LiDAR Fusion:

1. Before capture, the user adjusts a screen-space box plus the width, height,
   and depth of a 3D scan volume.
2. The centre marker supplies the target seed. At capture start, its world
   point and a gravity-aligned, camera-oriented volume are locked. A translucent
   RealityKit box shows the locked volume in the room.
3. Each depth frame samples only inside the screen selection. Only finite
   medium/high-confidence scene-depth samples are converted to world points.
4. Once the volume is locked, each processed frame (frames are throttled to
   the pipeline's frame interval), including frames with degraded tracking
   or no depth in the box, is handed to the pipeline so it can judge whether
   its evidence is still current.
5. Finish is enabled only when the pipeline's acceptance stage does not
   refuse and the coverage score passes the existing threshold.
6. If tracking is interrupted or the pipeline discards its evidence, the scan
   restarts and the volume is locked again.

The `ARFrame`, depth map, and confidence map never leave the ARKit callback.
Only copied `[SIMD3<Float>]` world points are passed to the serial fusion queue.

## Central LiDAR configuration

Every threshold of the measurement pipeline is a named, documented property
of `LiDARFusionConfiguration` in
`WarehouseApp/Services/LiDARMeasurementConfiguration.swift`. LiDAR Fusion
narrows the depth range to 0.15–1.20 m. Its screen selection, scan-volume
defaults and the 7 × 7 pixel seed window are capture settings and live in
`ARObjectScannerView` (`ObjectScanSelectionSettings`, `extractSeed`).

The user-facing scan volume defaults to 14×16×14 cm and is adjustable from
8–40 cm wide/deep and 8–50 cm high. It should be tightened around the target.

## Raw dimensions, tolerance, and persistence

The LiDAR configuration affects raw measurement only. Existing warehouse rules
remain separate:

- Internal unit: centimetres
- Per-axis scan tolerance: `measured dimension × 2% + 0.5 cm`
- Per-axis storage clearance: `0 cm`
- Final dimension: raw + scan tolerance + storage clearance

These values remain in `ObjectDimensionPolicy.default`. The confirmed
`objectScan` Firestore map and the 3D review behavior are unchanged.

## Automated validation

Synthetic tests are listed, with the mechanism each one covers, in
[manual-ar-measurement.md](manual-ar-measurement.md). They check logic on
generated scans and are not evidence of accuracy on a device. Run the suite
with:

```sh
xcodebuild -project Warehouse.xcodeproj -scheme WarehouseApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

## Precise physical test for the 6×6×8 cm cylinder

1. Use a LiDAR-equipped iPhone Pro or iPad Pro on iOS 17 or later. Confirm the
   cylinder independently with calipers at several points.
2. Put it upright on a matte, level, textured table. Use diffuse room light;
   avoid glass, mirrors, glossy black surfaces, and direct sunlight.
3. Open Add Product → Start Object Scan → Experimental LiDAR Fusion.
4. Hold the device 25–45 cm away. Put the centre marker on the cylinder body.
5. Tighten the screen box so it contains the cylinder with little background.
   Set the 3D volume to about 10×12×10 cm for this target.
6. Tap **Lock Selection & Start**. Verify the green volume remains fixed in
   world space as the phone moves.
7. Move slowly through a near-complete orbit, including modest high angles for
   the top. Keep the cylinder in the screen box and table tracking features in
   view. Do not move the cylinder or table.
8. Continue until dimensions, fused-frame count, stable-voxel count, and
   confidence appear and **Finish Scan** becomes enabled.
9. Record the raw dimensions, finish, and review. Repeat three times without
   nearby clutter; compare each axis with the caliper dimensions.
10. Place a 16×12×9 cm object 4–8 cm beside the cylinder, outside the tight
    green volume, and repeat. It may appear in the camera view but must not
    materially change the raw cylinder result.
11. Briefly move the nearby object into view during another scan. Confirm
    Finish is disabled while the dimensions disagree and that a caution or
    refusal names the nearby object rather than accepting a jump.
12. Use **Reset Selection** if the green box was locked incorrectly and
    **Restart Scan** if tracking or coverage degrades.

## Physical-device limitations

- The simulator validates deterministic geometry but supplies no real LiDAR
  depth. Accuracy, coverage, UI legibility, thermal load, and pose drift still
  require the device procedure above.
- ARKit scene depth is noisy on reflective, transparent, absorptive, very thin,
  or low-return surfaces. No calibration constant is used to hide that.
- If two objects physically touch, or their noisy surfaces come within a
  voxel of each other inside the locked volume, connected-component
  segmentation can treat them as one object. Tighten the volume and separate
  them physically.
- A minimum-area yaw search gives the oriented footprint. Near-circular
  objects have no unique yaw; their equal diameter axes remain valid.
- Confidence is an application quality heuristic, not an Apple-certified
  metrology guarantee. Warehouse safety margins remain separate from raw
  uncertainty.
