#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
api="$root/Services/APIClient.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
contract="$root/Social/Contracts/MatrixNativeVibesUIContract.swift"
plist="$root/Info.plist"

require() {
  file="$1"
  pattern="$2"
  message="$3"
  grep -Fq "$pattern" "$file" || {
    echo "$message" >&2
    exit 1
  }
}

require "$api" "/api/vibes/member-candidates" "Vibe invitations must use the bounded WeStreem member-candidate endpoint"
require "$api" "/api/vibes/contacts" "Explicit WeStreem Contacts API is missing"
require "$api" "/api/vibes/contact-matches" "Privacy-bounded phone-book matching is missing"
require "$api" "/api/vibes/invite-links" "Vibe invitation-link creation is missing"
require "$view" "Search active WeStreem accounts by name or handle." "The native invitation picker does not expose WeStreem user search"
require "$view" "Followers stay separate and are never added automatically." "Followers must not become implicit contacts or members"
require "$view" "Find people from Contacts" "Opt-in native Contacts discovery is missing"
require "$view" "one-way hashes for matching" "Contacts privacy disclosure is missing"
require "$view" "Share invitation link" "Native invitation sharing is missing"
require "$view" "MatrixNativeInviteUsersView(" "Native Vibe and Wave invitation destinations are missing"
require "$repository" "mayInvite: powerLevels.canOwnUserInvite()" "Wave invitation UI is not permission-gated by room authority"
require "$repository" "MatrixNativeMemberPresentationContract.displayName(" "Native member lists must use privacy-safe presentation"
require "$contract" 'fallbackDisplayName = "WeStreem member"' "Missing profiles must use a neutral WeStreem member label"
require "$contract" "WestreemVibeContactDiscoveryContract" "Testable Contacts privacy contract is missing"
require "$plist" "NSContactsUsageDescription" "Contacts privacy usage description is missing"

if grep -Eq '/api/fan-clubs|/api/fan-club-invites' "$view"; then
  echo "Native Matrix-authoritative invitations must not call legacy Fan Club APIs" >&2
  exit 1
fi

if grep -Fq 'displayName: member.displayName ?? member.userId' "$repository"; then
  echo "Native member lists must never expose raw Matrix IDs as display names" >&2
  exit 1
fi

if grep -Eq 'displayName = (result\\.sender|item\\.sender|sender)$|name \\?\\? (result\\.sender|item\\.sender|sender)' "$repository"; then
  echo "Native timelines, replies, and search must never expose raw Matrix sender IDs" >&2
  exit 1
fi

echo "Westreem Vibe Contacts and invitations source contract passed"
