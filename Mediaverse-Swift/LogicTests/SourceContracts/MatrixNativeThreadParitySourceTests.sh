#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
panel="$root/Social/Vibes/MatrixNativeThreadPanelView.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
coordinator="$root/Services/MatrixSessionCoordinator.swift"

require() {
  file="$1"
  value="$2"
  message="$3"
  grep -Fq "$value" "$file" || {
    echo "$message" >&2
    exit 1
  }
}

require "$repository" 'focus: .thread(rootEventId: rootEventID)' 'Thread timelines must use the standard Matrix m.thread focus'
require "$repository" 'timeline.sendReply(msg: content, eventId: rootEventID)' 'Thread replies must use the SDK relation API'
require "$repository" 'func eventItem(roomID: String, eventID: String)' 'Exact thread roots must be recoverable outside the room window'
require "$repository" 'timeline.fetchDetailsForEvent(eventId: eventID)' 'Deep links must hydrate missing events'
require "$repository" 'func markThreadRead(roomID: String, rootEventID: String)' 'Threads require an independent receipt path'
require "$repository" 'focusedThreadTimelines: [String: MatrixFocusedTimelineSession]' 'Thread timelines must retain their listener beyond initial creation'
require "$repository" 'await accumulator.waitForInitialSnapshot()' 'Thread timelines must await the first SDK diff instead of racing it'
require "$repository" 'try await session.timeline.markAsRead(receiptType: .read)' 'Thread receipts must advance on the retained focused timeline'
require "$repository" 'func releaseThreadTimeline(roomID: String, rootEventID: String)' 'Focused thread timelines must have an explicit lifecycle release'
require "$repository" 'let service = matrixRoom.threadListService()' 'Discovery must use the SDK server-backed thread list'
require "$repository" 'try await service.paginate()' 'Thread discovery must paginate through the SDK service'
require "$repository" 'isParticipated: root.isOwn || replies.contains(where: \.isOwn)' 'My threads must use Matrix identity participation'
require "$repository" 'hasUnread: false' 'Unavailable SDK unread state must fail closed rather than invent badges'
require "$panel" 'case mine = "My"' 'The panel must expose My threads'
require "$panel" 'summaries.filter(\.isParticipated)' 'My threads must filter on participation'
require "$view" 'Label("Load earlier replies", systemImage: "arrow.up")' 'Thread history must paginate independently'
require "$view" 'MatrixTimelineMerge.items(' 'Paginated thread history must deduplicate'
require "$view" 'guard values.count > 240 else { return values }' 'Thread rendering must stay bounded'
require "$view" 'threadRoot = try await matrixSession.event(' 'A selected summary must recover its exact root'
require "$view" 'MatrixNativeReadReceiptStrip(' 'Own messages must render Matrix-authoritative receipt avatars'
require "$view" 'navigationTitle("Read receipts")' 'Receipt avatars must expose an accessible detail list'
require "$view" 'Button("Try again") { Task { await load() } }' 'Failed thread synchronization must provide an explicit retry'
require "$view" 'releaseThreadTimeline(' 'Closing a discussion must release only its focused timeline'
require "$coordinator" 'repository.markThreadRead(' 'The session must route thread receipts independently'

echo "Matrix-native thread parity source contract passed"
