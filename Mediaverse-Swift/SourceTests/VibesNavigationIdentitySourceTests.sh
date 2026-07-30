#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
vibes="$root/Social/Vibes/MatrixNativeVibesViews.swift"
direct="$root/Social/Vibes/MatrixNativeDirectNotificationViews.swift"
profile="$root/Views/Profile/ProfileView.swift"

grep -q 'case waves' "$vibes"
grep -q 'case personalWaves' "$vibes"
grep -q 'case explore' "$vibes"
grep -q 'case \.personalWaves:' "$vibes"
grep -q 'MatrixNativeDirectMessagesView()' "$vibes"
grep -q 'case \.explore:' "$vibes"
grep -q 'MatrixNativePublicVibeDirectoryView' "$vibes"
grep -q 'navigationTitle("Personal Waves")' "$direct"
grep -q 'case vibesSecurity' "$profile"
grep -q 'MatrixNativeCryptoSecurityView()' "$profile"
grep -q 'title: "Vibes Security"' "$profile"

if grep -q 'Text(member.userID)' "$vibes"; then
  echo "Raw Matrix member IDs must not be rendered in member-facing Swift UI" >&2
  exit 1
fi

echo "Vibes navigation and identity source contracts passed"
