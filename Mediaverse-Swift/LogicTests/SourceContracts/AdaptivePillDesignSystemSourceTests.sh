#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CONSTANTS="$ROOT/Constants.swift"
VIBES="$ROOT/Social/Vibes/MatrixNativeVibesViews.swift"

grep -Fq 'struct WestreemPillButtonStyle: ButtonStyle' "$CONSTANTS"
grep -Fq 'case primary' "$CONSTANTS"
grep -Fq 'case secondary' "$CONSTANTS"
grep -Fq 'case danger' "$CONSTANTS"
grep -Fq 'case schedule' "$CONSTANTS"
grep -Fq 'WestreemTokens.Palette.greenOn' "$CONSTANTS"
grep -Fq 'WestreemTokens.Palette.surfaceRaisedEnd' "$CONSTANTS"
grep -Fq 'Color(hex: "#5A1E3A")' "$CONSTANTS"
grep -Fq 'Color(hex: "#453072")' "$CONSTANTS"
grep -Fq 'return .system(size: 8, weight: .bold, design: .monospaced)' "$CONSTANTS"
grep -Fq '.frame(height: density == .compact ? 24 : nil)' "$CONSTANTS"
grep -Fq 'HStack(spacing: 5)' "$VIBES"
grep -Fq 'WestreemPillButtonStyle(' "$VIBES"
grep -Fq 'tone: selectedFilter == filter ? .primary : .secondary' "$VIBES"
grep -Fq 'density: .compact' "$VIBES"

echo "Adaptive pill Design System source contract passed"
