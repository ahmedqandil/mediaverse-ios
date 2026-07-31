#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
pipeline="$root/Social/Vibes/MatrixNativeAttachmentPipeline.swift"
project="$root/Mediaverse.xcodeproj/project.pbxproj"

test -f "$pipeline"
grep -q 'MatrixNativeAttachmentPipeline.swift in Sources' "$project"

for expected in \
  'case dataSaver' \
  'case standard' \
  'case original' \
  'case preparing' \
  'case compressing' \
  'case uploading' \
  'case sending' \
  'case delivered' \
  'case failed' \
  'transactionID' \
  'func enqueueBatch' \
  'Exactly one SDK send preserves Matrix gallery semantics' \
  'preparedUploads.append' \
  'func retry(batchID:' \
  'func retry' \
  'func cancel' \
  'completeFileProtection' \
  'kCGImageSourceCreateThumbnailWithTransform' \
  'AVAssetExportPreset1280x720' \
  'AVAssetExportPreset1920x1080' \
  'shouldOptimizeForNetworkUse = true' \
  'MatrixNativeThumbnailCache' \
  'MatrixNativeThumbnailPrefetcher' \
  'visibleSourceIdentities' \
  'haloSourceIdentities'; do
  grep -q "$expected" "$pipeline" || {
    echo "Missing attachment pipeline contract: $expected" >&2
    exit 1
  }
done

grep -q 'Task.detached(priority: .userInitiated)' "$pipeline"
grep -q 'var progress: Double?' "$pipeline"
grep -q 'var transferredBytes: Int64?' "$pipeline"
grep -q 'value.stage = .uploading' "$pipeline"
grep -q 'value.progress = nil' "$pipeline"
if grep -q 'Double(item.totalBytes) \* item.progress' "$pipeline"; then
  echo "Upload progress must not be fabricated from lifecycle stages" >&2
  exit 1
fi
grep -q 'if let authoritativeProgress' "$root/Social/Vibes/MatrixNativeMediaViews.swift"
grep -q 'Progress unavailable' "$root/Social/Vibes/MatrixNativeMediaViews.swift"

grep -q 'MatrixNativeAttachmentQuality.standard' "$root/Social/Vibes/MatrixNativeMediaViews.swift"
grep -q 'Photo and video upload quality' "$root/Social/Vibes/MatrixNativeMediaViews.swift"
grep -q 'sendQueuedAttachments' "$root/Social/Vibes/MatrixNativeVibesViews.swift"
grep -q 'try await matrixSession.sendAttachments(' "$root/Social/Vibes/MatrixNativeVibesViews.swift"

if grep -Eq 'cloudflarestorage[.]com|r2[.]dev|http://|https://' "$pipeline"; then
  echo "Attachment pipeline must not expose storage-provider or public URLs" >&2
  exit 1
fi

echo "Matrix-native attachment pipeline source contract passed"
