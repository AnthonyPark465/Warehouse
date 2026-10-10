# Invention-disclosure outline: object measurement from multi-frame depth

**Purpose.** A technical outline for review by a patent attorney. It
describes what the software does and where. It is not a set of claims.

**Status of every statement below.**

- No prior-art search has been done. Nothing here asserts novelty,
  inventiveness, or patentability. "Candidate inventive mechanism" means only
  "the part the authors would like assessed".
- All test results are **synthetic** (generated scans). No physical accuracy
  has been measured.
- The following are standard techniques and are **not** put forward on their
  own: ARKit raycasting, LiDAR scanning, voxelization, connected-component
  labelling, minimum-area bounding rectangles, percentile trimming, warehouse
  placement, and AR overlays.

## 1. Technical field

Dimensional measurement of a physical object from several registered depth
frames captured by a handheld device, for use as stored product dimensions.

## 2. Technical problem

A handheld depth sensor gives noisy, incomplete range images. Measuring an
object standing on a surface from them has three coupled difficulties:

1. Removing the supporting surface also removes the object's base, because
   noise merges the two. Height measured from the remaining points is short
   by the removed thickness.
2. Gaps in depth data and gaps between adjacent objects are locally
   identical. A segmentation tolerant of the first merges the second.
3. A measurement can be numerically stable and wrong: one side unseen, the
   object clipped by the scan region, or frames fused across a change in the
   device's coordinate system.

## 3. Candidate inventive mechanism (the combination)

The candidate is the **combination** of the following steps operating on
multi-frame depth data, not any step alone.

A. **Validated multi-frame fusion.** Depth points enter a voxel grid only
   from frames that pass tracking, timing, and coordinate-continuity checks.
   A voxel must be observed in several distinct frames. Any indication that
   the coordinate system changed discards all fused evidence.

B. **Support plane with two roles.** The supporting surface is located from
   the height distribution of fused voxels (peak of the lowest populated
   band; noise estimated from below the plane only). Its points and an
   adaptive noise band are removed from segmentation. Its coordinate is
   retained and used as the lower boundary of the object's height.

C. **Conditional connectivity.** Segmentation is strict first. A component
   that reaches object size under strict connectivity is used as it is and is
   never joined to anything. A wider connectivity is applied only among
   components too small to be objects. A group bridged that way is selected
   only when it reaches object size and is the candidate nearest the seed,
   and its use is recorded.

D. **Evidence checks before acceptance.** Per-face contact with the scan
   region, arc of viewpoints, per-side surface support, agreement between
   recent estimates, a dense internal sheet indicating two merged objects,
   and consistency of the support plane with the selected object.

E. **Refuse or qualify.** A result is refused, or returned with explicit
   qualifications and a stored evidence record, according to those checks.

F. **Free-space gating of the wider connectivity (experimental, off by
   default; added 2026-10-10).** For each voxel of the region, the number of
   frames in which a depth ray passed through it to a farther return is
   kept. Two fragments are not joined when a voxel on the line between them
   was seen through in several frames, and in more frames than it was seen
   occupied. A missing return leaves a voxel unobserved; a ray through it
   shows it empty. This lets the wider connectivity of (C) reach farther
   without joining two sparsely scanned objects across a gap the sensor saw
   into.

Points an attorney may wish to examine:

- (B) Decoupling the support's segmentation role from its metrological role,
  so the removal band can track measured noise without affecting height.
- (C) Using object-size under strict connectivity as the condition that both
  triggers and bounds the wider connectivity.
- (B)+(C)+(D) together as a measurement that carries its own validity
  evidence.
- (C)+(F): the wider connectivity conditioned on component size **and** on
  observed free space. A preliminary search found the general ideas behind
  both published ([`prior-art-preliminary-search.md`](prior-art-preliminary-search.md)),
  so only the specific mechanism, with device data, is put forward.

## 4. Where each step is implemented

| Step | Source | Representative test |
|---|---|---|
| A | `LiDARVoxelFusionEngine.integrate(frame:)`, `invalidateEvidence`, `expireWeakVoxels` | `testCoordinateEpochChangeDiscardsEarlierEvidence`, `testTransientSingleFrameOutliersAreRejected` |
| B | `LiDARSupportPlaneEstimator.estimate`; `LiDARVoxelFusionEngine.analyze` (`aboveSupport`); `LiDARBoundsEstimate.height` | `testSupportPlaneNoiseDoesNotReduceObjectHeight`, `testRetainedSupportCoordinateAvoidsTheHeightLossOfFloorRemoval` |
| C | `LiDARComponentSelector.select` | `testSparseSurfaceUsesExpandedConnectivityAndRecordsTheFallback`, `testExpandedConnectivityStillRejectsAnUnrelatedObjectWithinBridgingReach`, `testObjectSizedStrictComponentNeverAbsorbsANeighbourWithinBridgingReach` |
| D | `LiDARVoxelFusionEngine.analyze`; `LiDARCoverageAnalyzer`; `LiDARStabilityAnalyzer.consider` | `testObjectTouchingEachBoxRegionFaceIsReported`, `testNarrowViewingArcIsRefusedAsInsufficientViewpoints`, `testNeighbourTooCloseToSeparateIsRefusedAsAPossibleMerge`, `testLowerShelfIsNotAcceptedAsTheProductsSupport` |
| E | `LiDARMeasurementAcceptance.decide`; `LiDARMeasurementSession.makeReport`; `LiDARMeasurementEvidence` | `testRectangularObjectOnHorizontalSupportIsAcceptedWithEvidence`, `testExcessiveUncertaintyIsRefused` |
| F | `LiDARFreeSpaceGrid`; `LiDARVoxelFusionEngine.analyze` (`isObservedEmpty`); `LiDARComponentSelector.select` (`bridges`) | `testAGapSeenThroughIsNotBridgedButAnUnobservedOneIs`, `testFreeSpaceSeparatesTwoPatchyObjectsThatAWiderReachAloneJoins` |

Full design and the complete mapping: [`manual-ar-measurement.md`](manual-ar-measurement.md).

## 5. Technical effects that can be measured

Stated as effects to be measured, not as achieved performance.

- Height error attributable to support removal.
- Rate at which an adjacent or background object enlarges the result.
- Rate at which sparsely scanned objects are measured, and marked as such.
- Rate at which clipped or under-observed objects are refused.
- Identity of output for identical input.

Synthetic figures: [`measurement-evaluation-synthetic.md`](measurement-evaluation-synthetic.md).
Synthetic ablation (each of B, C and F switched on or off on identical
scans): [`measurement-ablation-synthetic.md`](measurement-ablation-synthetic.md).
Physical figures: none yet. Procedure: `manual-ar-measurement.md`, "Physical
iPhone validation procedure". Scans recorded by the app can be replayed
through every variant with `scripts/replay-measurement.sh`, which is how the
same ablation is to be produced from device data.

## 6. What is not substantiated

- Accuracy, precision, or repeatability on any physical device.
- Behaviour on reflective, transparent, or very dark materials.
- Any comparison with the app's previous implementation or with third-party
  measurement software. The evaluation baseline was written for the
  comparison and is deliberately simple.
- That the thresholds are suitable beyond hand-sized objects.
- Anything about (F) outside constructed synthetic cases: whether real
  products fragment in the way those cases assume, and whether a phone's
  depth map resolves the gaps it relies on.

## 7. Known limitations relevant to scope

- Two objects in contact with hidden facing sides are measured as one.
- Wider connectivity can still join two sparsely scanned objects that are
  within its reach of each other.
- The selected object is the one nearest an interior point of the marked
  region, not one the user points at directly.
- The support must be horizontal and visible around the object.

## 8. Questions for the attorney

1. Is the combination in section 3 worth a prior-art search, and in which
   classes?
2. Which of A–E, if any, should be the focus?
3. What physical-validation data would be needed to support a filing?
4. Does public availability of this repository affect timing?

## 9. Record

- Implementation date of the mechanism in this form: 2026-10-09.
  (F), the ablation switches and scan recording: 2026-10-10.
- Preliminary prior-art notes: [`prior-art-preliminary-search.md`](prior-art-preliminary-search.md),
  2026-10-10. Not a professional search.
- Authorship and contribution: to be confirmed by the project owner.
- Development used AI coding assistants (Claude as implementer, OpenAI Codex
  as independent reviewer). How that bears on inventorship is a question for
  the attorney.
