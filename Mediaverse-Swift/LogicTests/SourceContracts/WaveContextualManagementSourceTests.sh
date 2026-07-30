#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
legacy_management="$root/Social/Vibes/VibeManagementViews.swift"

require() {
  grep -Fq -- "$1" "$2" || { echo "FAIL: $3" >&2; exit 1; }
}

require 'permissions.mayCreateWave' "$view" \
  "Wave creation must use Matrix power-level permission."
require 'Label("Create Wave", systemImage: "plus.bubble")' "$view" \
  "Wave creation must live in the Vibe directory."
require 'MatrixNativeRoomCreatorView(mode: .wave(parentSpaceID: space.id))' "$view" \
  "Wave creation must preserve Matrix parent identity."
require 'Image(systemName: "gearshape")' "$view" \
  "Wave settings must live inside the selected Wave."
require 'MatrixNativeWaveRulesView(room: room)' "$view" \
  "Wave settings must operate on the selected Matrix room."
require 'powerLevels.canOwnUserSendState' "$repository" \
  "Wave settings must be authorized by Matrix power levels."
require 'sendStateEventRaw(' "$repository" \
  "Structured rules must be stored as canonical Matrix room state."

if grep -Fq 'struct VibeWavesManagementView' "$legacy_management"; then
  echo "FAIL: Standalone legacy Wave management must remain retired." >&2
  exit 1
fi
if grep -Eq 'LegacySocialAPIAdapter|/api/fan-clubs' "$view"; then
  echo "FAIL: Matrix Wave management crossed the retired social authority." >&2
  exit 1
fi

echo "Matrix-native contextual Wave management source contracts passed."
