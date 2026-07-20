#!/bin/bash
# Regenerate the Xcode project from project.yml.
# XcodeGen 2.46 emits objectVersion 77 (Xcode 16 format); downgrade to 56 so
# Xcode 15.4 can open it. Remove the sed once the Mac is on Xcode 16.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
sed -i '' 's/objectVersion = 77;/objectVersion = 56;/' Warehouse.xcodeproj/project.pbxproj
echo "Project regenerated (objectVersion 56)."
