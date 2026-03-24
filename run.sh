#!/bin/bash
#
# Build and run (equivalent to Cmd+R in Xcode)
#
# Usage: ./run.sh
#
set -euo pipefail

source "$(dirname "$0")/.project.env"

BUILD_DIR="/private/tmp/${SCHEME}Build"

pkill -x "$SCHEME" 2>/dev/null && sleep 0.5 || true

echo "==> Building..."
xcodebuild -project "$SCHEME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Debug \
    build \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

echo "==> Launching..."
open "$BUILD_DIR/$SCHEME.app"
