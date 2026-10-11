#!/bin/bash
set -euo pipefail

# Compile the exact production compositor and shader code for an offscreen test.
# This also catches host-side Swift/Metal interface mismatches before iOS build.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/build/metal-verification"
mkdir -p "$VERIFY"
xcrun --sdk macosx metal -c "$ROOT/VRecord/Rendering/Shaders.metal" -o "$VERIFY/Shaders.air"
xcrun --sdk macosx metallib "$VERIFY/Shaders.air" -o "$VERIFY/default.metallib"
xcrun --sdk macosx swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -O \
  "$ROOT/VRecord/Tracking/HandLandmarks.swift" \
  "$ROOT/VRecord/Rendering/SkeletonRenderer.swift" \
  "$ROOT/VRecord/Rendering/MetalCompositor.swift" \
  "$ROOT/scripts/MetalVerification/main.swift" \
  -o "$VERIFY/verify-metal"
"$VERIFY/verify-metal" "$VERIFY/default.metallib"
