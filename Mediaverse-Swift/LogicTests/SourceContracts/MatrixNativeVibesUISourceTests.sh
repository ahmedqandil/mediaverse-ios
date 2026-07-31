#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
media_view="$root/Social/Vibes/MatrixNativeMediaViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
tabs="$root/Views/MainTabView.swift"
app="$root/MediaverseApp.swift"

grep -q 'struct MatrixNativeVibesRootView' "$view"
grep -q 'MatrixNativeWaveRoomView' "$view"
grep -q 'actor MatrixVibesRepositoryFoundation' "$repository"
grep -q 'timelineItems(roomID:' "$repository"
grep -q 'focus: .live(hideThreadedEvents: true)' "$repository"
grep -Fq 'internalIdPrefix: "westreem-room-\(roomID)"' "$repository"
grep -q 'trackReadReceipts: .messageLikeEvents' "$repository"
grep -q 'struct MatrixNativeRoomActivityPresentation' "$repository"
for activity_case in \
  callInvite \
  rtcNotification \
  roomMembership \
  profileChange \
  state \
  failedToParseMessageLike \
  failedToParseState; do
  grep -Eq "case (let )?\.$activity_case" "$repository" || {
    echo "Missing Matrix room activity projection: $activity_case" >&2
    exit 1
  }
done
grep -q 'handle.tryResend()' "$repository"
grep -q 'typingNotice(isTyping:' "$repository"
grep -q 'markAsRead(receiptType: .read)' "$repository"
grep -q 'client.roomDirectorySearch()' "$repository"
grep -q 'getRoomPreviewFromRoomId' "$repository"
grep -q 'preview.info().roomType == .space' "$repository"
grep -q 'joinRoomByIdOrAlias' "$repository"
grep -q 'client.createRoom(' "$repository"
grep -q 'isSpace: true' "$repository"
grep -q 'eventType: "m.space.child"' "$repository"
grep -q 'eventType: "m.space.parent"' "$repository"
grep -q 'inviteUserById' "$repository"
grep -q 'canOwnUserSendState' "$repository"
grep -q 'canOwnUserInvite' "$repository"
grep -q 'matrixNativeVibesEnabled' "$tabs"
grep -q 'MatrixNativeVibesRootView()' "$tabs"
grep -q 'MatrixNativeLegacyRouteUnavailableView' "$tabs"
grep -q '.environmentObject(matrixSession)' "$app"
grep -q 'struct MatrixNativeEchoToAtmoSheet' "$view"
grep -q 'Label("Echo to My Atmo", systemImage: "wave.3.right")' "$view"
grep -q 'sourceType: "MATRIX_EVENT"' "$view"
grep -q 'sourceId: "\\(roomID)|\\(eventID)"' "$view"
grep -q 'WestreemAtmoV2Repository(' "$view"

if grep -Eq 'LegacySocialAPIAdapter|MatrixWaveClient|/api/fan-clubs|/api/fan-club-posts' "$view"; then
  echo "Matrix-native Vibes UI must not import or call the legacy community authority" >&2
  exit 1
fi

for expected in \
  'Loading Vibes' \
  'Vibes unavailable' \
  'Offline — messages will stay queued' \
  'Message this Wave' \
  'Send message' \
  'Read by' \
  'Invitations' \
  'Discover Vibes' \
  'Create Vibe' \
  'Create Wave' \
  'Invite people' \
  'Load more Vibes'; do
  grep -q "$expected" "$view" "$media_view" || {
    echo "Missing Matrix-native UI contract: $expected" >&2
    exit 1
  }
done

# Element-style history pagination is automatic when the top sentinel becomes
# visible; it must retain loading state and an SDK-backed earlier-page request.
grep -q 'requestEarlierMessagesFromTopSentinel' "$view"
grep -q 'requestEarlierMessagesIfNeeded' "$view"
grep -q 'isLoadingHistory' "$view"
grep -q 'MatrixNativeTimelineDaySeparator' "$view"
grep -q 'calendar.isDateInToday(date)' "$view"
grep -q 'Text(item.timestamp, style: .time)' "$view"
grep -q 'isPassiveRoomActivity ? 3' "$view"

echo "Matrix-native Vibes UI source contract passed"
