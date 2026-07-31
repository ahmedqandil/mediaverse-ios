#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
models="$root/Social/Vibes/MatrixNativeRoomAttachmentModels.swift"
gallery="$root/Social/Vibes/MatrixNativeRoomAttachmentGalleryView.swift"
project="$root/Mediaverse.xcodeproj/project.pbxproj"

test -f "$models"
test -f "$gallery"
grep -q 'MatrixNativeRoomAttachmentModels.swift in Sources' "$project"
grep -q 'MatrixNativeRoomAttachmentGalleryView.swift in Sources' "$project"

for expected in \
  'enum MatrixNativeRoomAttachmentPayload: Codable, Equatable, Sendable' \
  'case media(MatrixNativeRoomMediaAttachment)' \
  'case document(MatrixNativeRoomDocumentAttachment)' \
  'case link(MatrixNativeRoomLinkAttachment)' \
  'var selection: Set<String>' \
  'var activePreviewIndex: Int?' \
  'var starredIDs: Set<String>' \
  'Today' \
  'Yesterday' \
  'month(.wide).year()' \
  'descriptor: MatrixNativeMediaDescriptor' \
  'eventReference: MatrixNativeEventReference' \
  'item.actions.canRedact' \
  'scheme == "https" || scheme == "http"' \
  'url.user == nil, url.password == nil'; do
  grep -q "$expected" "$models" || {
    echo "Missing room attachment model contract: $expected" >&2
    exit 1
  }
done

grep -q 'MatrixNativeRoomAttachmentLocalStore' "$models"
grep -q 'UserDefaults' "$models"
grep -q 'maximumIDs = 1_000' "$models"
grep -q 'SHA256.hash' "$models"
grep -q 'QLPreviewController' "$gallery"
grep -q 'completeFileProtection' "$gallery"
grep -q 'cleanupPreview' "$gallery"
grep -q 'MatrixNativeLinkPreviewCard' "$gallery"
grep -q 'roomIsEncrypted: roomIsEncrypted' "$gallery"

for expected in \
  'LazyVGrid' \
  'pinnedViews:' \
  'aspectRatio(1, contentMode: .fill)' \
  'TabView' \
  'PageTabViewStyle' \
  'MagnificationGesture' \
  '2.5' \
  '150' \
  'Delete for Me' \
  'Delete for Everyone' \
  'Forward' \
  'Star'; do
  grep -q "$expected" "$gallery" || {
    echo "Missing room attachment gallery UI: $expected" >&2
    exit 1
  }
done

if grep -Eq 'cloudflarestorage[.]com|r2[.]dev' "$models" "$gallery"; then
  echo "Room attachment gallery must use canonical Matrix media only" >&2
  exit 1
fi

echo "Matrix-native room attachment gallery source contract passed"
