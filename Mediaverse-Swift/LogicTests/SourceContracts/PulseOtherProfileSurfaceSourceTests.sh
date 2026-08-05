#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
SOURCE="$ROOT/Social/Atmosphere/PulseOtherProfileSurface.swift"
PROJECT="$ROOT/Mediaverse.xcodeproj/project.pbxproj"

grep -Fq 'pulse-other-profile-25-b' "$SOURCE"
for value in Ripples Videos Shorts Vibes FOLLOWERS FOLLOWING ENERGY 'VIBES IN COMMON'; do
  grep -Fq "$value" "$SOURCE"
done
grep -Fq 'let carries: Int' "$SOURCE"
grep -Fq 'let sharedVibes: [SharedVibe]' "$SOURCE"
grep -Fq 'let canViewContent: Bool' "$SOURCE"
grep -Fq 'C.lightHaptic()' "$SOURCE"
grep -Fq 'PulseOtherProfileSurface.swift in Sources' "$PROJECT"

if grep -Eq 'URLSession|APIClient|MatrixSession|ActiveContext' "$SOURCE"; then
  echo 'Other-person Pulse presentation must consume server authority, not infer it' >&2
  exit 1
fi

echo 'Pulse other-profile Design System source contract passed'
