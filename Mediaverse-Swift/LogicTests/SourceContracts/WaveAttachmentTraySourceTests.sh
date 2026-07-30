#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeMediaViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"

for label in \
  'Photos and videos' \
  'Record video' \
  'Voice message' \
  'File' \
  'Poll' \
  'Sticker'; do
  grep -Fq -- "$label" "$view" || {
    echo "FAIL: Matrix attachment tray is missing $label." >&2
    exit 1
  }
done

grep -Fq 'allowsMultipleSelection: true' "$view" || {
  echo "FAIL: Matrix attachment tray must support multiple files." >&2
  exit 1
}
grep -Fq 'maximumAttachmentCount' "$view" || {
  echo "FAIL: Matrix attachments must enforce the shared count limit." >&2
  exit 1
}
for operation in sendGallery sendImage sendFile sendVoiceMessage sendVideo createPoll; do
  grep -Fq -- "$operation(" "$repository" || {
    echo "FAIL: Matrix repository is missing $operation." >&2
    exit 1
  }
done

if grep -Eq 'LegacySocialAPIAdapter|/api/fan-clubs|/api/fan-club-posts' "$view" "$repository"; then
  echo "FAIL: Matrix attachments crossed the retired social authority." >&2
  exit 1
fi

echo "Matrix-native Wave attachment tray source contracts passed."
