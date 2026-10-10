#!/bin/bash
# Runs the SYNTHETIC ablation: the measurement pipeline with one mechanism
# switched off or on at a time, on generated scans. Compiles the pipeline
# sources into a macOS command-line tool, so no simulator or device is needed.
#
# Usage: scripts/evaluate-ablation.sh [output.md]
# Default output: docs/measurement-ablation-synthetic.md
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-docs/measurement-ablation-synthetic.md}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O \
  WarehouseApp/Services/LiDAR*.swift \
  WarehouseApp/Models/ProductObjectScan.swift \
  WarehouseApp/Models/ManualARMeasurement.swift \
  WarehouseAppTests/SyntheticScanFixtures.swift \
  WarehouseAppTests/MeasurementEvaluation.swift \
  WarehouseAppTests/MeasurementAblation.swift \
  Tools/MeasurementAblation/main.swift \
  -o "$BUILD/evaluate-ablation"
# Recorded in the report so its numbers can be tied to a source state.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain -- WarehouseApp WarehouseAppTests Tools 2>/dev/null)" ]; then
  COMMIT="$COMMIT plus uncommitted changes"
fi
TOOLCHAIN="$(swiftc --version 2>&1 | head -1)"
"$BUILD/evaluate-ablation" "$OUT" "commit $COMMIT with $TOOLCHAIN"
