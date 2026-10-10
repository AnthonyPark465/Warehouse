# Synthetic placement evaluation

> **SYNTHETIC RESULTS.** Every number below comes from generated receive and
> pick sequences (`WarehouseAppTests/PlacementEvaluation.swift`) replayed
> through the placement engine. They show how area-selection policies
> compare on that generator. They are **not** measurements of a real stock
> room and must not be quoted as such.

Regenerate with `./scripts/evaluate-placement.sh`. Generator seed `20261009`, 12 sequences of 160 events, 4 storage areas, 8 product sizes. Built from commit 62fe8e1 plus uncommitted changes with swift-driver version: 1.120.5 Apple Swift version 6.1 (swiftlang-6.1.0.110.21 clang-1700.0.13.3).

## How to read this (synthetic)

- Every policy replays the **same** event sequences against the same empty warehouse.
- Each policy only chooses the **area**; the position inside it is the single-area engine's own recommendation. The one exception is **Experiment: deepest position**, which also overrides the position. Every position used, by any policy, passed all of the engine's safety rules.
- **Failed receives**: no area accepted the product. Lower is better.
- **Fewer / more failures**: in how many sequences the policy had fewer, or more, failed receives than the first baseline on the same events. A lead that does not hold across most sequences is noise.
- **Receives before first failure**: how long the warehouse absorbs stock before the first refusal. Higher is better.
- **Unserved picks**: the product was asked for but none was stored. This includes picks that arrive before any receive, so compare policies rather than reading the level.
- **Moves per pick**: products standing directly in front of the picked one in the same lane. Lower is better. This is optimistic for any policy that blocks: the blockers are assumed to be set aside and put back for free, so staging space, blockers of blockers, and the moves to restore them are not counted.
- **Peak floor coverage**: largest share of all floor area under stored products (raw product footprint). Nothing in this catalogue may be stacked.
- The moves metric uses the engine's front-access rule, which is pessimistic for open floor areas reachable from above.
- The workload is invented, and the shipped policy's order was chosen with these results in view. These are in-family results, not held-out performance.

## Policies

- **First listed**: Baseline. The first area in the app's list that accepts the product, as a worker picking from the top of the menu would.
- **Emptiest area**: Baseline. The accepting area with the most free volume: "put it where there is room".
- **Position rank only**: The single-area ranking compared directly between areas, with no cross-area rule.
- **App cross-area search**: `PlacementEngine.calculate(package:shelves:)`, the app's cross-area search: fewest products to move, then the area with the least free room that still accepts the product.
- **Experiment: deepest position**: **Not in the app.** Tightest-fit area, but the product is pushed to the deepest position it can reach instead of the engine's front-most choice. Included to measure how much capacity the front-first ranking gives up, and what that costs in access.

## Results (synthetic, mean over 12 sequences)

| Policy | Failed receives | Fewer / more failures than First listed | Receives before first failure | Unserved picks | Moves per pick | Picks needing a move | Peak floor coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| First listed | 45.4% | 0 / 0 of 12 | 11.1 | 31.1% | 0.00 | 0.0% | 32.9% |
| Emptiest area | 45.8% | 5 / 5 of 12 | 11.7 | 32.0% | 0.00 | 0.0% | 32.1% |
| Position rank only | 46.1% | 3 / 6 of 12 | 11.2 | 32.3% | 0.00 | 0.0% | 32.2% |
| App cross-area search | 45.2% | 7 / 5 of 12 | 15.6 | 30.1% | 0.00 | 0.0% | 38.3% |
| Experiment: deepest position | 30.4% | 12 / 0 of 12 | 26.1 | 21.7% | 0.31 | 18.6% | 61.0% |

## Decision time (this machine, not an iPhone)

Wall-clock time for one policy decision, which includes calculating every area it considers. Not reproducible between runs.

| Policy | Mean (ms) | Slowest (ms) |
|---|---:|---:|
| First listed | 15.9 | 60.0 |
| Emptiest area | 20.2 | 68.5 |
| Position rank only | 19.8 | 65.3 |
| App cross-area search | 19.7 | 78.2 |
| Experiment: deepest position | 42.3 | 122.1 |
