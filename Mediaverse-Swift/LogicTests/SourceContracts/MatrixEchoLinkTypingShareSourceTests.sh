#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
contract="$root/Social/Contracts/MatrixNativeVibesUIContract.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
session="$root/Services/MatrixSessionCoordinator.swift"
api="$root/Services/APIClient.swift"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
media_view="$root/Social/Vibes/MatrixNativeMediaViews.swift"
plist="$root/Info.plist"

grep -q 'maximumDestinations = 20' "$contract"
grep -q 'sourceSenderMatrixUserID' "$contract"
grep -q 'hopTrace' "$contract"
grep -q 'stableTransactionID' "$contract"
grep -q 'canEcho(' "$contract"
grep -q 'sourceIsEncrypted: Bool' "$session"
grep -q 'let sourceRoom = try await repository.waveManagement' "$session"
grep -q '!sourceRoom.isEncrypted' "$session"
grep -q 'let destinationRoom = try await repository.waveManagement' "$session"
grep -q '!destinationRoom.isEncrypted' "$session"
grep -q 'let sourcePage = try await repository.timeline' "$session"
grep -Fq '$0.reference.remoteEventID == sourceEventID' "$session"
grep -q 'resolvedSource.kind != .unableToDecrypt' "$session"
grep -q 'resolvedSource.kind != .redacted' "$session"
grep -q 'sourceSenderMatrixUserID: resolvedSource.senderID' "$session"
grep -q 'sourceSenderName: resolvedSource.senderDisplayName' "$session"
grep -q 'sourceBody: resolvedSource.body' "$session"
grep -q 'existingReference: resolvedSource.westreemReference' "$session"
grep -q 'canOwnUserSendMessage' "$repository"
grep -q 'subscribeToTypingNotifications' "$repository"
grep -q 'guard matrixRoom.membership() == .joined else' "$repository"
grep -q 'let ignoredUserIDs = Set(try await client.ignoredUsers())' "$repository"
grep -q '!ignoredUserIDs.contains' "$repository"
grep -q 'exposePresence: $0.membership == .join' "$repository"
grep -q '&& !ignoredUserIDs.contains($0.userId)' "$repository"
grep -q 'statusText: exposePresence ? member.status?.text : nil' "$repository"
grep -q 'member.status?.text' "$repository"
grep -q 'joinedWaveDestinations' "$repository"
grep -q '/api/matrix/link-preview' "$contract"
grep -q '/api/link-preview/image' "$contract"
grep -q 'WESTREEM_SSRF_SAFE_PREVIEW' "$api"
grep -q 'MatrixNativeLinkPreviewCard' "$view"
grep -q 'enabled: !roomIsEncrypted' "$view"
grep -q 'struct MatrixNativeEchoToWavesSheet' "$view"
grep -q 'ShareLink(item: item.body)' "$view"
grep -q 'MatrixNativeWaveActivityStrip' "$view"
grep -q '.frame(minHeight: 44)' "$view"
grep -q '.frame(width: 44, height: 44)' "$media_view"
grep -q 'record a Vibe video message or join a video lounge' "$plist"
grep -q 'record a Vibe voice or video message' "$plist"

if grep -q 'Older protected Ripples cannot be echoed through the current sharing path' "$view"; then
  :
else
  echo "Legacy protected source Echo must fail closed with visible copy" >&2
  exit 1
fi

echo "Matrix Echo, safe preview, typing, share, and touch-target source contracts passed"
