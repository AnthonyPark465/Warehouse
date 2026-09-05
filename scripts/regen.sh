#!/bin/bash
# Regenerate the Xcode project from project.yml (requires: brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")/.."
# Per-machine overrides (signing team etc.) — see the comment in project.yml.
[ -f project.local.yml ] || printf '{}\n' > project.local.yml
xcodegen generate
echo "Project regenerated."
