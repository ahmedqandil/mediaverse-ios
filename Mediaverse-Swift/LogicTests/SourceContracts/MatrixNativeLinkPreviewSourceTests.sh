#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
contract="$root/Social/Contracts/MatrixNativeVibesUIContract.swift"
view="$root/Social/Vibes/MatrixNativeMediaViews.swift"
session="$root/Services/MatrixSessionCoordinator.swift"
api="$root/Services/APIClient.swift"

require() {
  grep -Fq "$2" "$1" || { echo "$3" >&2; exit 1; }
}

require "$contract" 'public struct MatrixNativeLinkPreviewCache' 'Preview metadata must use a bounded account cache'
require "$contract" 'maximumEntriesPerAccount = 100' 'Preview cache must be bounded'
require "$contract" 'timeToLive: TimeInterval = 10 * 60' 'Preview cache must expire'
require "$contract" 'isAllowedPort(components.port' 'Nonstandard ports must fail closed'
require "$session" 'eventType: "org.matrix.preview_urls"' 'Swift must read the Element account preference'
require "$session" 'return false' 'Unreadable preference state must fail closed'
require "$view" 'MatrixNativeLinkPreviewStore.shared.remove' 'Edited or redacted links must invalidate old metadata'
require "$view" 'guard !Task.isCancelled else { return }' 'Stale preview requests must not mutate visible state'
require "$view" 'Link preview unavailable' 'Unavailable previews need accessible UI'
require "$api" 'derivedBy == "WESTREEM_SSRF_SAFE_PREVIEW"' 'Swift must verify preview authority'

echo "Matrix-native link preview source contract passed"
