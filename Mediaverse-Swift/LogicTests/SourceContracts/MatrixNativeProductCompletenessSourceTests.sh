#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
REPOSITORY="$ROOT/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
SESSION="$ROOT/Services/MatrixSessionCoordinator.swift"
VIEWS="$ROOT/Social/Vibes/MatrixNativeVibesViews.swift"
MEDIA="$ROOT/Social/Vibes/MatrixNativeMediaViews.swift"
API="$ROOT/Services/APIClient.swift"

require() {
  file="$1"
  pattern="$2"
  message="$3"
  if ! grep -Fq "$pattern" "$file"; then
    echo "FAIL: $message"
    exit 1
  fi
}

reject() {
  file="$1"
  pattern="$2"
  message="$3"
  if grep -Fq "$pattern" "$file"; then
    echo "FAIL: $message"
    exit 1
  fi
}

require "$REPOSITORY" "pinnedEventIds" "Pinned browser must read canonical Matrix pinned state"
require "$REPOSITORY" "getEventTimelineItemByEventId" "Pinned browser must resolve through MatrixRustSDK"
require "$REPOSITORY" "withMentions" "Message sends must carry standard Matrix mention metadata"
require "$REPOSITORY" "Mentions(" "Message sends must construct the SDK mention object"
require "$REPOSITORY" "waveMembers(roomID:" "Mention targets must be validated against Matrix room members"
require "$SESSION" "func pinnedMessages" "Session controller must expose pinned Matrix Ripples"
require "$MEDIA" "Wave member mention suggestions" "Room composer must expose accessible member suggestions"
require "$VIEWS" "Pinned Ripples" "Wave UI must expose a pinned Ripple browser"
require "$VIEWS" "Echo to My Atmo" "Explicit Matrix-to-Personal-Atmo sharing must remain available"
require "$VIEWS" "MatrixNativeVibeAffiliationsView" "Vibe UI must expose reviewed affiliations"
require "$VIEWS" "case \"PENDING\"" "Affiliation UI must represent pending status"
require "$VIEWS" "case \"APPROVED\"" "Affiliation UI must represent approved status"
require "$VIEWS" "\"REJECTED\", \"REVOKED\"" "Affiliation UI must represent negative terminal status"
require "$API" "/api/matrix/vibe-affiliations" "Swift must use the Matrix Space affiliation endpoint"
reject "$VIEWS" "/api/fan-clubs" "Matrix-native Vibe views must not use legacy Fan Club APIs"
reject "$REPOSITORY" "URLSession(" "Matrix repository must not become a handwritten Matrix client"

echo "Matrix native product completeness source contracts passed"
