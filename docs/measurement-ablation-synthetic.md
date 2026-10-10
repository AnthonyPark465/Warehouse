# Synthetic ablation of the measurement pipeline

> **SYNTHETIC RESULTS.** Every number below comes from generated scans
> (`WarehouseAppTests/SyntheticScanFixtures.swift`). They show what each
> mechanism contributes on that generator. They are **not** measurements
> of accuracy on an iPhone and must not be quoted as such. The same
> comparison on recorded device scans is produced by
> `scripts/replay-measurement.sh`.

Regenerate with `./scripts/evaluate-ablation.sh`. Generator seeds
`20261009` (part 1) and `20261010` (part 2). Built from commit 62fe8e1 plus uncommitted changes with swift-driver version: 1.120.5 Apple Swift version 6.1 (swiftlang-6.1.0.110.21 clang-1700.0.13.3).

## How to read this (synthetic)

- Each variant differs in **one** setting from the variant it is compared
  with: the full pipeline, except that *Wide reach + free space* is
  compared with *Wide reach*. All variants see identical frames.
- **Offered** means accepted or qualified: a result the user would get.
- **Correct** means offered with every dimension within max(1.0 cm, 15%)
  of the truth. That margin is loose: it exists to tell a merged or
  truncated result from a sound one, not to grade accuracy.
- **Oversized** and **undersized** are offered results outside the margin.
  The classes are exclusive: a result with one dimension too large and
  another too small counts as oversized.
- These are in-family results. The generator, the scenarios and the
  pipeline's thresholds were written by the same authors.

## Part 1: steps B and C (synthetic)

The 80 cases of `docs/measurement-evaluation-synthetic.md`, without
occlusion, exactly as that report runs them.

- **Full pipeline**: The app's default configuration.
- **Height from retained points**: Support still removed for segmentation, but height is measured from the lowest product voxel left, not from the support coordinate.
- **Unconditional connectivity**: Every component is bridged at the expanded reach, object-sized or not.

| Variant | Isolated offered | Height error, mean signed (cm) | Height error, mean absolute (cm) | Length/width error, mean absolute (cm) | Crowded: correct | Crowded: oversized offered | Crowded: oversized refused | Answerable cases refused |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Full pipeline | 16 of 16 | +0.20 | 0.20 | 0.41 | 17 of 18 | 0 | 1 | 1 of 64 |
| Height from retained points | 16 of 16 | -0.43 | 0.43 | 0.41 | 17 of 18 | 0 | 1 | 1 of 64 |
| Unconditional connectivity | 16 of 16 | +0.20 | 0.20 | 0.41 | 15 of 18 | 0 | 3 | 3 of 64 |

Notes:

- Height error uses `isolated` cases only, offered results only.
- "Crowded" is the `neighbour` and `background` categories. "Answerable"
  is every category except `clipped` and `deficient`.
- Unconditional connectivity bridges one missing voxel between any two
  components. It differs from the full pipeline wherever two components
  lie within that reach: a neighbouring object, or pieces of the same
  object, which is why the `sparse` cases change from accepted to
  qualified.

### Cases where a variant differs from the full pipeline (synthetic)

| Case | True L × W × H (cm) | Full pipeline | Height from retained points | Unconditional connectivity |
|---|---|---|---|---|
| neighbour-0-gap8mm | 7.9 × 6.8 × 3.4 | 8.3 × 7.1 × 3.6 qualified | 8.3 × 7.1 × 3.0 qualified | 16.7 × 7.1 × 10.2 refused |
| neighbour-2-gap7mm | 12.9 × 3.1 × 11.6 | 13.2 × 3.5 × 11.9 qualified | 13.2 × 3.5 × 11.2 qualified | 19.7 × 7.2 × 11.9 refused |
| sparse-0 | 6.6 × 4.4 × 8.9 | 6.9 × 4.7 × 9.0 accepted | 6.9 × 4.7 × 8.3 accepted | 6.9 × 4.7 × 9.0 qualified |
| sparse-1 | 11.3 × 6.8 × 3.3 | 11.6 × 7.1 × 3.5 accepted | 11.6 × 7.1 × 2.7 accepted | 11.6 × 7.1 × 3.5 qualified |
| sparse-2 | 9.3 × 3.6 × 5.5 | 9.6 × 3.9 × 5.6 accepted | 9.6 × 3.9 × 4.9 accepted | 9.6 × 3.9 × 5.6 qualified |
| sparse-3 | 7.3 × 7.2 × 10.3 | 7.6 × 7.5 × 10.5 accepted | 7.6 × 7.5 × 9.7 accepted | 7.6 × 7.5 × 10.5 qualified |
| sparse-4 | 5.9 × 4.2 × 10.5 | 6.2 × 4.5 × 10.7 accepted | 6.2 × 4.5 × 9.9 accepted | 6.2 × 4.5 × 10.7 qualified |
| sparse-5 | 11.8 × 3.6 × 11.5 | 12.1 × 3.9 × 11.6 accepted | 12.1 × 3.9 × 10.9 accepted | 12.1 × 3.9 × 11.6 qualified |

## Part 2: free-space gating (synthetic)

36 purpose-built cases **with occlusion modelled**. A "patchy"
object returns depth only in square tiles 10–14 mm wide separated by
unscanned strips 7–10 mm wide, so its surface never forms an
object-sized component at strict connectivity. A "patchy pair" is two
such objects 8–18 mm apart.

- **Full pipeline**: The app's default configuration.
- **Default reach + free space**: Free-space check at the app's 2-voxel reach.
- **Wide reach**: Fragments are bridged across up to 5 voxels (15 mm) instead of 2. No free-space check.
- **Wide reach + free space**: The same reach, but a gap that depth rays were seen passing through is not bridged.

### Dense object alone (control) (synthetic)

| Variant | Correct | Oversized offered | Undersized offered | Refused | of which the refused estimate was oversized | Offered containing neighbour voxels |
|---|---:|---:|---:|---:|---:|---:|
| Full pipeline | 6 of 6 | 0 | 0 | 0 | 0 | n/a |
| Default reach + free space | 6 of 6 | 0 | 0 | 0 | 0 | n/a |
| Wide reach | 6 of 6 | 0 | 0 | 0 | 0 | n/a |
| Wide reach + free space | 6 of 6 | 0 | 0 | 0 | 0 | n/a |

### Dense object with a dense neighbour 8–18 mm away (control) (synthetic)

| Variant | Correct | Oversized offered | Undersized offered | Refused | of which the refused estimate was oversized | Offered containing neighbour voxels |
|---|---:|---:|---:|---:|---:|---:|
| Full pipeline | 6 of 6 | 0 | 0 | 0 | 0 | 0 |
| Default reach + free space | 6 of 6 | 0 | 0 | 0 | 0 | 0 |
| Wide reach | 6 of 6 | 0 | 0 | 0 | 0 | 0 |
| Wide reach + free space | 6 of 6 | 0 | 0 | 0 | 0 | 0 |

### Patchy object alone (synthetic)

| Variant | Correct | Oversized offered | Undersized offered | Refused | of which the refused estimate was oversized | Offered containing neighbour voxels |
|---|---:|---:|---:|---:|---:|---:|
| Full pipeline | 0 of 10 | 0 | 0 | 10 | 0 | n/a |
| Default reach + free space | 0 of 10 | 0 | 0 | 10 | 0 | n/a |
| Wide reach | 9 of 10 | 0 | 0 | 1 | 0 | n/a |
| Wide reach + free space | 9 of 10 | 0 | 0 | 1 | 0 | n/a |

### Two patchy objects 8–18 mm apart (synthetic)

| Variant | Correct | Oversized offered | Undersized offered | Refused | of which the refused estimate was oversized | Offered containing neighbour voxels |
|---|---:|---:|---:|---:|---:|---:|
| Full pipeline | 0 of 14 | 0 | 0 | 14 | 1 | 0 |
| Default reach + free space | 0 of 14 | 0 | 0 | 14 | 1 | 0 |
| Wide reach | 0 of 14 | 0 | 0 | 14 | 14 | 0 |
| Wide reach + free space | 12 of 14 | 0 | 0 | 2 | 2 | 0 |

What this does and does not show:

- It shows the designed behaviour on a constructed surface: a wider
  reach recovers a patchy object, and free-space evidence stops that
  reach from joining two such objects across a gap rays passed through.
- "Containing neighbour voxels" uses the generator's own knowledge of
  which object each selected voxel lies on (more than
  2% on the second object), so a result can
  be seen to be the target alone and not merely target-sized.
- The construction favours the mechanism. The missing strips are
  regular; the solid still hides everything behind it perfectly; rays
  come from dense surface samples, not a camera's pixel grid; noise is
  small and independent, with no mixed pixels at silhouettes, no
  depth-map smoothing and no pose error. One generator, one seed.
- It does not show that real products fragment this way, that an
  iPhone's depth map resolves gaps of this size, or that grazing rays
  at real silhouettes do not block bridges that should be made.
  Recorded device scans are needed for each of those.

### Per-case results, part 2 (synthetic)

| Case | True L × W × H (cm) | Full pipeline | Default reach + free space | Wide reach | Wide reach + free space |
|---|---|---|---|---|---|
| dense-0 | 6.6 × 5.1 × 4.7 | 7.0 × 5.5 × 5.0 accepted | 7.0 × 5.5 × 5.0 accepted | 7.0 × 5.5 × 5.0 accepted | 7.0 × 5.5 × 5.0 accepted |
| dense-1 | 8.6 × 7.4 × 5.9 | 9.1 × 7.8 × 6.2 accepted | 9.1 × 7.8 × 6.2 accepted | 9.1 × 7.8 × 6.2 accepted | 9.1 × 7.8 × 6.2 accepted |
| dense-2 | 9.3 × 7.2 × 9.1 | 9.7 × 7.6 × 9.3 accepted | 9.7 × 7.6 × 9.3 accepted | 9.7 × 7.6 × 9.3 accepted | 9.7 × 7.6 × 9.3 accepted |
| dense-3 | 10.2 × 7.8 × 4.0 | 10.6 × 8.3 × 4.2 accepted | 10.6 × 8.3 × 4.2 accepted | 10.6 × 8.3 × 4.2 accepted | 10.6 × 8.3 × 4.2 accepted |
| dense-4 | 9.5 × 6.8 × 8.3 | 9.9 × 7.3 × 8.6 accepted | 9.9 × 7.3 × 8.6 accepted | 9.9 × 7.3 × 8.6 accepted | 9.9 × 7.3 × 8.6 accepted |
| dense-5 | 10.1 × 4.8 × 8.4 | 10.5 × 5.3 × 8.6 accepted | 10.5 × 5.3 × 8.6 accepted | 10.5 × 5.3 × 8.6 accepted | 10.5 × 5.3 × 8.6 accepted |
| dense-neighbour-0-gap11mm | 9.9 × 5.1 × 5.4 | 10.3 × 5.6 × 5.6 qualified | 10.3 × 5.6 × 5.6 qualified | 10.3 × 5.6 × 5.6 qualified | 10.3 × 5.6 × 5.6 qualified |
| dense-neighbour-1-gap15mm | 8.3 × 7.4 × 7.3 | 8.7 × 7.9 × 7.5 qualified | 8.7 × 7.9 × 7.5 qualified | 8.7 × 7.9 × 7.5 qualified | 8.7 × 7.9 × 7.5 qualified |
| dense-neighbour-2-gap17mm | 7.9 × 4.9 × 4.4 | 8.3 × 5.4 × 4.6 accepted | 8.3 × 5.4 × 4.6 accepted | 8.3 × 5.4 × 4.6 accepted | 8.3 × 5.4 × 4.6 accepted |
| dense-neighbour-3-gap15mm | 10.2 × 8.4 × 9.5 | 10.6 × 8.9 × 9.8 qualified | 10.6 × 8.9 × 9.8 qualified | 10.6 × 8.9 × 9.8 qualified | 10.6 × 8.9 × 9.8 qualified |
| dense-neighbour-4-gap13mm | 7.6 × 6.4 × 9.4 | 8.0 × 6.9 × 9.6 qualified | 8.0 × 6.9 × 9.6 qualified | 8.0 × 6.9 × 9.6 qualified | 8.0 × 6.9 × 9.6 qualified |
| dense-neighbour-5-gap15mm | 7.8 × 7.6 × 8.1 | 8.2 × 8.1 × 8.3 qualified | 8.2 × 8.1 × 8.3 qualified | 8.2 × 8.1 × 8.3 qualified | 8.2 × 8.1 × 8.3 qualified |
| patchy-0 | 9.2 × 6.6 × 4.5 | — refused | — refused | 9.6 × 7.0 × 4.7 qualified | 9.6 × 7.0 × 4.7 qualified |
| patchy-1 | 10.5 × 7.8 × 10.5 | 2.0 × 1.1 × 7.2 refused | — refused | 10.9 × 8.2 × 10.7 qualified | 10.9 × 8.2 × 10.7 qualified |
| patchy-2 | 10.1 × 5.4 × 9.4 | — refused | — refused | 10.5 × 5.9 × 9.6 qualified | 10.5 × 5.9 × 9.6 qualified |
| patchy-3 | 8.1 × 4.7 × 10.5 | — refused | — refused | 8.5 × 5.1 × 10.7 refused | 8.5 × 5.1 × 10.7 refused |
| patchy-4 | 8.0 × 6.6 × 8.7 | — refused | — refused | 8.4 × 7.1 × 8.9 qualified | 8.4 × 7.1 × 8.9 qualified |
| patchy-5 | 6.3 × 5.1 × 10.7 | 4.3 × 1.4 × 5.4 refused | 4.3 × 1.4 × 5.4 refused | 6.8 × 5.5 × 11.0 qualified | 6.8 × 5.5 × 11.0 qualified |
| patchy-6 | 10.9 × 4.4 × 4.5 | 3.8 × 3.4 × 4.7 refused | — refused | 11.3 × 4.9 × 4.7 qualified | 11.3 × 4.9 × 4.7 qualified |
| patchy-7 | 9.5 × 4.2 × 10.4 | 4.2 × 1.3 × 5.4 refused | — refused | 9.9 × 4.6 × 10.7 qualified | 9.9 × 4.6 × 10.7 qualified |
| patchy-8 | 10.8 × 8.4 × 9.9 | 3.2 × 0.5 × 6.9 refused | — refused | 11.2 × 8.9 × 10.1 qualified | 11.2 × 8.9 × 10.1 qualified |
| patchy-9 | 8.6 × 8.0 × 4.2 | — refused | — refused | 9.0 × 8.4 × 4.4 qualified | 9.0 × 8.4 × 4.4 qualified |
| patchy-pair-0-gap17mm | 8.1 × 7.3 × 5.7 | 3.3 × 1.2 × 5.9 refused | 6.0 × 3.4 × 5.9 refused | 15.4 × 8.5 × 5.9 refused | 8.5 × 7.8 × 5.9 qualified |
| patchy-pair-1-gap12mm | 8.5 × 7.0 × 4.1 | 3.4 × 3.4 × 4.4 refused | 3.4 × 3.3 × 4.4 refused | 15.1 × 7.4 × 10.1 refused | 8.9 × 7.4 × 4.4 qualified |
| patchy-pair-2-gap16mm | 10.8 × 6.5 × 6.2 | 4.7 × 3.3 × 6.5 refused | 4.7 × 3.3 × 6.5 refused | 17.5 × 6.9 × 6.8 refused | 11.2 × 7.0 × 6.5 qualified |
| patchy-pair-3-gap8mm | 11.8 × 6.2 × 9.6 | 2.0 × 0.8 × 6.3 refused | 2.0 × 0.8 × 6.3 refused | 20.0 × 7.3 × 10.4 refused | 20.0 × 7.3 × 10.4 refused |
| patchy-pair-4-gap11mm | 7.2 × 6.4 × 8.3 | — refused | — refused | 16.0 × 9.0 × 8.6 refused | 7.6 × 6.8 × 8.5 qualified |
| patchy-pair-5-gap16mm | 8.1 × 5.6 × 5.3 | 1.7 × 1.0 × 6.5 refused | 1.7 × 1.0 × 6.5 refused | 17.2 × 9.3 × 6.5 refused | 8.5 × 6.1 × 5.6 qualified |
| patchy-pair-6-gap13mm | 10.2 × 4.4 × 11.0 | 2.3 × 1.1 × 5.4 refused | 2.3 × 1.1 × 5.4 refused | 16.4 × 9.3 × 11.1 refused | 10.7 × 4.9 × 11.1 qualified |
| patchy-pair-7-gap11mm | 12.0 × 7.4 × 6.6 | 6.0 × 5.3 × 6.9 refused | 6.0 × 5.3 × 6.9 refused | 21.1 × 7.7 × 9.2 refused | 21.1 × 7.7 × 9.2 refused |
| patchy-pair-8-gap13mm | 7.0 × 6.1 × 5.6 | — refused | — refused | 14.9 × 8.2 × 7.7 refused | 7.4 × 6.6 × 5.9 qualified |
| patchy-pair-9-gap16mm | 10.5 × 8.5 × 9.0 | 2.2 × 1.1 × 9.2 refused | — refused | 20.1 × 8.9 × 9.2 refused | 11.0 × 8.9 × 9.2 qualified |
| patchy-pair-10-gap14mm | 9.9 × 5.7 × 5.0 | 3.1 × 1.5 × 5.3 refused | 3.1 × 1.5 × 5.3 refused | 16.1 × 8.0 × 6.5 refused | 10.3 × 6.2 × 5.3 qualified |
| patchy-pair-11-gap9mm | 8.5 × 5.4 × 4.7 | 2.9 × 2.2 × 5.7 refused | — refused | 14.2 × 8.1 × 5.7 refused | 8.9 × 5.9 × 5.0 qualified |
| patchy-pair-12-gap15mm | 8.3 × 4.3 × 4.4 | — refused | — refused | 15.1 × 7.6 × 7.4 refused | 8.7 × 4.8 × 4.7 qualified |
| patchy-pair-13-gap13mm | 8.9 × 8.0 × 6.9 | 3.4 × 1.9 × 7.1 refused | — refused | 16.4 × 9.2 × 7.1 refused | 9.3 × 8.5 × 7.1 qualified |
