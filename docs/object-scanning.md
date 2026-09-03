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

The previous scanner recomputed the dominant centre-depth histogram bin on
every frame, accepted a large screen window and depth band, cropped to a fixed
50 cm world cube, then selected the largest connected component. A table or
nearby object could therefore become the per-frame depth target and later win
the largest-component test. That directly explains jumps from a small object
to the bounds of surrounding geometry.

The replacement pipeline is:

1. Before capture, the user adjusts a screen-space box plus the width, height,
   and depth of a 3D scan volume.
2. The centre marker supplies the target seed. At capture start, its world
   point and a gravity-aligned, camera-oriented volume are locked. A translucent
   green RealityKit box shows the locked volume in the room.
3. Each depth frame samples only inside the screen selection. Only finite
   medium/high-confidence scene-depth samples are converted to world points.
4. The fusion engine independently rejects every point outside the locked
   world volume before voxel insertion. Similar camera depth alone never makes
   a point eligible.
5. ARKit camera poses register samples into world space. Voxels need distinct
   observations from at least three frames.
6. A gravity-aligned height histogram detects the lowest sufficiently supported
   horizontal plane. Its noisy contact band is removed, while the plane height
   remains the lower height boundary.
7. Region growing starts at the stable voxel nearest the locked user seed.
   Disconnected geometry is discarded; the largest cluster is not used.
8. A robust minimum-area horizontal search supplies oriented axes without
   weighting over-scanned faces more heavily. Interpolated 1st/99th percentiles
   produce robust extents, and the support plane supplies the lower height.
9. Three consistent live estimates are required. A dimension increase above
   25% freezes the last stable value and displays the nearby-object warning.
   A changed value is adopted only after three consistent estimates.
10. Finish remains disabled until the world volume is locked, measurement is
    stable, at least 20 frames and 120 segmented voxels are available, and the
    existing confidence threshold passes.

The `ARFrame`, depth map, and confidence map never leave the ARKit callback.
Only copied `[SIMD3<Float>]` world points are passed to the serial fusion queue.

## Central LiDAR configuration

`LiDARFusionConfiguration.smallObject` in
`WarehouseApp/Services/LiDARVoxelFusionEngine.swift` contains:

| Setting | Default | Trade-off |
| --- | ---: | --- |
| Voxel size | 3 mm | Smaller improves detail but raises memory/sample cost |
| Frame observation threshold | 3 | Higher rejects transients but takes longer |
| Minimum fused frames | 20 | More coverage at the cost of capture time |
| Minimum stable voxels | 120 | Rejects sparse scans; thin objects may need more views |
| Crop margin | 3 mm | Covers quantization without admitting broad surroundings |
| Support noise band | 6 mm | Removes table/contact noise while plane height preserves full object height |
| Support-plane bin | 3 mm | Matches voxel resolution |
| Connectivity radius | 2 voxels (6 mm) | Bridges LiDAR holes; larger values risk joining close objects |
| Maximum seed distance | 8 cm | Supports incomplete first views while still binding to the selected target |
| Bound percentiles | 1st / 99th | Rejects edge outliers without arbitrary calibration |
| Stable estimates | 3 | Adds latency but prevents one-frame replacement |
| Jump threshold | 25% | Sensitive enough to catch the reported 6→16 cm failure |
| Estimate consistency | 8% | Accommodates LiDAR noise while rejecting materially different bounds |

The user-facing scan volume defaults to 14×16×14 cm and is adjustable from
8–40 cm wide/deep and 8–50 cm high. It should be tightened around the target.

## Raw dimensions, tolerance, and persistence

The LiDAR configuration affects raw measurement only. Existing warehouse rules
remain separate:

- Internal unit: centimetres
- Per-axis scan tolerance: `max(2 cm, measured dimension × 2%)`
- Per-axis storage clearance: `1 cm`
- Final dimension: raw + scan tolerance + storage clearance

These values remain in `ObjectDimensionPolicy.default`. The confirmed
`objectScan` Firestore map and the 3D review behavior are unchanged.

## Automated validation

`LiDARVoxelFusionEngineTests` deterministically covers:

- A 6×6×8 cm cylinder on a table
- The cylinder plus a nearby 16×12×9 cm object
- One-frame outliers
- A surrounding horizontal table
- A rotated rectangular object
- A sudden 6×6×8 to 16×12×9 jump followed by recovery
- Pre-fusion locked-volume rejection
- Multi-frame consensus

Geometric accuracy is ±6 mm, twice the configured voxel size. Run the complete
suite with:

```sh
xcodebuild -project Warehouse.xcodeproj -scheme WarehouseApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4' test
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
11. Briefly move the nearby object into view during another scan. Confirm the
    last stable dimensions freeze and the nearby-object warning appears rather
    than accepting a jump.
12. Use **Reset Selection** if the green box was locked incorrectly and
    **Restart Scan** if tracking or coverage degrades.

## Physical-device limitations

- The simulator validates deterministic geometry but supplies no real LiDAR
  depth. Accuracy, coverage, UI legibility, thermal load, and pose drift still
  require the device procedure above.
- ARKit scene depth is noisy on reflective, transparent, absorptive, very thin,
  or low-return surfaces. No calibration constant is used to hide that.
- If two objects physically touch or their noisy surfaces bridge the configured
  6 mm connectivity distance inside the locked volume, connected-component
  segmentation can treat them as one object. Tighten the volume and separate
  them physically.
- Horizontal PCA gives a robust oriented footprint, but near-circular objects
  have no unique yaw; their equal diameter axes remain valid.
- Confidence is an application quality heuristic, not an Apple-certified
  metrology guarantee. Warehouse safety margins remain separate from raw
  uncertainty.
