#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
source_file="$root/Views/Profile/WestreemAccountHubSurface.swift"

test -f "$source_file"
grep -Fq 'westreem-account-hub-26-a' "$source_file"

for copy in \
  'Account' \
  'Edit profile' \
  'Switch context' \
  'History' \
  'Resume watching' \
  'Collections' \
  'Saved clips' \
  'Channel' \
  'Profile & privacy' \
  'Notifications' \
  'Security' \
  'Billing & rentals' \
  'Paired devices' \
  'Affiliation requests' \
  'Sign out'
do
  grep -Fq "$copy" "$source_file"
done

grep -Fq 'case publicAccount = "PUBLIC ACCOUNT"' "$source_file"
grep -Fq 'case privateAccount = "PRIVATE ACCOUNT"' "$source_file"
grep -Fq 'activeSessionCount: Int?' "$source_file"
grep -Fq 'return "UNAVAILABLE"' "$source_file"
grep -Fq 'let onAction: @MainActor (WestreemAccountHubAction) -> Void' "$source_file"
grep -Fq 'let icon: @MainActor (WestreemAccountHubAction) -> AnyView' "$source_file"

if grep -Eq 'URLSession|APIClient|fetch\(' "$source_file"; then
  echo "Account hub must remain projection-only" >&2
  exit 1
fi

echo "WestreemAccountHubSurfaceSourceTests: PASS"
