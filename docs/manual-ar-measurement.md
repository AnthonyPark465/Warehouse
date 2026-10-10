# Object measurement from multi-frame depth

Engineering design for the app's central feature: measuring a physical product
from several registered iPhone LiDAR/depth frames, and declining to report a
measurement the evidence does not support.

Status: the pipeline is implemented and covered by synthetic tests. **It has
not been validated against physical ground truth.** Nothing here is an
accuracy claim. See [Limitations](#limitations) and
[Physical validation](#physical-iphone-validation-procedure).

## 1. The sensor problem

An iPhone depth frame is a low-resolution, noisy range image from one
viewpoint. Turning a handful of them into three product dimensions runs into
five specific problems:

1. **One view is not a box.** A single frame sees at most three faces. The
   unseen faces contribute nothing, so a dimension can be defined by one edge.
2. **The product sits on something.** The table is in every frame and is
   usually the largest surface. It has to be removed, but removing it also
   removes the product's base, which shortens the height.
3. **Depth has holes and fliers.** Dark, glossy or grazing surfaces return
   nothing; edges return spurious points. Holes fragment a surface, fliers
   extend it.
4. **Products have neighbours.** A second product a few millimetres away, or
   a wall behind, is geometrically continuous with the target at sensor
   resolution.
5. **The coordinate system is not permanent.** After an interruption or
   relocalization, ARKit's world origin may move. Points fused before and
   after are then in different frames.

A pipeline that always answers will answer wrongly in each of these cases.
The design goal is therefore two-fold: measure well when the evidence is
good, and say precisely what is missing when it is not.

## 2. Inputs

| Input | Source | Type |
|---|---|---|
| Region | User-marked polygon plus bottom/top limits, or a locked box | `LiDARSpatialRegion` |
| Seed | An interior point of the region, 2 cm above its lower limit | `ManualARMeasurementState.productSeed` |
| Frames | World-space depth points, timestamp, tracking state, coordinate epoch, camera position, per-sample confidence counts | `LiDARDepthFrame` |
| Configuration | Every threshold, named and documented | `LiDARFusionConfiguration` |

The region is a crop only. Its size is never reported as a product dimension.
The user selects the object by drawing the region around it; the region's
interior point stands in for an aim point.

## 3. Processing stages

The stages are explicit, and each produces values that can be inspected and
tested. Support-plane estimation, component selection, bounds estimation,
stability analysis and acceptance are separate functions with their own
result types. Frame validation and voxel fusion share
`integrate(frame:)`. The support, boundary and coverage checks are applied in
`analyze()`, which records each outcome in `LiDARGeometryAnalysis`.

```
LiDARDepthFrame
   │
   ▼ 1 frame validation      LiDARVoxelFusionEngine.integrate(frame:)
   ▼ 2 voxel fusion          LiDARVoxelFusionEngine.integrate(frame:), expireWeakVoxels
   ▼ 3 support-plane         LiDARSupportPlaneEstimator.estimate
   ▼ 4 component selection   LiDARComponentSelector.select
   ▼ 5 bounds estimation     LiDARBoundsEstimator.estimate
   ▼   coverage analysis     LiDARCoverageAnalyzer
   ▼ 6 stability analysis    LiDARStabilityAnalyzer.consider
   ▼ 7 final acceptance      LiDARMeasurementAcceptance.decide
   │
   ▼
LiDARMeasurementReport { measurement, decision, evidence, guidance }
```

`LiDARVoxelFusionEngine.analyze()` runs stages 3–5 and coverage.
`LiDARMeasurementSession.process(_:)` runs the whole chain per frame. Neither
contains ARKit types, so the same code runs on device, in tests, and in the
evaluation tool.

### 3.1 Frame validation

A frame contributes only if all of the following hold, checked in this order:

- **Coordinate epoch unchanged.** The capture layer increments the epoch when
  the session is interrupted or re-run. A change discards all fused evidence
  before anything else can reject the frame.
- **Timestamp finite, later than the last, and at least one frame interval
  after it.** Near-duplicate frames would count one view many times.
- **Tracking normal.** A relocalizing or unavailable frame discards all
  evidence. Limited tracking rejects the frame, and discards all evidence
  once it has lasted longer than `maximumLimitedTrackingSeconds`.
- **Camera motion plausible.** A displacement faster than
  `maximumCameraSpeedMetresPerSecond` is treated as a coordinate
  discontinuity.
- **At least one point inside the region.**

Per-sample filtering (depth range, confidence level) happens while reading
the depth map, through `LiDARDepthSampleFilter.classify`, in both capture
views. Counts of rejected samples travel with the frame into the evidence
record. The capture views themselves need a device and have no unit tests.

### 3.2 Voxel fusion

Accepted points are cropped to the region and binned into 3 mm voxels. Within
one frame, all points in a voxel are averaged into a single observation
(spatial de-duplication). Across frames, a voxel accumulates one observation
per frame.

- **Transient rejection:** a voxel needs `minimumFrameObservations` (3)
  distinct frames.
- **Stale rejection:** a voxel seen fewer than `persistentObservationCount`
  (6) times and unseen for more than `weakVoxelExpiryFrames` (60) accepted
  frames expires. Established voxels expire after
  `persistentVoxelExpiryFrames` (600). Expiry is checked every quarter of
  `weakVoxelExpiryFrames`, so removal can lag the limit by up to 15 frames.
  When expired
  geometry had already passed the three-frame filter and is significant
  relative to the product, `weakGeometryExpired` is reported.

### 3.3 Support-plane estimation

Heights of stable voxels are histogrammed along the region's vertical axis.

1. Take the **lowest** bin that holds enough voxels to be a surface.
2. **Climb** up to two bins toward a more populated neighbour. The lowest
   populated bin is the noise tail of the plane, not its centre.
3. Take the **median** of heights within 1.5 bins of that peak, twice.
4. Estimate plane noise from heights **below** the plane only. Product points
   stand on the plane and would inflate a two-sided estimate.
5. Set the removal band to `max(supportPlaneNoiseBand, 3 × noise)`, capped at
   `maximumSupportPlaneNoiseBand`.

The result carries the plane coordinate, the band, the residual, and the
method used.

#### Why removing the support shortens an object, and how this is avoided

The support and the product meet. Depth noise smears both into a band a few
millimetres thick, so any rule that removes "the table" also removes the
lowest slice of the product. If height is then measured over the remaining
points, it is short by the band thickness (6 mm by default, more for a noisy
surface), and the error grows with exactly the noise the band exists to
absorb.

This pipeline separates the two roles the support plays:

- For **segmentation**, the plane and its band are removed
  (`aboveSupport`, `LiDARVoxelFusionEngine.analyze`).
- For **height**, the plane's coordinate is kept as the lower boundary
  (`LiDARBoundsEstimate.supportCoordinate`, `height = top − supportCoordinate`).

The band can therefore be as wide as the noise requires without costing
height. `testRetainedSupportCoordinateAvoidsTheHeightLossOfFloorRemoval` shows
both behaviours on identical synthetic frames.

A wrong plane is worse than a missing one, so four checks guard it:

| Check | Reason code |
|---|---|
| No bin qualifies as a surface | `supportPlaneNotFound` |
| Geometry lies below the plane | `geometryBelowSupport` |
| The plane does not extend past the product footprint | `supportNotBeyondFootprint` |
| The product floats well above the plane | `objectNotOnSupport` |

Each of these refuses the measurement.

### 3.4 Component selection

1. **Strict pass.** 26-neighbour connected components over voxels above the
   support. Each is a *unit*.
2. Units with at least `minimumStableVoxelCount` voxels are **object-sized**
   and are never merged with anything.
3. Smaller units (*fragments*) are grouped with each other at the expanded
   reach (two voxels, Euclidean). Each group records which object-sized units
   it touches.
4. Candidates are object-sized units and fragment groups that reach object
   size together. The candidate **nearest the seed** wins, within
   `maximumSeedDistance`.
5. If the winner is an object-sized unit, the result is **strict**. Nothing
   is bridged onto it. Loose fragments beside it are reported
   (`fragmentsExcluded`), not absorbed.
6. If the winner exists only as bridged fragments, the result is
   **expanded**, and `expandedConnectivityUsed` is recorded with the reason.
7. An expanded result is refused with `possiblePartialObject` when rejected
   fragments (below object size, at least
   `minimumReportedComponentVoxelCount` voxels) within
   `neighbourProximityWarningDistance` of the selection hold at least
   `partialSelectionFragmentFraction` (0.2) of the voxels of both together.

#### Why conditional connectivity helps without always merging neighbours

Holes and neighbours look alike locally: both are a missing voxel between two
occupied ones. A single connectivity radius has to choose. A tight radius
fragments a sparsely scanned product; a wide one bridges to the box next to
it.

Making the wide radius conditional breaks the tie using information the
local test lacks:

- A well-scanned product forms an object-sized strict component. It needs no
  bridging, so it gets none, and a neighbour one missing voxel away cannot
  join it.
- A product that only exists as fragments is the case bridging is for. It is
  bridged, and the record says so.
- Anything object-sized on its own is, by construction, a separate object. It
  is excluded from bridging in both directions.

The fallback is therefore used only when strict segmentation cannot recover
an object, and its use is always visible in the evidence.

Two further guards cover what connectivity cannot see:

- **Proximity.** A rejected component within
  `neighbourProximityWarningDistance` of the selection yields
  `nearbyObjectClose`.
- **Partial selection.** On a surface that returns depth only in patches,
  the reach can join a few patches near the seed into an object-sized group
  and leave the rest out. Such a sliver stands on the support, is stable,
  and is evenly covered within its own small bounds, so the support,
  coverage, stability and uncertainty checks all pass it. What gives it away
  is outside it: comparably many unbridged fragments right beside it. Step 7
  refuses on that. The 0.2 share was chosen on synthetic fixtures only: in
  the synthetic evaluation and ablation, correct expanded results had a
  share of at most 0.03 and slivers at least 0.39. It has not been checked
  on device scans.
- **Interior partition.** Two objects closer than the voxel grid can resolve
  join even at strict connectivity. A single scanned object is a shell, so
  slices through its interior are thin outlines. Facing sides of two merged
  objects appear as one slice many times denser than its neighbours.
  `LiDARCoverageAnalyzer.hasInteriorPartition` detects that and refuses with
  `possibleMergedObjects`.

#### Free-space evidence (experimental, off by default)

A depth return says where a surface is. It also says the space between the
camera and that surface is empty. `LiDARFreeSpaceGrid` keeps that second
fact: for each voxel of the region's bounding box, the number of distinct
frames in which a ray passed through it on the way to a farther return. Rays
stop counting `freeSpaceCarveMarginInVoxels` (2) before their hit, so depth
noise on a surface is not read as space behind it.

A voxel is **observed empty** when at least
`freeSpaceMinimumFrameObservations` (3) frames saw through it and more frames
saw through it than saw a surface in it. With
`freeSpaceGatingEnabled`, step 3 above does not bridge two voxels if any voxel
on the straight line between them is observed empty. A hole in a scanned
surface has no ray through it; a gap between two objects that the sensor
could see into does.

At the default two-voxel reach this changes little: a 3–6 mm gap is below
what a phone's depth map resolves. Its purpose is to make a **longer** reach
safe, so a surface that returns depth only in patches can be joined up
without also joining a second such object beside it. The synthetic ablation
shows that behaviour on constructed cases
([`measurement-ablation-synthetic.md`](measurement-ablation-synthetic.md)).

It is off by default because none of this has been checked on a device.
Known risks: rays grazing a surface at its silhouette pass through
partly-empty voxels and can block a bridge that should be made (a safe
failure: the scan is refused, not mis-measured); mixed pixels at depth edges
may fabricate or hide free space; a gap seen through in one place does not
stop a chain of bridges round it elsewhere.

The evidence record gains `freeSpace` (rays, voxels seen through, whether
the grid was available) and `components.freeSpaceBlockedBridgeCount`.

### 3.5 Bounds estimation

Selected voxels are sorted by voxel key, then:

- **Orientation.** The yaw whose percentile bounds have the smallest area,
  searched at 3° then 0.25°. A later candidate must beat the best by
  `orientationTieTolerance`, so square and round footprints resolve to the
  same angle every run.
- **Extents.** 1st–99th percentile along each footprint axis, and the 99th
  percentile of height.
- **Compensation.** One voxel is added to each horizontal extent and half a
  voxel to the top (`extentQuantizationCompensation`).

Three sets of dimensions are kept: trimmed, untrimmed, and compensated. The
compensated set is the raw measurement.

### 3.6 Coverage, stability and uncertainty

- **Viewpoints.** Camera azimuths around the seed are binned; the arc that
  contains them must reach `minimumViewpointSpanDegrees`.
- **Sides.** For each of the four footprint sides, the fraction of its length
  with voxels near the edge. A side below `minimumSideSupportFraction` is
  sparse.
- **Top.** The fraction of the footprint with voxels near the top height.
- **Boundary contact.** Voxels near each region face are counted per face;
  `boundaryContactMinimumVoxels` near one face is contact.
- **Stability.** The newest estimate is stable when
  `stableEstimateCount` of the last `stabilityWindow` estimates agree with
  it. The newest estimate is always the one reported, so the stored
  dimensions and the displayed box describe the same evidence. A stable
  value replaced by a much larger one is flagged while that change is recent.
  An analysis that yields no estimate clears the window, so agreement has to
  be earned again from fresh estimates.
- **Uncertainty.** Per axis: one voxel, plus half the trimmed tail, plus half
  the spread of agreeing estimates, plus a penalty per sparse bounding side,
  plus (height only) the support noise. This is a heuristic that ranks scans
  by how well evidenced they are. It is not a calibrated error bound.

### 3.7 Final acceptance

The geometric stages run every `measurementIntervalFrames` accepted frames.
Once a result can be finished they run on every accepted frame, so the offer
to finish never rests on geometry older than the fused evidence.

`LiDARMeasurementAcceptance.decide` returns one of three statuses.

| Status | Meaning | Finish |
|---|---|---|
| `accepted` | No failure, warning or fallback | Allowed |
| `qualified` | Usable; warnings and fallbacks are shown and stored | Allowed |
| `refused` | The evidence does not support a measurement | Blocked |

## 4. Outputs

- **Dimensions** (cm): the latest estimate that completed every stage.
- **Decision** with reason codes.
- **Guidance**: one sentence per reason code saying what to do.
- **Evidence record** (`LiDARMeasurementEvidence`), stored on the product as
  `objectScan.measurementEvidence`:

| Evidence | Field |
|---|---|
| Captured and accepted frames; rejections by reason | `frames` |
| Tracking and depth-confidence statistics | `frames.trackingNormalFrameCount`, `lowConfidenceSampleCount`, `highConfidenceSampleCount`, `outOfRangeSampleCount` |
| Stable, transient and expired voxel counts | `voxels` |
| Support coordinate, method, residual, band, checks | `supportPlane` |
| Strict or expanded connectivity, and why | `components.connectivityMode`, `fallbackReason` |
| Selected and rejected component statistics | `components.selected`, `components.rejected` |
| Trimmed, untrimmed and compensated dimensions | `bounds` |
| Per-axis uncertainty | `uncertaintyCM` |
| Boundary contact per face | `boundaryContacts` |
| Coverage: viewing arc, side support, top, partition | `coverage` |
| Stability across recent estimates | `stability` |
| Failure, warning and fallback codes | `failureCodes`, `warningCodes`, `fallbackCodes` |

Storage-adjusted dimensions (tolerance applied) are stored beside the raw
ones in the same `objectScan` map (`raw*`, `scanTolerance*`, `final*`).

## 5. Failure states

Failures refuse the measurement. Warnings and fallbacks qualify it.

| Code | Category | Guidance shown |
|---|---|---|
| `noSelectionLocked` | failure | Set the scan region before scanning |
| `insufficientAcceptedFrames` | failure | Keep scanning |
| `trackingNotNormal` | failure | Hold steady, move more slowly |
| `productNotInView` | failure | Aim at the product inside the region |
| `insufficientStableGeometry` | failure | Move closer, scan slowly |
| `insufficientGeometryAboveSupport` | failure | Aim at the product; very flat products must be entered manually |
| `supportPlaneNotFound` | failure | Include some of the table or floor in the region |
| `supportNotBeyondFootprint` | failure | Include the surface around the product |
| `geometryBelowSupport` | failure | Set the bottom limit at the supporting surface |
| `objectNotOnSupport` | failure | Set the bottom limit at the surface the product stands on |
| `noObjectNearSeed` | failure | Re-mark the region so the product is at its centre |
| `insufficientConnectedGeometry` | failure | Scan each side more slowly |
| `degenerateBounds` | failure | Scan the sides and the top |
| `regionBoundaryContact` | failure | The product touches the selected scan boundary; enlarge the region |
| `possibleMergedObjects` | failure | Two objects appear to be touching; separate them |
| `possiblePartialObject` | failure | Only a piece of a patchy surface was joined up; scan the sparse areas slowly or enter the dimensions manually |
| `insufficientViewpoints` | failure | Scan another side |
| `dimensionsUnstable` | failure | Keep scanning slowly |
| `excessiveUncertainty` | failure | Scan another side and the top |
| `nearbyObjectClose` | warning | Move farther from the nearby or background object |
| `fragmentsExcluded` | warning | Scan the sparse area slowly |
| `supportPlaneNoisy` | warning | Height is less certain |
| `sparseSideCoverage` | warning | Scan another side |
| `topSurfaceSparse` | warning | Scan the top from above |
| `viewpointCoverageUnknown` | warning | Coverage could not be checked |
| `weakGeometryExpired` | warning | Rescan any side passed quickly |
| `sustainedDimensionJump` | warning | Check nothing else joined the box |
| `evidenceInvalidatedByTrackingReset` | warning | Check the region still surrounds the product |
| `expandedConnectivityUsed` | fallback | Gaps were bridged; scan sparse areas to confirm |

When the coordinate system changes mid-scan, the app goes further than the
pipeline: `ManualARMeasurementState.handleTrackingReset` stops the scan and
asks the user to check the marked region, because the region was placed in
the old coordinates too.

## 6. Measurable technical effects

Each effect below is a property that can be measured. The synthetic figures
are in [`measurement-evaluation-synthetic.md`](measurement-evaluation-synthetic.md).
Physical figures do not exist yet.

| Effect | How it is measured |
|---|---|
| Height is not reduced by support removal | Signed height error, pipeline vs. a pipeline that measures the remaining points |
| A neighbour or background object does not enlarge the result | Share of crowded scenes where an offered dimension exceeds the truth by a margin |
| Sparse surfaces are still measured, and marked | Share of sparse scenes answered; share marked `expandedConnectivityUsed` |
| Clipped products are not reported as complete | Share of clipped scenes refused |
| Under-evidenced scans are refused | Refusal rate on deliberately deficient scans, and on good ones |
| Identical input gives identical output | Exact equality of reports across runs and dictionary states |
| Evidence from a discarded coordinate system does not reach the result | Dimensions after a simulated origin shift |

## 7. Mechanism → code → test

| Mechanism | Source | Tests |
|---|---|---|
| Per-sample depth and confidence filter | `LiDARDepthSampleFilter.classify` | `testDepthSampleFilterRejectsLowConfidenceAndOutOfRangeSamples` |
| Frame validation: epoch, timestamp, spacing, tracking, camera jump | `LiDARVoxelFusionEngine.integrate(frame:)`, `invalidateEvidence` | `testCoordinateEpochChangeDiscardsEarlierEvidence`, `testCoordinateResetIsHonouredEvenWhenItsFrameHasAStaleTimestamp`, `testOutOfOrderFrameIsRejectedAsStale`, `testNonFiniteTimestampsAreRejectedWithoutPoisoningTheSession`, `testFramesArrivingFasterThanTheFrameIntervalAreNotCounted`, `testRelocalizingFrameInvalidatesEvidence`, `testBriefLimitedTrackingKeepsEvidenceButBlocksAcceptance`, `testProlongedLimitedTrackingInvalidatesEvidence`, `testImplausibleCameraJumpIsTreatedAsACoordinateDiscontinuity` |
| Region crop before fusion | `LiDARSpatialRegion.contains`, `integrate(frame:)` | `testLockedVolumeRejectsPointsBeforeFusion`, `testPolygonalRegionRejectsOutsidePointsBeforeFusion`, `testNothingIsFusedOrMeasuredBeforeASelectionIsLocked` |
| Spatial de-duplication per frame | `integrate(frame:)` (`frameBins`) | `testFrameStatisticsRecordDuplicatesOutsidePointsAndConfidence` |
| Transient rejection | `analyze()` (observation filter) | `testTransientSingleFrameOutliersAreRejected`, `testRequiresMultiFrameConsensus` |
| Stale rejection | `expireWeakVoxels` | `testWeaklyObservedVoxelsExpireWhilePersistentOnesRemain`, `testEstablishedVoxelsStillExpireAfterTheLongTimeout`, `testBrieflySeenGeometryThatExpiresIsReported` |
| Support plane from the peak, one-sided noise, capped band, fallback | `LiDARSupportPlaneEstimator.estimate` | `testSupportEstimateUsesThePlanePeakNotItsLowerNoiseTail`, `testVeryNoisySupportCapsTheRemovalBandAndIsReported`, `testHeightsWithNoSurfaceFallBackAndAreReportedAsNoSupport` |
| Support removed for segmentation, kept for height | `analyze()` (`aboveSupport`), `LiDARBoundsEstimate.height` | `testSupportPlaneNoiseDoesNotReduceObjectHeight`, `testHorizontalTableIsRemovedButRemainsLowerHeightBoundary`, `testRetainedSupportCoordinateAvoidsTheHeightLossOfFloorRemoval` |
| Support validity checks | `analyze()` | `testRegionWhoseBottomLimitCutsTheProductReportsMissingSupport`, `testLowerShelfIsNotAcceptedAsTheProductsSupport`, `testProductLedgeIsNotAcceptedAsTheSupport`, `testThinlyScannedBaseBelowAShoulderIsNotIgnored` |
| Strict selection nearest the seed | `LiDARComponentSelector.select` | `testNeighbourSeparatedBySmallGapIsExcludedAndReported`, `testBackgroundObjectBehindTheProductIsExcluded`, `testObjectFarFromTheSeedIsRefusedRatherThanMeasured`, `testSmallObjectInsideMuchLargerRegionIsMeasuredNotTheRegion` |
| Conditional expanded connectivity, recorded | `LiDARComponentSelector.select` | `testSparseSurfaceUsesExpandedConnectivityAndRecordsTheFallback` |
| Expanded connectivity does not merge other objects | `LiDARComponentSelector.select` | `testExpandedConnectivityStillRejectsAnUnrelatedObjectWithinBridgingReach`, `testExpandedConnectivityDoesNotBridgeToASparseObjectBeyondItsReach`, `testExpandedConnectivityDoesNotBridgeADiagonalTwoVoxelStep`, `testObjectSizedStrictComponentNeverAbsorbsANeighbourWithinBridgingReach`, `testFragmentContestedByTwoObjectsIsNotAbsorbedAndTheResultIsQualified` |
| Sub-voxel merge detection | `LiDARCoverageAnalyzer.hasInteriorPartition` | `testNeighbourTooCloseToSeparateIsRefusedAsAPossibleMerge` |
| Deterministic oriented bounds | `LiDARBoundsEstimator.estimate` | `testRotatedRectangularObjectUsesOrientedBounds`, `testIdenticalInputProducesIdenticalDimensions`, `testPointOrderWithinFramesDoesNotChangeDimensions`, `testSquareAndRoundFootprintsResolveOrientationTiesTheSameWayEveryRun`, `testUnevenFaceCoverageDoesNotRotateBoxAwayFromProductEdges` |
| Boundary contact per face (sides and top; a region whose bottom cuts the product surfaces as a support failure) | `LiDARSpatialRegion.faces(near:distance:)`, `analyze()` | `testObjectTouchingEachBoxRegionFaceIsReported`, `testObjectTouchingEachPrismEdgeIsReported`, `testRegionWhoseBottomLimitCutsTheProductReportsMissingSupport` |
| Viewpoint and surface coverage | `recordViewpoint`, `LiDARCoverageAnalyzer.surfaceCoverage`, `viewpointSpanDegrees` | `testNarrowViewingArcIsRefusedAsInsufficientViewpoints`, `testUnevenScanningCoverageIsReportedAndRaisesUncertainty`, `testViewpointSpanIsTheSmallestArcContainingAllViewpoints`, `testFramesWithoutCameraPosesAreQualifiedAsUnknownCoverage` |
| Stability analysis | `LiDARStabilityAnalyzer.consider` | `testUnstableEstimatesFollowedByRecovery`, `testUnstableDimensionsBlockAcceptanceUntilTheyAgree`, `testStabilityMustBeEarnedAgainAfterAnAnalysisWithNoEstimate`, `testStableEstimateKeepsRefiningInsteadOfFreezing`, `testSustainedJumpIsAdoptedButFlaggedWhileRecent` |
| Uncertainty and acceptance | `LiDARMeasurementAcceptance.uncertaintyCM`, `decide`, `LiDARMeasurementSession.process` | `testExcessiveUncertaintyIsRefused`, `testAcceptanceRequiresTheMinimumNumberOfFrames`, `testAcceptedScanIsRefusedOnceTheProductLeavesView`, `testFinishableResultIsReanalysedOnEveryFrameSoNewContactIsSeenImmediately`, `testQualifiedMeasurementIsNeverGradedGood` |
| Evidence record and guidance | `LiDARMeasurementSession.makeReport`, `LiDARMeasurementGuidance` | `testRectangularObjectOnHorizontalSupportIsAcceptedWithEvidence`, `testEveryReasonCodeHasGuidanceAndEvidenceRoundTripsThroughJSON` |
| Finish gated by the decision and tracking | `ManualProductScanStatus.finishIsAvailable`, `ManualARMeasurementState.finishProductScan` | `testFinishIsRefusedWhenAcceptanceRefusesEvenWithACompleteBox`, `testFinishProductScanIsRejectedWithTheMissingEvidence`, `testFinishProductScanIsRejectedWhileTrackingIsNotNormal` |
| Scan stopped on tracking reset | `ManualARMeasurementState.handleTrackingReset`, `ManualARSessionView.Coordinator.sessionWasInterrupted` | `testTrackingResetStopsTheScanAndDiscardsItsResult` (state only; the coordinator needs a device) |
| Seed inside a concave region | `ManualMeasurementGeometry.interiorPoint` | `testInteriorPointOfConcaveBoundaryLiesInsideIt` |

Test files: `LiDARMeasurementPipelineTests`, `LiDARMeasurementAdversarialTests`,
`LiDARVoxelFusionEngineTests`, `MeasurementEvaluationTests`,
`ManualMeasurementGeometryTests`.

## 8. App integration

The Add Product form owns the product draft. It can receive dimensions from
the manual region scan described here, the automatic LiDAR scan
(`ARObjectScannerView`, same pipeline with a locked box), Apple Object
Capture, or manual entry.

- `ManualARSessionView` owns the gravity-aligned AR session, centre raycasts,
  anchors and SceneKit rendering. It builds `LiDARDepthFrame`s and hands them
  to a `LiDARMeasurementSession` on a serial queue.
- `ManualARMeasurementState` owns stages and user actions.
- `ManualMeasurementGeometry` validates the marked polygon and limits.
- `ObjectCornerLockWindow` snaps a boundary marker to a recognised corner.

Shelf placement, retrieval-priority ranking and AR overlays consume the
stored dimensions downstream; they are not part of this mechanism.

Dimensions are displayed to one millimetre. That is display resolution, not
precision: the fused grid is 3 mm. The review screen states that the values
are estimates and shows the heuristic uncertainty with that label.

Configurable tolerance is applied per dimension after measurement:
`adjusted = measured × (1 + percentage) + fixed`. Defaults are 2% and 0.5 cm.

Requirements: iOS 17, camera permission, AR world tracking. LiDAR is
optional; without it the pipeline receives sparse ARKit feature points and
will usually refuse for lack of geometry.

## Limitations

**Not validated physically.** Every threshold is an engineering default.
No statement about accuracy on a device can be made from this work.

**Known systematic bias on synthetic data.** The evaluation shows a positive
bias of about one voxel per dimension. The quantization compensation, which
was inherited from the previous implementation, is its main source. Whether
real depth data needs that compensation is a calibration question for
physical validation; it was deliberately not tuned on synthetic data.

**Things the pipeline cannot detect:**

- Two products pressed together with their facing sides hidden are one box to
  a depth sensor (`testTouchingProductsWithHiddenFacingSidesMeasureAsOneBox`).
- A product with a real internal divider is refused as a possible merge
  (`testProductWithAnInternalDividerIsRefusedAsAPossibleMerge`).
- A neighbour scanned so sparsely that it never forms an object-sized
  component, within two voxels of an equally sparse target, can be bridged.
  Free-space gating (experimental, off) addresses this only for gaps the
  sensor saw through.
- A surface that returns depth only in patches smaller than an object is
  refused at the default reach. On one constructed synthetic case
  (`patchy-pair-3` in the ablation report) a small bridged group used to be
  offered as `qualified` with dimensions far below the truth; it is now
  refused as `possiblePartialObject`
  (`testSliverBridgedFromAPatchySurfaceIsRefusedAsPartial`). That check
  counts only fragments below object size, so a sliver whose neighbouring
  pieces each bridge to object size on their own is still not caught, and
  its threshold rests on synthetic cases alone.
- The seed is the region's interior point. If another object sits nearer to
  it than the intended product, that object is measured.
- Products flatter than the removal band (about 6 mm) cannot be separated
  from their support and are refused.
- A lower part of a stepped product that returns fewer than about a dozen
  voxels is not noticed under a dense shoulder.
- Side coverage is measured along each side's length only, not its height.

**Assumptions:** the product and support are stationary; the support is
horizontal with respect to gravity; the product rests on it; world +Y stays
gravity-aligned.

**Capture:** the manual flow requests `.sceneDepth` only, so ARKit's
temporally smoothed depth is not used. Depth extraction runs on the main
queue. Both predate this work and need device profiling before changing.

**Synthetic fixtures** have exact camera poses, independent Gaussian noise,
and, unless a scan plan asks for it (`modelsOcclusion`, used by the
free-space cases), no occlusion between objects. Real depth error is
correlated, worse at edges, and material-dependent.

## Physical iPhone validation procedure

### Recording and replaying scans

Record every validation scan, so the comparison between pipeline variants
runs on identical input and can be repeated after any code change.

1. Build and run from Xcode (a debug build). In **Add Product → measure**,
   reach the scan step. Under **Start Product Scan**, switch on
   **Save raw scan for validation**.
2. Type the **product name** (the same spelling every time, for example
   `tea-box`) and the **test** (for example `accuracy` or `neighbour-10mm`).
   Both are remembered between scans.
3. Scan as usual. When the scan stops, the app shows
   `Saved <name>.wlscan (N frames)`. A scan of half a minute is 10–20 MB.
4. Copy the recordings to the Mac: Files app → On My iPhone → Warehouse →
   `ScanRecordings`, or Finder → the iPhone → Files → Warehouse.
5. Put them in one folder with a `ground-truth.csv` made from
   [`validation/ground-truth-template.csv`](validation/ground-truth-template.csv),
   then run:

   ```sh
   ./scripts/replay-measurement.sh ~/Desktop/scans
   ```

   It writes `docs/measurement-replay-device.md`: per-variant error against
   the caliper values, by test, with every scan listed. The report also
   states for how many scans the replay reproduced the result the app
   showed; anything short of all of them needs explaining before the
   numbers are used.

Recording is offered in debug builds only. Points whose ray never crosses
the region are not stored, which cannot affect a measurement; the file
format is described in `LiDARScanRecording.swift`.

The variants replayed are the full pipeline, height from retained points
(step B off), unconditional connectivity (step C off), a wide bridging reach,
and the wide reach with free-space gating.

### Procedure

This procedure produces the first real accuracy data. Until it has been run,
treat every dimension as unverified.

**Equipment.** A LiDAR iPhone. Calipers or a steel rule read to 0.5 mm. At
least eight rigid products spanning 3–30 cm: boxes, a cylinder, one dark, one
glossy, one with a stepped profile. A matte table.

**Ground truth.** Measure each product's length, width and height three times
with calipers; record the mean.

**For each scan, record:** product; true dimensions; device model and iOS
version; distance; lighting; surface; reported dimensions; decision; reason
codes; and the stored `measurementEvidence` map.

**Protocol.**

1. *Accuracy.* Each product alone on the table, full orbit, five scans.
   Report signed and absolute error per axis, separately for `accepted` and
   `qualified`.
2. *Repeatability.* Ten scans of three products by one operator; then five
   each by two more operators. Report standard deviation per axis.
3. *Support.* Repeat (1) on a glossy table, a dark table, and a textured
   cloth. Compare signed height error with `supportPlane.residualMetres`.
4. *Neighbours.* A second product at 3, 6, 10, 20 and 40 mm from the target,
   five scans each. Record whether the result is merged, and which reason
   codes appear.
5. *Background.* The target 2, 5 and 10 cm in front of a wall and of a taller
   product.
6. *Clipping.* Mark the region so one side, then the top, cuts the product by
   about 1 cm. Record whether `regionBoundaryContact` is reported.
7. *Coverage.* Scan from one side only; two adjacent sides; without the top.
8. *Sparse surfaces.* Dark and glossy products. Record
   `components.connectivityMode`.
9. *Tracking.* Cover the camera for two seconds mid-scan; background and
   foreground the app; walk away and return. Confirm the scan stops and asks
   for the region to be checked.
10. *Rejection rate.* Across (1)–(3), the share of complete, careful scans
    that are refused, with reasons.

**Decide from the data:** whether `extentQuantizationCompensation` should
change; whether the uncertainty heuristic tracks real error well enough to
be shown; and which thresholds need calibrating per device.

**Regression.** Also run the existing checks: three- and four-point regions,
undo/reset/replace for every marker, self-crossing boundaries, camera denial,
non-LiDAR warning, manual entry, tolerance editing, save and reopen.

## Synthetic evaluation

```sh
./scripts/evaluate-measurement.sh
```

Compiles the pipeline sources into a macOS command-line tool, runs it and a
simple baseline over generated scans, and writes
[`measurement-evaluation-synthetic.md`](measurement-evaluation-synthetic.md).
It reports dimension error, repeatability, false merging, clipping detection
and rejection rate. All of it is synthetic and labelled as such.

```sh
./scripts/evaluate-ablation.sh
```

Runs the same generated scans with one mechanism switched off or on at a
time and writes
[`measurement-ablation-synthetic.md`](measurement-ablation-synthetic.md):
height from retained points, unconditional connectivity, and free-space
gating at a wide reach. The switches (`heightUsesSupportCoordinate`,
`connectivityIsConditional`) exist for this comparison; the app never sets
them. Also synthetic.
