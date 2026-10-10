# Synthetic measurement evaluation

> **SYNTHETIC RESULTS.** Every number below comes from generated scans
> (`WarehouseAppTests/SyntheticScanFixtures.swift`): exact camera poses,
> Gaussian ray noise, no occlusion between objects. They show how the
> pipeline's logic behaves on that generator. They are **not** measurements
> of accuracy on an iPhone and must not be quoted as such. Physical
> validation is described in `docs/manual-ar-measurement.md`.

Regenerate with `./scripts/evaluate-measurement.sh`. Generator seed
`20261009`, 80 cases, default
`LiDARFusionConfiguration.smallObject`. Built from commit 62fe8e1 plus uncommitted changes with swift-driver version: 1.120.5 Apple Swift version 6.1 (swiftlang-6.1.0.110.21 clang-1700.0.13.3).

## How to read this (synthetic)

- **Strengthened**: `LiDARMeasurementSession`, the app's pipeline.
- **Naive baseline**: single pass, largest component at a fixed wide radius,
  height over the points left after floor removal, no refusal. A sanity
  floor, intentionally weak.
- **Seeded baseline**: the same, but it selects the component nearest the
  seed the app pipeline is given and measures height from its floor
  estimate. Input-matched and still simple. This is the fairer comparison.
- Neither baseline is the app's previous implementation. Both reuse the
  pipeline's default voxel size, floor band and wide radius.
- **These are in-family regression results, not held-out performance.** The
  cases use the same generative model as the unit tests and several of the
  same scenario families, and the pipeline's thresholds were chosen with
  that family in view. No threshold was changed after these cases were
  first run, but the repository history cannot prove that ordering. An
  independent generator or physical scans should be expected to give
  worse numbers.
- `clipped` and `deficient` cases are built around the pipeline's own
  thresholds. They show a rule fires, not that the rule is right.

## Summary (synthetic)

| Metric (synthetic) | Strengthened | Seeded baseline | Naive baseline |
|---|---|---|---|
| Isolated cases answered | 16 of 16 offered | 16 of 16 | 16 of 16 |
| Dimension error, mean absolute (cm) | 0.34 | 3.23 | 3.17 |
| Dimension error, median absolute (cm) | 0.35 | 0.49 | 0.41 |
| Dimension error, worst (cm) | 0.51 | 27.84 | 27.84 |
| Dimension error, mean signed (cm) | 0.34 | 3.23 | 3.03 |
| Repeatability, mean std dev across noise seeds (cm) | 0.01 | 0.03 | 0.03 |
| Oversized result offered in crowded scenes | 0 of 18 | 4 of 18 | 14 of 18 |
| Oversized estimate produced but refused | 1 of 18 | n/a (cannot refuse) | n/a (cannot refuse) |
| Clipping reported as boundary contact | 7 of 10 | no check | no check |
| Clipped cases refused or unanswered | 10 of 10 | 3 of 10 | 3 of 10 |
| Boundary-contact false alarms, all unclipped cases | 0 of 70 | n/a | n/a |

Notes on the metrics:

- Dimension error uses the `isolated` category only (distinct single
  objects, one scan each). For the strengthened pipeline it counts only
  results it offers (accepted or qualified); the baselines cannot refuse,
  so every answer counts.
- Mean and worst baseline error are dominated by a few isolated cases in
  which support noise exceeds the baselines' fixed floor band, so support
  residue joins the object (the rows near 31 cm). The median shows the
  typical case.
- Repeatability uses 24 runs; the strengthened pipeline refused
  0 of them, and refused runs are left out of its figure.
- "Oversized" means any reported dimension more than
  max(1.00 cm, 15%) above the true value in a scene with a neighbour or
  background object. It is a proxy for merging: it also counts any other
  large over-estimate, and misses contamination that does not enlarge the
  result.
- A baseline that returns nothing for a clipped case has not detected
  clipping; it simply found no geometry.

## Rejection rate by category (synthetic)

| Category | Cases | Strengthened refused | Seeded baseline: no answer | Naive baseline: no answer |
|---|---|---|---|---|
| isolated | 16 | 0% | 0% | 0% |
| repeatability | 24 | 0% | 0% | 0% |
| neighbour | 12 | 8% | 0% | 0% |
| background | 6 | 0% | 0% | 0% |
| sparse | 6 | 0% | 0% | 0% |
| clipped | 10 | 100% | 30% | 30% |
| deficient | 6 | 100% | 0% | 0% |

`clipped` and `deficient` cases are built so that refusal is the intended
outcome. Refusals elsewhere are scans the pipeline would not finish even
though the object was fully scanned.

## Per-case results (synthetic)

| Case | True L × W × H (cm) | Strengthened | Decision | Reasons | Seeded baseline | Naive baseline |
|---|---|---|---|---|---|---|
| isolated-0 | 6.4 × 3.5 × 6.4 | 6.8 × 3.9 × 6.6 | accepted |  | 6.8 × 3.9 × 6.7 | 6.8 × 3.9 × 6.1 |
| isolated-1 | 10.2 × 5.4 × 5.3 | 10.6 × 5.9 × 5.5 | accepted |  | 10.6 × 5.9 × 5.6 | 10.6 × 5.9 × 5.0 |
| isolated-2 | 7.3 × 4.1 × 8.2 | 7.7 × 4.7 × 8.4 | accepted |  | 13.1 × 10.2 × 8.8 | 13.1 × 10.2 × 8.1 |
| isolated-3 | 10.4 × 8.2 × 5.2 | 10.9 × 8.6 × 5.3 | accepted |  | 31.5 × 31.4 × 5.8 | 31.5 × 31.4 × 5.2 |
| isolated-4 | 9.6 × 7.5 × 8.6 | 10.1 × 7.9 × 8.7 | accepted |  | 10.1 × 8.1 × 8.9 | 10.1 × 8.1 × 8.3 |
| isolated-5 | 12.4 × 7.9 × 7.1 | 12.8 × 8.3 × 7.4 | accepted |  | 12.9 × 8.4 × 7.5 | 12.9 × 8.4 × 6.9 |
| isolated-6 | 13.5 × 4.7 × 8.0 | 13.9 × 5.2 × 8.2 | accepted |  | 14.0 × 5.3 × 8.4 | 14.0 × 5.3 × 7.8 |
| isolated-7 | 7.9 × 7.3 × 8.7 | 8.3 × 7.7 × 8.9 | accepted |  | 15.2 × 13.4 × 9.2 | 15.2 × 13.4 × 8.6 |
| isolated-8 | 11.6 × 4.7 × 11.5 | 12.0 × 5.2 × 11.6 | accepted |  | 12.1 × 5.4 × 11.8 | 12.1 × 5.4 × 11.2 |
| isolated-9 | 5.9 × 4.9 × 3.7 | 6.3 × 5.4 × 3.9 | accepted |  | 6.4 × 5.5 × 4.0 | 6.4 × 5.5 × 3.4 |
| isolated-10 | 5.7 × 3.5 × 3.2 | 6.2 × 4.0 × 3.5 | accepted |  | 31.5 × 31.4 × 3.8 | 31.5 × 31.4 × 3.2 |
| isolated-11 | 10.8 × 7.3 × 4.2 | 11.2 × 7.7 × 4.4 | accepted |  | 17.7 × 16.2 × 4.8 | 17.7 × 16.2 × 4.2 |
| isolated-cylinder-0 | 7.4 × 7.4 × 8.4 | 7.7 × 7.7 × 8.6 | accepted |  | 7.8 × 7.7 × 8.7 | 7.8 × 7.7 × 8.1 |
| isolated-cylinder-1 | 8.8 × 8.8 × 11.6 | 9.1 × 9.1 × 11.9 | accepted |  | 9.2 × 9.1 × 11.9 | 9.2 × 9.1 × 11.2 |
| isolated-cylinder-2 | 7.2 × 7.2 × 8.4 | 7.5 × 7.5 × 8.6 | accepted |  | 7.5 × 7.4 × 8.7 | 7.5 × 7.4 × 8.1 |
| isolated-cylinder-3 | 7.1 × 7.1 × 5.4 | 7.4 × 7.3 × 5.6 | accepted |  | 7.4 × 7.3 × 5.7 | 7.4 × 7.3 × 5.1 |
| repeat-0-0 | 9.2 × 3.4 × 7.7 | 9.7 × 3.9 × 7.8 | accepted |  | 9.8 × 4.0 × 8.0 | 9.8 × 4.0 × 7.4 |
| repeat-0-1 | 9.2 × 3.4 × 7.7 | 9.7 × 3.9 × 7.8 | accepted |  | 9.7 × 4.0 × 8.0 | 9.7 × 4.0 × 7.3 |
| repeat-0-2 | 9.2 × 3.4 × 7.7 | 9.7 × 3.9 × 7.8 | accepted |  | 9.7 × 4.0 × 8.0 | 9.7 × 4.0 × 7.3 |
| repeat-0-3 | 9.2 × 3.4 × 7.7 | 9.7 × 3.9 × 7.8 | accepted |  | 9.7 × 4.1 × 8.0 | 9.7 × 4.1 × 7.4 |
| repeat-0-4 | 9.2 × 3.4 × 7.7 | 9.7 × 3.9 × 7.8 | accepted |  | 9.7 × 4.0 × 8.0 | 9.7 × 4.0 × 7.4 |
| repeat-0-5 | 9.2 × 3.4 × 7.7 | 9.7 × 3.9 × 7.8 | accepted |  | 9.7 × 3.9 × 8.0 | 9.7 × 3.9 × 7.4 |
| repeat-0-6 | 9.2 × 3.4 × 7.7 | 9.7 × 3.9 × 7.8 | accepted |  | 9.7 × 4.0 × 8.0 | 9.7 × 4.0 × 7.4 |
| repeat-0-7 | 9.2 × 3.4 × 7.7 | 9.7 × 3.9 × 7.8 | accepted |  | 9.7 × 4.1 × 8.0 | 9.7 × 4.1 × 7.4 |
| repeat-1-0 | 7.6 × 3.7 × 7.4 | 8.0 × 4.3 × 7.7 | accepted |  | 8.0 × 4.3 × 7.7 | 8.0 × 4.3 × 7.1 |
| repeat-1-1 | 7.6 × 3.7 × 7.4 | 8.0 × 4.2 × 7.7 | accepted |  | 8.1 × 4.3 × 7.8 | 8.1 × 4.3 × 7.2 |
| repeat-1-2 | 7.6 × 3.7 × 7.4 | 8.0 × 4.3 × 7.7 | accepted |  | 8.0 × 4.3 × 7.7 | 8.0 × 4.3 × 7.1 |
| repeat-1-3 | 7.6 × 3.7 × 7.4 | 8.0 × 4.2 × 7.7 | accepted |  | 8.2 × 4.3 × 7.8 | 8.2 × 4.3 × 7.2 |
| repeat-1-4 | 7.6 × 3.7 × 7.4 | 8.0 × 4.2 × 7.7 | accepted |  | 8.1 × 4.2 × 7.7 | 8.1 × 4.2 × 7.1 |
| repeat-1-5 | 7.6 × 3.7 × 7.4 | 8.0 × 4.2 × 7.7 | accepted |  | 8.1 × 4.2 × 7.7 | 8.1 × 4.2 × 7.1 |
| repeat-1-6 | 7.6 × 3.7 × 7.4 | 8.0 × 4.2 × 7.7 | accepted |  | 8.0 × 4.3 × 7.7 | 8.0 × 4.3 × 7.1 |
| repeat-1-7 | 7.6 × 3.7 × 7.4 | 8.0 × 4.2 × 7.7 | accepted |  | 8.0 × 4.4 × 7.7 | 8.0 × 4.4 × 7.1 |
| repeat-2-0 | 7.9 × 6.7 × 5.8 | 8.4 × 7.1 × 6.0 | accepted |  | 8.4 × 7.2 × 6.1 | 8.4 × 7.2 × 5.5 |
| repeat-2-1 | 7.9 × 6.7 × 5.8 | 8.4 × 7.1 × 6.0 | accepted |  | 8.5 × 7.1 × 6.1 | 8.5 × 7.1 × 5.5 |
| repeat-2-2 | 7.9 × 6.7 × 5.8 | 8.4 × 7.1 × 6.0 | accepted |  | 8.5 × 7.2 × 6.1 | 8.5 × 7.2 × 5.5 |
| repeat-2-3 | 7.9 × 6.7 × 5.8 | 8.4 × 7.1 × 6.0 | accepted |  | 8.5 × 7.2 × 6.1 | 8.5 × 7.2 × 5.5 |
| repeat-2-4 | 7.9 × 6.7 × 5.8 | 8.4 × 7.1 × 6.0 | accepted |  | 8.5 × 7.2 × 6.1 | 8.5 × 7.2 × 5.5 |
| repeat-2-5 | 7.9 × 6.7 × 5.8 | 8.4 × 7.1 × 6.0 | accepted |  | 8.4 × 7.2 × 6.1 | 8.4 × 7.2 × 5.5 |
| repeat-2-6 | 7.9 × 6.7 × 5.8 | 8.4 × 7.1 × 6.0 | accepted |  | 8.4 × 7.2 × 6.1 | 8.4 × 7.2 × 5.5 |
| repeat-2-7 | 7.9 × 6.7 × 5.8 | 8.4 × 7.1 × 6.0 | accepted |  | 8.4 × 7.2 × 6.1 | 8.4 × 7.2 × 5.5 |
| neighbour-0-gap8mm | 7.9 × 6.8 × 3.4 | 8.3 × 7.1 × 3.6 | qualified | nearbyObjectClose | 16.9 × 7.3 × 10.4 | 16.9 × 7.3 × 9.8 |
| neighbour-1-gap21mm | 7.2 × 4.1 × 6.2 | 7.6 × 4.6 × 6.5 | accepted |  | 7.6 × 4.5 × 6.5 | 8.1 × 8.1 × 6.9 |
| neighbour-2-gap7mm | 12.9 × 3.1 × 11.6 | 13.2 × 3.5 × 11.9 | qualified | nearbyObjectClose | 19.8 × 7.4 × 11.9 | 19.8 × 7.4 × 11.3 |
| neighbour-3-gap13mm | 7.3 × 4.6 × 8.3 | 7.6 × 5.2 × 8.6 | qualified | nearbyObjectClose | 7.6 × 5.1 × 8.6 | 7.6 × 5.1 × 8.0 |
| neighbour-4-gap16mm | 5.6 × 5.2 × 9.6 | 6.0 × 5.8 × 9.8 | accepted |  | 6.2 × 5.7 × 9.8 | 8.4 × 4.4 × 12.6 |
| neighbour-5-gap8mm | 12.6 × 5.8 × 8.0 | 20.3 × 6.5 × 8.1 | refused | possibleMergedObjects, sustainedDimensionJump | 20.4 × 6.7 × 8.3 | 20.4 × 6.7 × 7.7 |
| neighbour-6-gap17mm | 11.0 × 8.9 × 5.0 | 11.4 × 9.4 × 5.3 | accepted |  | 11.6 × 9.3 × 5.3 | 11.6 × 9.3 × 4.7 |
| neighbour-7-gap14mm | 13.5 × 8.7 × 4.8 | 13.9 × 9.1 × 5.0 | qualified | nearbyObjectClose | 14.0 × 9.3 × 5.1 | 14.0 × 9.3 × 4.5 |
| neighbour-8-gap24mm | 11.9 × 5.2 × 5.0 | 12.4 × 5.5 × 5.3 | accepted |  | 12.3 × 5.8 × 5.3 | 12.3 × 5.8 × 4.7 |
| neighbour-9-gap10mm | 8.8 × 4.5 × 6.1 | 9.1 × 4.8 × 6.2 | qualified | nearbyObjectClose | 17.3 × 5.5 × 6.4 | 17.3 × 5.5 × 5.8 |
| neighbour-10-gap19mm | 4.9 × 4.6 × 4.3 | 5.3 × 5.2 × 4.5 | accepted |  | 5.4 × 5.1 × 4.5 | 10.5 × 5.7 × 11.9 |
| neighbour-11-gap15mm | 8.6 × 3.3 × 5.9 | 9.0 × 3.7 × 6.0 | qualified | nearbyObjectClose | 9.1 × 3.9 × 6.2 | 9.3 × 7.2 × 5.4 |
| background-0 | 7.9 × 5.0 × 9.8 | 8.3 × 5.3 × 9.9 | accepted |  | 8.5 × 5.6 × 10.1 | 24.2 × 4.3 × 10.5 |
| background-1 | 8.6 × 4.6 × 8.7 | 8.9 × 4.9 × 8.9 | accepted |  | 9.1 × 5.1 × 9.0 | 24.3 × 3.5 × 9.8 |
| background-2 | 9.7 × 9.0 × 6.1 | 10.1 × 9.4 × 6.3 | accepted |  | 10.3 × 9.5 × 6.5 | 24.3 × 4.5 × 12.8 |
| background-3 | 10.5 × 4.5 × 7.9 | 10.8 × 4.8 × 8.0 | accepted |  | 11.0 × 5.1 × 8.2 | 24.5 × 4.6 × 14.3 |
| background-4 | 12.6 × 6.2 × 5.5 | 13.0 × 6.6 × 5.7 | accepted |  | 12.9 × 6.9 × 5.9 | 24.4 × 4.4 × 12.2 |
| background-5 | 12.9 × 5.8 × 6.0 | 13.2 × 6.4 × 6.2 | accepted |  | 13.4 × 6.3 × 6.3 | 24.4 × 4.2 × 16.7 |
| sparse-0 | 6.6 × 4.4 × 8.9 | 6.9 × 4.7 × 9.0 | accepted |  | 6.6 × 4.4 × 8.9 | 6.6 × 4.4 × 8.1 |
| sparse-1 | 11.3 × 6.8 × 3.3 | 11.6 × 7.1 × 3.5 | accepted |  | 11.3 × 6.9 × 3.3 | 11.3 × 6.9 × 2.5 |
| sparse-2 | 9.3 × 3.6 × 5.5 | 9.6 × 3.9 × 5.6 | accepted |  | 9.3 × 3.6 × 5.5 | 9.3 × 3.6 × 4.7 |
| sparse-3 | 7.3 × 7.2 × 10.3 | 7.6 × 7.5 × 10.5 | accepted |  | 7.4 × 7.2 × 10.3 | 7.4 × 7.2 × 9.6 |
| sparse-4 | 5.9 × 4.2 × 10.5 | 6.2 × 4.5 × 10.7 | accepted |  | 5.9 × 4.2 × 10.5 | 5.9 × 4.2 × 9.8 |
| sparse-5 | 11.8 × 3.6 × 11.5 | 12.1 × 3.9 × 11.6 | accepted |  | 11.8 × 3.6 × 11.5 | 11.8 × 3.6 × 10.7 |
| clipped-0-top | 12.3 × 9.1 × 10.4 | 12.6 × 9.5 × 9.8 | refused | regionBoundaryContact, topSurfaceSparse | 12.8 × 9.7 × 9.6 | 12.8 × 9.7 × 9.0 |
| clipped-1-side | 5.7 × 4.6 × 11.4 | — | refused | insufficientGeometryAboveSupport | — | — |
| clipped-2-side | 10.4 × 8.4 × 4.8 | 9.6 × 8.8 × 4.9 | refused | regionBoundaryContact, supportNotBeyondFootprint | 8.7 × 8.6 × 4.9 | 8.7 × 8.6 × 4.2 |
| clipped-3-top | 12.7 × 9.2 × 6.0 | 13.0 × 9.5 × 4.9 | refused | regionBoundaryContact, topSurfaceSparse | 12.8 × 9.7 × 4.6 | 12.8 × 9.7 × 4.0 |
| clipped-4-side | 6.4 × 6.3 × 4.3 | — | refused | insufficientGeometryAboveSupport | — | — |
| clipped-5-side | 6.8 × 5.9 × 11.1 | — | refused | geometryBelowSupport, insufficientGeometryAboveSupport | — | — |
| clipped-6-top | 13.7 × 6.2 × 10.6 | 14.2 × 6.6 × 10.2 | refused | regionBoundaryContact, topSurfaceSparse | 14.0 × 6.8 × 9.9 | 14.0 × 6.8 × 9.3 |
| clipped-7-side | 8.0 × 3.7 × 11.9 | 6.0 × 4.1 × 12.1 | refused | regionBoundaryContact | 5.3 × 4.3 × 12.2 | 5.3 × 4.3 × 11.5 |
| clipped-8-side | 7.2 × 4.5 × 6.1 | 7.1 × 5.0 × 6.3 | refused | regionBoundaryContact | 6.2 × 5.1 × 6.5 | 6.2 × 5.1 × 5.8 |
| clipped-9-top | 6.0 × 3.1 × 6.1 | 6.4 × 3.5 × 5.7 | refused | regionBoundaryContact | 6.2 × 3.3 × 5.5 | 6.2 × 3.3 × 4.9 |
| deficient-0-narrow-arc | 12.7 × 3.1 × 5.1 | 13.0 × 3.6 × 5.3 | refused | insufficientViewpoints | 12.7 × 3.6 × 5.5 | 12.7 × 3.6 × 4.9 |
| deficient-1-few-frames | 7.7 × 5.8 × 4.5 | 8.1 × 6.2 × 4.7 | refused | insufficientAcceptedFrames | 8.1 × 6.2 × 4.7 | 8.1 × 6.2 × 4.1 |
| deficient-2-one-side-low | 7.6 × 4.5 × 5.3 | 7.9 × 5.0 × 5.4 | refused | insufficientViewpoints, excessiveUncertainty, sparseSideCoverage, topSurfaceSparse | 7.9 × 5.2 × 5.3 | 7.9 × 5.2 × 4.5 |
| deficient-3-narrow-arc | 7.9 × 5.1 × 10.5 | 8.4 × 5.6 × 10.7 | refused | insufficientViewpoints | 8.3 × 5.7 × 10.8 | 8.3 × 5.7 × 10.2 |
| deficient-4-few-frames | 6.0 × 5.1 × 4.6 | 6.4 × 5.6 × 4.8 | refused | insufficientAcceptedFrames | 6.5 × 5.5 × 4.9 | 6.5 × 5.5 × 4.3 |
| deficient-5-one-side-low | 12.9 × 8.4 × 6.1 | 13.3 × 8.9 × 6.3 | refused | insufficientViewpoints, excessiveUncertainty, sparseSideCoverage, topSurfaceSparse | 13.3 × 9.2 × 6.2 | 13.3 × 9.2 × 5.4 |
