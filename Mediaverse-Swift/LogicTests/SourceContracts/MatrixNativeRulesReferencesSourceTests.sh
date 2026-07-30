#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
REPOSITORY="$ROOT/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
VIEWS="$ROOT/Social/Vibes/MatrixNativeVibesViews.swift"
CONTRACT="$ROOT/Social/Contracts/MatrixNativeVibesUIContract.swift"
SESSION="$ROOT/Services/MatrixSessionCoordinator.swift"
API="$ROOT/Services/APIClient.swift"
SHARE="$ROOT/Social/Ripples/EchoVibeSheet.swift"
INCOMING="$ROOT/Social/Ripples/IncomingShareSheet.swift"
EVENTS="$ROOT/Social/Events/VibeEventsViews.swift"

grep -q 'com.westreem.room.rules.v1' "$CONTRACT"
grep -q 'com.westreem.event_ref.v1' "$CONTRACT"
grep -q 'com.westreem.share.v1' "$CONTRACT"
grep -q 'canOwnUserSendState' "$REPOSITORY"
grep -q 'sendStateEventRaw' "$REPOSITORY"
grep -q 'MatrixNativeWaveRulesView' "$VIEWS"
grep -q 'MatrixNativeWestreemReferenceCard' "$VIEWS"
grep -q '/api/matrix/share/resolve' "$API"
grep -q 'resolveMatrixShare' "$API"
grep -q 'sendWestreemReference' "$SESSION"
grep -q 'MatrixNativeWestreemShareEntityType' "$SHARE"
grep -q 'content: .event' "$EVENTS"
grep -q 'typedWestreemShare' "$INCOMING"
grep -q 'matrixSession.sendWestreemReference' "$SHARE"

if grep -Eq 'LegacySocialAPIAdapter|/api/fan-clubs|/api/fan-club-posts' "$SHARE" "$INCOMING"; then
  echo "Native Vibes sharing must not write through the legacy social API." >&2
  exit 1
fi

# Match executable transport construction/use, not the explicit architectural
# comment that prohibits it. URLRequest is included because a handwritten
# Matrix client could otherwise hide behind URLSession injected elsewhere.
if grep -Eq 'URLSession[[:space:]]*[(]|URLSession[.]shared|URLRequest[[:space:]]*[(]' "$REPOSITORY"; then
  echo "Matrix-native rules and references must use MatrixRustSDK, not URLSession." >&2
  exit 1
fi

echo "Matrix-native Wave rules and typed reference source contracts passed."
