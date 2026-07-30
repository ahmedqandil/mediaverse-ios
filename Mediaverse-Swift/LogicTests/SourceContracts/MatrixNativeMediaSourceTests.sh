#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
foundation="$root/Social/Vibes/MatrixNativeMediaFoundation.swift"
views="$root/Social/Vibes/MatrixNativeMediaViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
controller="$root/Services/MatrixSessionCoordinator.swift"
contract="$root/Social/Contracts/MatrixNativeVibesUIContract.swift"
api_client="$root/Services/APIClient.swift"

for file in "$foundation" "$views" "$repository" "$controller" "$contract" "$api_client"; do
  test -f "$file"
done

for expected in \
  'sendGallery(' \
  'sendImage(' \
  'sendFile(' \
  'sendVoiceMessage(' \
  'sendVideo(' \
  'createPoll(' \
  'sendPollResponse(' \
  'uploadMedia(' \
  'getMediaContent(' \
  'isEncrypted()'; do
  grep -q "$expected" "$repository" || {
    echo "Missing Matrix Rust SDK media boundary: $expected" >&2
    exit 1
  }
done

for expected in \
  'Photos and videos' \
  'Record video' \
  'Voice message' \
  'Create Poll' \
  'Sticker' \
  'Open or share file' \
  'Attachment unavailable'; do
  grep -q "$expected" "$views" || {
    echo "Missing native Matrix media experience: $expected" >&2
    exit 1
  }
done

grep -q 'encryptedMediaUnavailable' "$foundation"
grep -q 'maximumAttachmentCount = 10' "$foundation"
grep -q 'hasExecutableSignature' "$foundation"
grep -q 'attachmentValidationAndLimits' "$contract"
grep -q 'encryptedMediaFailClosed' "$contract"
grep -q 'MatrixNativeApprovedStickerPicker' "$views"
grep -q 'matrixApprovedStickerPacks' "$api_client"
grep -q 'matrixApprovedStickerData' "$api_client"
grep -q 'MatrixNativeApprovedStickerContract.accepts' "$api_client"
grep -q 'sendRaw(eventType: "m.sticker"' "$repository"

if grep -Eq 'LegacySocialAPIAdapter|MatrixWaveClient|URLSession[(]|/api/fan-clubs|/api/fan-club-posts' \
  "$foundation" "$views" "$repository"; then
  echo "Matrix-native media must not use legacy social or handwritten Matrix transport" >&2
  exit 1
fi

echo "Matrix-native media source contract passed"
