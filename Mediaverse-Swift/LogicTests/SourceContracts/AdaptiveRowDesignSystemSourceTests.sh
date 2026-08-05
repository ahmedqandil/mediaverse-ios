#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CONSTANTS="$ROOT/Constants.swift"
VIBES="$ROOT/Social/Vibes/MatrixNativeVibesViews.swift"

grep -Fq 'private struct WestreemAdaptiveRowModifier: ViewModifier' "$CONSTANTS"
grep -Fq '.frame(minHeight: 56)' "$CONSTANTS"
grep -Fq 'WestreemTokens.Palette.actRow' "$CONSTANTS"
grep -Fq '.frame(width: 3)' "$CONSTANTS"
grep -Fq 'WestreemTokens.Palette.lineSoft' "$CONSTANTS"
grep -Fq 'MatrixNativeWaveRow(room: room)' "$VIBES"
grep -Fq 'HStack(spacing: 11)' "$VIBES"
grep -Fq '.font(.system(size: 13, weight:' "$VIBES"
grep -Fq 'Text("LIVE · \(room.activeCallParticipantCount)")' "$VIBES"
grep -Fq '.frame(minWidth: 18, minHeight: 18)' "$VIBES"
grep -Fq '.westreemAdaptiveRow(isLive: room.activeCallParticipantCount > 0)' "$VIBES"

echo "Adaptive row Design System source contract passed"
