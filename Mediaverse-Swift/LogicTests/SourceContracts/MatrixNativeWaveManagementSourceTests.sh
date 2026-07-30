#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
REPOSITORY="$ROOT/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
COORDINATOR="$ROOT/Services/MatrixSessionCoordinator.swift"
VIEW="$ROOT/Social/Vibes/MatrixNativeVibesViews.swift"

require() {
  file="$1"
  pattern="$2"
  message="$3"
  if ! grep -Fq "$pattern" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

reject() {
  file="$1"
  pattern="$2"
  message="$3"
  if grep -Fq "$pattern" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require "$REPOSITORY" "func waveManagement(roomID: String)" "missing Matrix Wave settings contract"
require "$REPOSITORY" "matrixRoom.updateJoinRules" "access is not Matrix room state"
require "$REPOSITORY" "matrixRoom.updateHistoryVisibility" "history is not Matrix room state"
require "$REPOSITORY" "matrixRoom.updatePowerLevelsForUsers" "roles are not Matrix power levels"
require "$REPOSITORY" "matrixRoom.kickUser" "kick is not Matrix membership moderation"
require "$REPOSITORY" "matrixRoom.banUser" "ban is not Matrix membership moderation"
require "$REPOSITORY" "matrixRoom.unbanUser" "unban is not Matrix membership moderation"
require "$REPOSITORY" "setRoomNotificationMode" "notifications are not Matrix push rules"
require "$REPOSITORY" "client.searchService()" "Wave search is not SDK-owned"
require "$COORDINATOR" "validateRoomAccess(roomID: roomID)" "coordinator does not fail closed on room access"
require "$VIEW" "MatrixNativeWaveManagementView" "Wave management UI is missing"
require "$VIEW" "MatrixNativeWaveMembersView" "member and role UI is missing"
require "$VIEW" "MatrixNativeWaveSearchView" "Wave search UI is missing"
reject "$REPOSITORY" "/api/fan-clubs" "legacy Vibe API appeared in Matrix repository"
reject "$REPOSITORY" "URLSession.shared" "handwritten Matrix transport appeared in repository"

echo "Matrix-native Wave management source contracts passed."
