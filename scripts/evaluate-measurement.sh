#!/bin/bash
# Runs the SYNTHETIC measurement evaluation: the app's pipeline against a
# simple baseline on generated scans. Compiles the pipeline sources into a
# macOS command-line tool, so no simulator or device is needed.
#
# Usage: scripts/evaluate-measurement.sh [output.md] [generator-seed]
# Default output: docs/measurement-evaluation-synthetic.md
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-docs/measurement-evaluation-synthetic.md}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O \
  WarehouseApp/Services/LiDAR*.swift \
  WarehouseApp/Models/ProductObjectScan.swift \
  WarehouseApp/Models/ManualARMeasurement.swift \
  WarehouseAppTests/SyntheticScanFixtures.swift \
  WarehouseAppTests/MeasurementEvaluation.swift \
  Tools/MeasurementEvaluation/main.swift \
  -o "$BUILD/evaluate-measurement"
# Recorded in the report so its numbers can be tied to a source state.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain -- WarehouseApp WarehouseAppTests Tools 2>/dev/null)" ]; then
  COMMIT="$COMMIT plus uncommitted changes"
fi
TOOLCHAIN="$(swiftc --version 2>&1 | head -1)"
"$BUILD/evaluate-measurement" "$OUT" "${2:-20261009}" "commit $COMMIT with $TOOLCHAIN"
