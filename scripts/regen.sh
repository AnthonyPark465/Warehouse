#!/bin/bash
# Regenerate the Xcode project from project.yml (requires: brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
echo "Project regenerated."
