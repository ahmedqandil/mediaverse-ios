#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
source_file="$root/Views/Profile/WestreemProfilePrivacySurface.swift"

test -f "$source_file"
grep -Fq 'westreem-profile-privacy-26-b' "$source_file"

for copy in \
  'Profile & privacy' \
  'YOU' \
  'Profile image' \
  'TAP TO CHANGE · POSITION AFTER PICKING' \
  'Banner' \
  '3:1 · POSITION AFTER PICKING' \
  'DISPLAY NAME' \
  'HANDLE' \
  'BIO' \
  'WHO CAN SEE YOU' \
  'Private account' \
  'People send a follow request. Accepting also adds them to Contacts.' \
  'Show when you are online' \
  'Your presence dot and “in a vibe” state.' \
  'Show your watch activity' \
  'Continue watching and what you have finished.' \
  'PUBLIC ACCOUNTS APPROVE FOLLOWS AND ADD CONTACTS IMMEDIATELY' \
  'TURNING PRIVATE ON DOES NOT REMOVE EXISTING FOLLOWERS'
do
  grep -Fq "$copy" "$source_file"
done

grep -Fq 'let onProfileImage: @MainActor () -> Void' "$source_file"
grep -Fq 'let onBanner: @MainActor () -> Void' "$source_file"
grep -Fq 'let onEditField: @MainActor (WestreemProfileField) -> Void' "$source_file"
grep -Fq 'let onToggle: @MainActor (WestreemPrivacyPreference, Bool) -> Void' "$source_file"
grep -Fq '.frame(width: 42, height: 25)' "$source_file"

if grep -Eq 'URLSession|APIClient|fetch\(' "$source_file"; then
  echo "Profile privacy surface must keep authority injected" >&2
  exit 1
fi

echo "WestreemProfilePrivacySurfaceSourceTests: PASS"
