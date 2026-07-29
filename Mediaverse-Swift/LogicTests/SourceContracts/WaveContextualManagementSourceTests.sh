#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
view="$repo_dir/Social/Vibes/SocialDestinationViews.swift"
management="$repo_dir/Social/Vibes/VibeManagementViews.swift"

require() {
  grep -Fq -- "$1" "$2" || { echo "FAIL: $3"; exit 1; }
}
reject() {
  if grep -Fq -- "$1" "$2"; then echo "FAIL: $3"; exit 1; fi
}

require 'returnToWaveDirectory()' "$view" "Wave-local back must return to the directory."
require '.navigationBarBackButtonHidden(isCommunityConversation)' "$view" "Wave-local back must replace system back."
require 'detail.capabilities.canManageClub' "$view" "Wave creation must use server-owned capability."
require 'Label("New Wave", systemImage: "plus")' "$view" "Wave creation must live in the directory."
require 'wave.capabilities.canManage' "$view" "Wave settings must use Wave capability."
require 'editingWave = wave' "$view" "Settings must open from the selected Wave."
reject 'option("Waves"' "$view" "Vibe options must not expose legacy Wave management."
reject 'struct VibeWavesManagementView' "$management" "Standalone Wave management must remain retired."

echo "Swift contextual Wave management source contracts passed."
