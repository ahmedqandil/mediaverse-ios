#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
destinations="$root/Social/Vibes/SocialDestinationViews.swift"
affiliations="$root/Social/Vibes/VibeAffiliationsView.swift"
invitations="$root/Social/Vibes/VibeInvitationsView.swift"
management="$root/Social/Vibes/VibeManagementViews.swift"
native_views="$root/Social/Vibes/MatrixNativeVibesViews.swift"
native_repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"

for file in "$destinations" "$affiliations" "$invitations" "$management"; do
  if grep -Eq 'LEGACY_VIBES_ROLLBACK|LegacySocialAPIAdapter|MatrixWaveClient|/api/fan-club' "$file"; then
    echo "A retired Vibe authority remains in an active source file: $file" >&2
    exit 1
  fi
done

grep -q 'MatrixNativeLegacyRouteUnavailableView' "$destinations"
grep -q 'MatrixNativeLegacyRouteUnavailableView' "$invitations"
grep -q 'MatrixNativeVibesRootView()' "$management"
grep -q 'MatrixNativeLegacyRouteUnavailableView' "$affiliations"
grep -q 'struct MatrixNativeVibesRootView' "$native_views"
grep -q 'actor MatrixVibesRepositoryFoundation' "$native_repository"

echo "Legacy Vibes source retirement contract passed"
