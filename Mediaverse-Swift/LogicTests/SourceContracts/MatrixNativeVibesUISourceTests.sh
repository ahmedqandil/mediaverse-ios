#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
media_view="$root/Social/Vibes/MatrixNativeMediaViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
tabs="$root/Views/MainTabView.swift"
app="$root/MediaverseApp.swift"
tab_strip="$root/Utilities/MediaverseTabStrip.swift"

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
grep -Fq 'Root page container: Vibes · Videos · Shorts · Discover' "$tabs"
grep -Fq '@State private var selectedTab: AppTab = .myVibes' "$tabs"
grep -Fq 'bottomTabButton(.myVibes, title: vibesTabTitle' "$tabs"
grep -Fq 'bottomTabButton(.videos, title: "Videos"' "$tabs"
grep -Fq 'bottomTabButton(.shorts, title: "Shorts"' "$tabs"
grep -Fq 'bottomTabButton(.explore, title: "Discover"' "$tabs"
if grep -Fq 'bottomTabButton(.home' "$tabs"; then
  echo "Home must not be a primary iOS destination" >&2
  exit 1
fi
grep -Fq 'C.lightHaptic()' "$tabs"
grep -q '.environmentObject(matrixSession)' "$app"
grep -q 'struct MatrixNativeEchoToAtmoSheet' "$view"
grep -q 'Label("Echo to My Atmo", systemImage: "wave.3.right")' "$view"
grep -q 'sourceType: "MATRIX_EVENT"' "$view"
grep -q 'sourceId: "\\(roomID)|\\(eventID)"' "$view"
grep -q 'WestreemAtmoV2Repository(' "$view"

# Vibe Home/Events/Members/Info navigation uses the shared underline strip.
# Every tab must expose a stable label/identifier and its selected state to
# VoiceOver/UI automation; visual colour/underline is not the sole state cue.
grep -q 'MediaverseUnderlineTabStrip(' "$view"
grep -q 'accessibilityIdentifier("mediaverse-tab-\\(item.id)"' "$tab_strip"
grep -q 'accessibilityLabel(item.label)' "$tab_strip"
grep -q 'accessibilityAddTraits(isSelected(item) ? .isSelected : \[\])' "$tab_strip"

# The selected-Vibe Home is intentionally Waves-first: a compact identity
# strip is followed by one mixed Wave projection, with active live experiences
# leading that same list. Events stay in the Events tab rather than becoming a
# suggestion dashboard on Home.
home_content="$(sed -n '/private var homeContent/,/private var eventsContent/p' "$view")"
printf '%s\n' "$home_content" | grep -Fq 'MatrixNativeVibeIdentityStrip('
printf '%s\n' "$home_content" | grep -Fq 'MatrixNativeSectionLabel(title: "Waves"'
printf '%s\n' "$home_content" | grep -Fq 'waveRows(liveLounges: activeLounges)'
if printf '%s\n' "$home_content" | grep -Fq 'VibeEventCardView('; then
  echo "Vibe Home must not duplicate Event cards outside the Events tab" >&2
  exit 1
fi
if printf '%s\n' "$home_content" | grep -Fq 'title: "Live lounges"'; then
  echo "Live experiences must lead the unified Wave list on Vibe Home" >&2
  exit 1
fi

# The root Waves inbox is one Matrix-authoritative recency list. Personal and
# community entries keep their existing destinations while sharing ordering.
# Pinning is the only rank override; Live remains a filter and row state.
combined_content="$(sed -n '/private struct MatrixNativeCombinedWavesView/,/private struct MatrixNativeVibeView/p' "$view")"
printf '%s\n' "$combined_content" | grep -Fq 'private enum WaveInboxItem'
printf '%s\n' "$combined_content" | grep -Fq 'private enum WaveInboxFilter'
for filter in 'case all = "All"' 'case unread = "Unread"' 'case vibes = "Vibes"' 'case live = "Live"'; do
  printf '%s\n' "$combined_content" | grep -Fq -- "$filter" || {
    echo "Missing canonical Wave inbox filter: $filter" >&2
    exit 1
  }
done
printf '%s\n' "$combined_content" | grep -Fq 'case personal(MatrixDirectRoomSummary)'
printf '%s\n' "$combined_content" | grep -Fq 'case community(MatrixWaveSummary)'
printf '%s\n' "$combined_content" | grep -Fq 'private enum ChatInboxRow'
printf '%s\n' "$combined_content" | grep -Fq 'case request(MatrixNativeInvitationSummary)'
printf '%s\n' "$combined_content" | grep -Fq 'private struct UnifiedWaveRow'
printf '%s\n' "$combined_content" | grep -Fq 'private struct WaveRequestRow'
printf '%s\n' "$combined_content" | grep -Fq 'MatrixNativeSectionLabel('
printf '%s\n' "$combined_content" | grep -Fq 'selectedFilter == .all ? "Chats" : selectedFilter.rawValue'
printf '%s\n' "$combined_content" | grep -Fq 'count: filteredRecencySortedRows.count'
printf '%s\n' "$combined_content" | grep -Fq 'private var recencySortedItems'
printf '%s\n' "$combined_content" | grep -Fq 'private var filteredRecencySortedItems'
printf '%s\n' "$combined_content" | grep -Fq 'private var filteredRecencySortedRows'
printf '%s\n' "$combined_content" | grep -Fq '.blur(radius: 2.6)'
printf '%s\n' "$combined_content" | grep -Fq 'Message preview hidden until accepted.'
printf '%s\n' "$combined_content" | grep -Fq 'try await matrixSession.acceptInvite(roomID: invitation.id)'
printf '%s\n' "$combined_content" | grep -Fq 'try await matrixSession.declineInvite(roomID: invitation.id)'
printf '%s\n' "$combined_content" | grep -Fq 'left.lastActivity ?? .distantPast'
printf '%s\n' "$combined_content" | grep -Fq 'return left.id < right.id'
printf '%s\n' "$combined_content" | grep -Fq 'private func rowIsPinned'
if printf '%s\n' "$combined_content" | grep -Fq 'let leftLive:'; then
  echo "Live state must not override unified Wave recency ordering" >&2
  exit 1
fi
printf '%s\n' "$combined_content" | grep -Fq 'communityWaves = Array('
printf '%s\n' "$combined_content" | grep -Fq '.filter { !$0.isNestedSpace }'
printf '%s\n' "$combined_content" | grep -Fq 'MatrixNativeWaveRoomView(room: room.timelineRoom)'
printf '%s\n' "$combined_content" | grep -Fq 'MatrixNativeWaveRoomView(room: room)'
printf '%s\n' "$combined_content" | grep -Fq 'kindLabel'
for row_action in \
  'private struct DesignSystemWaveSwipeContainer' \
  'static var leading: CGFloat { 88 }' \
  'static var shortTrailing: CGFloat { 88 }' \
  'static var fullTrailing: CGFloat { 174 }' \
  'static var fullThreshold: CGFloat { -116 }' \
  'width: 60' \
  'width: 58' \
  'width: 56' \
  'WestreemTokens.Easing.spring' \
  'UISelectionFeedbackGenerator().selectionChanged()' \
  '.contextMenu {' \
  '"Notify for every Ripple"' \
  '"Pin to the top"' \
  '"Mute this Wave"' \
  '"Mark as unread"' \
  '"Hide Personal Wave"' \
  'pendingCommunityLeave' \
  'Button("Undo", action: undoAction)'; do
  printf '%s\n' "$combined_content" | grep -Fq -- "$row_action" || {
    echo "Missing canonical Wave row action: $row_action" >&2
    exit 1
  }
done
if printf '%s\n' "$combined_content" | grep -Fq '.swipeActions('; then
  echo "The Design System Wave row must not fall back to native swipeActions geometry" >&2
  exit 1
fi
unread_mutation="$(awk '
  /func setWaveUnread\(roomID: String, unread: Bool\) async throws/ {
    count += 1
    if (count == 2) capture = 1
  }
  capture { print }
  capture && /func setWaveFavourite\(roomID: String, favourite: Bool\)/ { exit }
' "$repository")"
printf '%s\n' "$unread_mutation" | grep -Fq 'if !unread {'
printf '%s\n' "$unread_mutation" | grep -Fq 'let timeline = try await matrixRoom.timeline()'
printf '%s\n' "$unread_mutation" | grep -Fq 'try await timeline.markAsRead(receiptType: .read)'
printf '%s\n' "$unread_mutation" | grep -Fq 'try await matrixRoom.setUnreadFlag(newValue: unread)'
if [ "$(printf '%s\n' "$unread_mutation" | grep -n 'markAsRead' | cut -d: -f1)" -ge "$(printf '%s\n' "$unread_mutation" | grep -n 'setUnreadFlag' | cut -d: -f1)" ]; then
  echo "Mark read must advance the receipt before clearing the manual unread flag" >&2
  exit 1
fi
grep -Fq 'try await matrixRoom.setIsFavourite(' "$repository"
grep -Fq 'try await matrixRoom.setIsLowPriority(isLowPriority: true' "$repository"
grep -Fq 'try await matrixSession.setWaveUnread(' "$view"
grep -Fq 'try await matrixSession.setWaveFavourite(' "$view"
grep -Fq 'try await matrixSession.hidePersonalWave(' "$view"
grep -Fq 'let lastActivity: Date?' "$repository"
grep -Fq 'private static func latestActivityDate(room: Room)' "$repository"
grep -Fq 'let lastActivity = await latestActivityDate(room: matrixRoom)' "$repository"
grep -Fq 'lastActivity: lastActivity' "$repository"
grep -Fq 'lastActivity: lastActivity' "$root/Social/Vibes/MatrixNativeDirectNotificationFoundation.swift"
if printf '%s\n' "$combined_content" | grep -Fq 'title: "Personal Waves"'; then
  echo "Root Waves inbox must not split Personal Waves into a separate section" >&2
  exit 1
fi
if printf '%s\n' "$combined_content" | grep -Fq 'title: "Vibe Waves"'; then
  echo "Root Waves inbox must not split community Waves into a separate section" >&2
  exit 1
fi

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
