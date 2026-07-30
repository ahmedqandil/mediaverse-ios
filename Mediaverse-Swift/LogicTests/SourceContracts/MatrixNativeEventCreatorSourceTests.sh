#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
models="$root/Social/Events/VibeEventModels.swift"
views="$root/Social/Events/VibeEventsViews.swift"
vibes="$root/Social/Vibes/MatrixNativeVibesViews.swift"
api="$root/Services/APIClient.swift"

for required in \
  'let matrixSpaceId: String' \
  'let matrixRoomId: String' \
  'let clientRequestId: String'; do
  grep -q "$required" "$models" || {
    echo "Matrix-owned Event request is missing: $required" >&2
    exit 1
  }
done

for required in \
  '@EnvironmentObject private var matrixSession: MatrixNativeSessionController' \
  'matrixSession.vibes()' \
  'matrixSession.waves(spaceID: selectedVibeID)' \
  'preselectedMatrixSpaceID' \
  'preselectedMatrixRoomID' \
  'editEvent?.matrixReference?.matrixSpaceId' \
  'editEvent?.matrixReference?.matrixRoomId' \
  'requestVibeEventCoverUpload'; do
  grep -Fq "$required" "$views" || {
    echo "Matrix-native Event creator is missing: $required" >&2
    exit 1
  }
done

grep -q 'Label("Create Event", systemImage: "calendar.badge.plus")' "$vibes"
grep -q '"/api/vibe-events/media/upload-url"' "$api"

if grep -Eq 'fetchManagedCommunityVibes|requestFanClub(Profile|Photo)Upload' "$views" "$api"; then
  echo "Matrix-native Event creation must not use retired Vibe discovery or Fan Club uploads." >&2
  exit 1
fi

request_block="$(
  sed -n '/struct CreateVibeEventRequest:/,/^}/p' "$models"
)"
if printf '%s\n' "$request_block" | grep -Eq 'clubId|waveId'; then
  echo "Matrix-native Event request must not send legacy clubId or waveId authority." >&2
  exit 1
fi

echo "Matrix-native Event creator source contract passed"
