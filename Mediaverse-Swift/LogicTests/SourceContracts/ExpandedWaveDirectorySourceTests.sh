#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
routes="$root/Navigation/AppRoute.swift"

require() {
  grep -Fq -- "$1" "$2" || { echo "FAIL: $3" >&2; exit 1; }
}

require 'private struct MatrixNativeVibeView: View' "$view" \
  "A Vibe must open as a Matrix-native Wave directory."
require 'MatrixNativeSectionLabel(title: "Waves", count: rooms.count)' "$view" \
  "The complete accessible Wave directory must remain visible."
require 'MatrixNativeWaveRow(room: room)' "$view" \
  "Vibe Waves must share one information-rich Matrix-native row."
require 'if room.isNestedSpace' "$view" \
  "Nested Matrix Spaces must remain navigable."
require 'MatrixNativeNestedSpaceView(room: room)' "$view" \
  "Nested Matrix organization must have a native destination."
require 'MatrixNativeWaveRoomView(room: room)' "$view" \
  "Wave selection must open one dedicated Matrix room timeline."
require 'permissions.mayCreateWave' "$view" \
  "Wave creation must remain power-level gated."
require 'MatrixNativeRoomCreatorView(mode: .wave(parentSpaceID: space.id))' "$view" \
  "Wave creation must preserve the parent Matrix Space."
require 'MatrixNativeRichComposer(' "$view" \
  "A dedicated Wave must retain the Matrix-native rich composer."
require '.safeAreaInset(edge: .bottom, spacing: 0)' "$view" \
  "The composer must remain available while reading the room timeline."
require 'client.spaceService().spaceRoomList(spaceId: spaceID)' "$repository" \
  "The Wave directory must come from Matrix Space hierarchy."
require 'eventType: "m.space.child"' "$repository" \
  "New Waves must be linked with canonical Matrix Space state."
require 'eventType: "m.space.parent"' "$repository" \
  "New Waves must retain their canonical parent relation."
require 'case vibeWave' "$routes" \
  "Native routing must preserve Vibe and Wave identity."

if grep -Eq 'LegacySocialAPIAdapter|/api/fan-clubs|/api/fan-club-posts' "$view"; then
  echo "FAIL: Matrix-native directory crossed the retired social authority." >&2
  exit 1
fi

echo "Expanded Matrix-native Wave directory source contracts passed."
