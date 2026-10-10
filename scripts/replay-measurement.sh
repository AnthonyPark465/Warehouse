#!/bin/bash
# Replays scans recorded on a phone through the measurement pipeline, once per
# variant, and compares them with hand-measured dimensions. Compiles the
# pipeline sources into a macOS command-line tool; no device is needed.
#
# Usage: scripts/replay-measurement.sh <recordings-folder> [ground-truth.csv] [output.md]
# Defaults: ground truth <recordings-folder>/ground-truth.csv when it exists,
#           output docs/measurement-replay-device.md
set -euo pipefail
if [ $# -lt 1 ]; then
  echo "Usage: scripts/replay-measurement.sh <recordings-folder> [ground-truth.csv] [output.md]" >&2
  exit 2
fi
RECORDINGS="$(cd "$1" && pwd)"
TRUTH="${2:-}"
if [ -z "$TRUTH" ] && [ -f "$RECORDINGS/ground-truth.csv" ]; then
  TRUTH="$RECORDINGS/ground-truth.csv"
fi
if [ -n "$TRUTH" ]; then
  TRUTH="$(cd "$(dirname "$TRUTH")" && pwd)/$(basename "$TRUTH")"
fi
cd "$(dirname "$0")/.."
OUT="${3:-docs/measurement-replay-device.md}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O \
  WarehouseApp/Services/LiDAR*.swift \
  WarehouseApp/Models/ProductObjectScan.swift \
  WarehouseApp/Models/ManualARMeasurement.swift \
  WarehouseAppTests/SyntheticScanFixtures.swift \
  WarehouseAppTests/MeasurementEvaluation.swift \
  WarehouseAppTests/MeasurementAblation.swift \
  WarehouseAppTests/MeasurementReplay.swift \
  Tools/MeasurementReplay/main.swift \
  -o "$BUILD/replay-measurement"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain -- WarehouseApp WarehouseAppTests Tools 2>/dev/null)" ]; then
  COMMIT="$COMMIT plus uncommitted changes"
fi
"$BUILD/replay-measurement" "$RECORDINGS" "$TRUTH" "$OUT" "commit $COMMIT"
