#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
contract="$root/Social/Contracts/MatrixInvitePinConvergenceContracts.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
session="$root/Services/MatrixSessionCoordinator.swift"
views="$root/Social/Vibes/MatrixNativeVibesViews.swift"
echo_view="$root/Social/Ripples/EchoVibeSheet.swift"
api="$root/Services/APIClient.swift"

grep -q 'maximumPinnedEvents = 100' "$contract"
grep -q 'Missing/redacted/blocked events may still be unpinned' "$contract"
grep -q 'pinnedEventIds.prefix(100)' "$repository"
grep -q 'MatrixPinnedEventMutationContract.decide' "$repository"
grep -q 'getEventTimelineItemByEventId' "$repository"
grep -q 'try await repository.setPinned' "$session"
grep -q 'Unpin unavailable Ripple' "$views"
grep -q 'MatrixPinnedEventFallbackContract.detail' "$views"
grep -q 'resolveMatrixShare' "$echo_view"
grep -q '/api/matrix/share/resolve' "$api"
grep -q 'sendWestreemReference' "$echo_view"
grep -q 'subtitle: "Personal Atmo"' "$echo_view"

echo "Matrix pins and MediaVerse share source contract passed"
