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
grep -q 'item.kind != .unableToDecrypt' "$session"
grep -q 'existingReference: item.westreemReference' "$session"
grep -q 'canOwnUserSendMessage' "$repository"
grep -q 'subscribeToTypingNotifications' "$repository"
grep -q 'guard matrixRoom.membership() == .joined' "$repository"
grep -q 'let ignoredUserIDs = Set(try await client.ignoredUsers())' "$repository"
grep -q '!ignoredUserIDs.contains' "$repository"
grep -q 'exposePresence: !ignoredUserIDs.contains' "$repository"
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

if grep -q 'Encrypted Ripples cannot be echoed until secure cross-Wave forwarding is verified' "$view"; then
  :
else
  echo "Encrypted source Echo must fail closed with visible copy" >&2
  exit 1
fi

echo "Matrix Echo, safe preview, typing, share, and touch-target source contracts passed"
