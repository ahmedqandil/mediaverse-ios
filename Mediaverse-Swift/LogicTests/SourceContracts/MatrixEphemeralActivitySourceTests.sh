#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
foundation="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
views="$root/Social/Vibes/MatrixNativeVibesViews.swift"

require() {
  file="$1"; needle="$2"; message="$3"
  if ! grep -Fq "$needle" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require "$foundation" 'exposePresence: $0.membership == .join' 'presence must be hidden for invited, banned, requested and left members'
require "$foundation" 'let ignoredUserIDs = Set((try? await client.ignoredUsers()) ?? [])' 'typing must refresh the authoritative ignore list for every update'
require "$foundation" 'try await timeline.markAsRead(receiptType: .read)' 'read state must remain SDK authoritative'
require "$views" '@State private var typingExpiryTask: Task<Void, Never>?' 'local typing must own a cancellable expiry'
require "$views" 'Task.sleep(for: .seconds(8))' 'typing must expire locally when editing stops silently'
require "$views" 'if phase != .active { updateTypingState(false) }' 'backgrounding must send a stop-typing transition'
require "$views" 'typingUserIDs.count - typingNames.count' 'large-room typing overflow must remain exact'
require "$views" 'typingUserIDs.prefix(2)' 'large-room typing names must remain render bounded'

echo "PASS: Matrix ephemeral activity privacy, expiry and overflow contracts"
