#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
views="$root/Social/Vibes/MatrixNativeVibesViews.swift"

grep -q 'focusedTimelines: \[String: MatrixFocusedTimelineSession\]' "$repository"
grep -q 'focusedThreadTimelines: \[String: MatrixFocusedTimelineSession\]' "$repository"
grep -q 'await accumulator.waitForInitialSnapshot()' "$repository"
grep -q 'hasMore: !session.hitTimelineStart' "$repository"
grep -q 'nextToken: snapshot.hasMore ? "previous" : nil' "$repository"
grep -q 'releaseTimeline(roomID: room.id)' "$views"
grep -q 'info?.numUnreadNotifications ?? 0' "$repository"
grep -q 'room.unreadCount > 99 ? "99+"' "$views"

echo "Matrix focused timeline hydration source contract passed"
