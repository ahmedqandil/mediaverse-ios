#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
REPOSITORY="$ROOT/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
SESSION="$ROOT/Services/MatrixSessionCoordinator.swift"
VIEWS="$ROOT/Social/Vibes/MatrixNativeVibesViews.swift"
CONTRACT="$ROOT/Social/Contracts/MatrixNativeWaveActionsContract.swift"

grep -q 'timelineWithConfiguration' "$REPOSITORY"
grep -q 'focus: .thread(rootEventId:' "$REPOSITORY"
grep -q 'timeline.sendReply(msg:' "$REPOSITORY"
grep -q 'timeline.toggleReaction' "$REPOSITORY"
grep -q 'timeline.edit(' "$REPOSITORY"
grep -q 'timeline.redactEvent' "$REPOSITORY"
grep -q 'matrixRoom.reportContent' "$REPOSITORY"
grep -q 'timeline.pinEvent' "$REPOSITORY"
grep -q 'timeline.unpinEvent' "$REPOSITORY"
grep -q 'powerLevels.canOwnUser' "$REPOSITORY"
grep -q 'client.ignoredUsers()' "$REPOSITORY"
grep -q 'MatrixNativeThreadView' "$VIEWS"
grep -q 'Open discussion' "$VIEWS"
grep -q 'MatrixNativeEnergyPicker' "$VIEWS"
grep -q 'accessibilityLabel("More message actions")' "$VIEWS"
grep -q 'sendThreadReply' "$SESSION"
grep -q 'com.westreem.energy.v1:HITS' "$CONTRACT"
grep -q 'User strongest-model Matrix-native Vibes prompt (precedence 1)' "$CONTRACT"

if grep -Eq 'URLSession[(]|/_matrix/client|LegacySocialAPIAdapter|social(Post|Data)[(]' \
    "$REPOSITORY" "$SESSION" "$VIEWS"; then
  echo "Matrix Wave actions must use MatrixRustSDK without protocol or legacy adapters" >&2
  exit 1
fi

echo "Matrix-native Wave action source contract passed"
