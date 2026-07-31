#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
foundation="$root/Social/Vibes/MatrixNativeDirectNotificationFoundation.swift"
views="$root/Social/Vibes/MatrixNativeDirectNotificationViews.swift"
coordinator="$root/Services/MatrixSessionCoordinator.swift"
push="$root/Services/PushNotificationManager.swift"

require() {
  file="$1"
  pattern="$2"
  message="$3"
  if ! grep -Fq "$pattern" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

reject() {
  file="$1"
  pattern="$2"
  message="$3"
  if grep -Fq "$pattern" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require "$foundation" "client.getDmRoom(userId:" "DM discovery must use MatrixRustSDK"
require "$foundation" "client.createRoom(" "DM creation must use MatrixRustSDK"
require "$foundation" "client.ignoredUsers()" "DM discovery and creation must honor Matrix ignored-user account data"
require "$foundation" "await existing.isEncrypted()" "existing DMs must be verified encrypted before secure presentation"
require "$foundation" "mayPresentExistingRoom(" "direct-room presentation must fail closed on encryption, direct semantics, and canonical peer identity"
require "$foundation" "info.inviter?.userId" "secure direct invitations must resolve their canonical Matrix inviter"
require "$views" "respondToInvitation" "validated direct invitations must expose native accept and decline actions"
require "$foundation" "isEncrypted: true" "new direct rooms must be encrypted"
require "$foundation" "isDirect: true" "new direct rooms must be marked direct"
require "$foundation" 'let creationKey = "\(currentUserID)\u{0}\(target.matrixUserID)"' "DM creation reuse must be isolated by immutable account and peer identity"
require "$foundation" "recentlyCreatedDirectRooms[creationKey]" "sequential starts must reuse the room while SDK sync converges"
require "$foundation" "recentlyCreatedDirectRooms.count > 128" "DM creation convergence state must stay bounded"
require "$foundation" "registerNotificationHandler(listener:" "Matrix sync push rules must drive Vibe notifications"
require "$foundation" "timeline.markAsRead(receiptType: .read)" "Matrix receipts must own notification read state"
require "$views" "APIClient.shared.search(q: normalized, type: \"people\")" "Westreem identity search must discover DM candidates"
require "$coordinator" "directNotificationProvider" "the active Matrix session must own the native adapter"
require "$coordinator" "directNotificationProvider.validateRoomAccess(roomID: roomID)" "timeline and room mutations must revalidate ignored and secure-DM state at entry"
require "$push" "MatrixNativePushRouteStore.shared.stage" "existing APNs tap handling must route Matrix payloads"
reject "$foundation" "MatrixWaveClient" "deprecated handwritten Matrix client must not be used"
reject "$foundation" "URLSession" "native Matrix transport must not bypass MatrixRustSDK"
reject "$foundation" "LegacySocialAPIAdapter" "legacy social APIs must not own DMs or notifications"

echo "PASS: Matrix direct-message and notification source contracts"
