#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
SOURCE="$ROOT/Social/Atmosphere/PulsePostingIdentitySheet.swift"
PROJECT="$ROOT/Mediaverse.xcodeproj/project.pbxproj"

grep -Fq 'pulse-posting-identity-25-c' "$SOURCE"
grep -Fq 'Everything you do stays under the name you pick here.' "$SOURCE"
grep -Fq 'SWITCHING CHANGES WHO POSTS, NOT WHAT YOU SEE' "$SOURCE"
grep -Fq 'YOUR FEED, VIBES AND WAVES STAY YOURS' "$SOURCE"
grep -Fq 'case user = "USER"' "$SOURCE"
grep -Fq 'case channel = "CHANNEL"' "$SOURCE"
grep -Fq 'Create a channel' "$SOURCE"
grep -Fq 'WestreemTokens.Palette.greenSoft' "$SOURCE"
grep -Fq '.westreemAdaptiveSheet(detents: [.medium, .large])' "$SOURCE"
grep -Fq 'PulsePostingIdentitySheet.swift in Sources' "$PROJECT"

if grep -Eq 'ActiveContext|mv_active_ctx|requestMagicLink|URLSession|APIClient' "$SOURCE"; then
  echo 'Posting identity sheet must remain independent of workspace and network authority' >&2
  exit 1
fi

echo 'Pulse posting identity Design System source contract passed'
