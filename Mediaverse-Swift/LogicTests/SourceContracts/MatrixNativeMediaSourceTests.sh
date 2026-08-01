#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
foundation="$root/Social/Vibes/MatrixNativeMediaFoundation.swift"
views="$root/Social/Vibes/MatrixNativeMediaViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
controller="$root/Services/MatrixSessionCoordinator.swift"
contract="$root/Social/Contracts/MatrixNativeVibesUIContract.swift"
migration_contract="$root/Social/Contracts/MatrixAttachmentStorageMigrationContract.swift"
api_client="$root/Services/APIClient.swift"

for file in "$foundation" "$views" "$repository" "$controller" "$contract" "$migration_contract" "$api_client"; do
  test -f "$file"
done

for expected in \
  'sendGallery(' \
  'sendImage(' \
  'sendAudio(' \
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

grep -q 'handle.join()' "$repository"
grep -q 'MediaSource.fromJson(json: sourceJSON)' "$repository"
grep -q 'getMediaContent(mediaSource: source)' "$repository"
grep -q 'getMediaThumbnail(' "$repository"
grep -q 'permitsDirectCloudflareUpload = false' "$migration_contract"
grep -q 'permitsClientTranscoding = false' "$migration_contract"
grep -q 'uploadProgressOwner: LifecycleOwner = .matrixRustSDK' "$migration_contract"
grep -q 'retryOwner: LifecycleOwner = .matrixRustSDK' "$migration_contract"
grep -q 'value.hasPrefix("mxc://")' "$migration_contract"

if grep -Eq 'cloudflarestorage[.]com|r2[.]dev|/api/.*/upload-url' \
    "$foundation" "$views" "$repository" "$controller"; then
  echo "Matrix attachment clients must not know the Cloudflare storage provider" >&2
  exit 1
fi

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
grep -q 'legacyEncryptedMediaIsolation' "$contract"
grep -q 'MatrixNativeApprovedStickerPicker' "$views"
grep -q 'matrixApprovedStickerPacks' "$api_client"
grep -q 'matrixApprovedStickerData' "$api_client"
grep -q 'MatrixNativeApprovedStickerContract.accepts' "$api_client"
grep -q 'sendRaw(eventType: "m.sticker"' "$repository"
grep -q 'if let expectedSize, expectedSize > maximum' "$repository"
if sed -n '/func mediaData(/,/func avatarData/p' "$repository" | grep -q 'guard let expectedSize'; then
  echo "Inbound Matrix media must accept events without optional info.size" >&2
  exit 1
fi
grep -q 'state == .unavailable' "$views"
grep -q 'Button("Retry")' "$views"
grep -q 'thumbnailSourceJSON: content.info?.thumbnailSource?.toJson()' "$repository"
grep -q 'if let thumbnail = media.authenticatedThumbnail' "$views"
grep -q 'thumbnailData = try? await matrixSession.mediaData' "$views"
grep -q 'Loading image preview' "$views"
grep -q 'state == .idle || state == .loading' "$views"
grep -q 'Image(systemName: "play.fill")' "$views"
grep -q 'generatedData = try? await matrixSession.mediaThumbnailData' "$views"
grep -q 'MatrixNativeWaveformAnalyzer.samples(from: url)' "$views"
grep -q 'static let fallbackSamples' "$views"
grep -q 'let barWidth: CGFloat = 2' "$views"
grep -q 'WaveformBarsView(' "$views"

if grep -Eq 'LegacySocialAPIAdapter|MatrixWaveClient|URLSession[(]|/api/fan-clubs|/api/fan-club-posts' \
  "$foundation" "$views" "$repository"; then
  echo "Matrix-native media must not use legacy social or handwritten Matrix transport" >&2
  exit 1
fi

echo "Matrix-native media source contract passed"
