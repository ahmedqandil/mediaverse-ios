#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeWatchPartyView.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
api="$root/Services/APIClient.swift"

grep -q '/api/matrix/watch-party/lease?videoId=' "$api"
grep -q 'suspendPlaybackLease()' "$view"
grep -q 'resumePlaybackLease()' "$view"
grep -q 'state.lastUpdatedAt ?? state.startedAt' "$view"
grep -q 'abs(driftMs) > 5_000' "$view"
grep -q 'abs(driftMs) > 1_500' "$view"
grep -q 'Playback URLs are viewer-specific revocable WeStreem leases' "$repository"
if grep -q 'content\["videoUrl"\] = url' "$repository"; then
  echo "viewer playback URL leaked into Matrix state" >&2
  exit 1
fi

echo "Matrix Watch Party playback lease source contract passed"
