#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
tabs="$root/Views/MainTabView.swift"
atmo="$root/Social/Atmosphere/AtmoProfileViews.swift"

require() {
  grep -Fq -- "$1" "$2" || { echo "FAIL: $3" >&2; exit 1; }
}

require 'struct MatrixNativeVibesRootView: View' "$view" \
  "Vibes must enter through the Matrix-native directory."
require 'MatrixNativeVibeView(space: space)' "$view" \
  "A Matrix Space must be the canonical Vibe destination."
require 'rooms = try await matrixSession.waves(spaceID: space.id).rooms' "$view" \
  "Wave membership and hierarchy must be loaded from Matrix."
require 'MatrixNativeWaveRoomView(room: room)' "$view" \
  "A Wave must open as a dedicated Matrix room."
require 'MatrixNativeRichComposer(' "$view" \
  "Dedicated Waves must use the Matrix-native composer."
require 'MatrixNativeMessageRow(' "$view" \
  "Dedicated Waves must render Matrix timeline events."
require 'permissions = try await matrixSession.spacePermissions(spaceID: space.id)' "$view" \
  "Vibe management must use Matrix power levels."
require 'if permissions.mayOpenVibeManagement' "$view" \
  "Every joined Vibe member must be able to reach member-level Vibe actions."
require 'func childRooms(spaceID: String)' "$repository" \
  "Wave directories must come from the Matrix SDK repository."
require 'matrixNativeVibesEnabled' "$tabs" \
  "The app must retain a controlled Matrix-native rollout boundary."
require 'struct AtmoProfileView: View' "$atmo" \
  "Personal Atmo must remain an independent Westreem-owned surface."

if grep -Eq 'LegacySocialAPIAdapter|RippleCard[(]|/api/fan-clubs|/api/fan-club-posts' "$view"; then
  echo "FAIL: Matrix-native Vibes must not render or mutate legacy social Ripples." >&2
  exit 1
fi

echo "Matrix-native Vibe and Wave directory source contracts passed."
