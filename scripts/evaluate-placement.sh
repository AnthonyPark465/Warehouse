#!/bin/bash
# Runs the SYNTHETIC placement evaluation: generated receive/pick sequences
# replayed through the placement engine under several area-selection
# policies. Compiles the engine sources into a macOS command-line tool, so no
# simulator or device is needed.
#
# Usage: scripts/evaluate-placement.sh [output.md] [generator-seed]
# Default output: docs/placement-evaluation-synthetic.md
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-docs/placement-evaluation-synthetic.md}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
# The engine's models reach most of the pure-Swift model and support code, so
# compile every source that does not need an iOS framework.
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(
  grep -L -E "^import (Firebase[A-Za-z]*|UIKit|ARKit|SwiftUI|RealityKit|AVFoundation|SceneKit)" \
    WarehouseApp/Models/*.swift WarehouseApp/Support/*.swift WarehouseApp/Services/LiDAR*.swift
)
swiftc -O "${SOURCES[@]}" \
  WarehouseAppTests/PlacementEvaluation.swift \
  Tools/PlacementEvaluation/main.swift \
  -o "$BUILD/evaluate-placement"
# Recorded in the report so its numbers can be tied to a source state.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain -- WarehouseApp WarehouseAppTests Tools 2>/dev/null)" ]; then
  COMMIT="$COMMIT plus uncommitted changes"
fi
TOOLCHAIN="$(swiftc --version 2>&1 | head -1)"
"$BUILD/evaluate-placement" "$OUT" "${2:-20261009}" "commit $COMMIT with $TOOLCHAIN"
