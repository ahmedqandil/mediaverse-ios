#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
views="$root/Social/Vibes/MatrixNativeVibesViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
contract="$root/Social/Contracts/MatrixInvitePinConvergenceContracts.swift"

grep -q 'func pendingInvitations()' "$repository"
grep -q 'client.rooms().filter({ $0.membership() == .invited })' "$repository"
grep -q 'MatrixInvitationSafetyContract.evaluate' "$repository"
grep -q 'try await invited.join()' "$repository"
grep -q 'try await invited.leave()' "$repository"
grep -q 'MatrixInviteDeclineBlockContract.plan' "$repository"
grep -q 'kind == .personalWave && !inviterValid' "$contract"
grep -q 'Blocked inviter. Acceptance unavailable.' "$views"
if grep -q 'Unencrypted Personal Wave invitation cannot be accepted.' "$views"; then
  echo "Unencrypted Personal Waves must not be rejected" >&2
  exit 1
fi
grep -q 'Decline and block .*?' "$views"
grep -q 'guard pendingInvitationID == nil' "$views"
grep -q 'accessibilityLabel(".* invitation to' "$views"

echo "Matrix-native invitation source contract passed"
