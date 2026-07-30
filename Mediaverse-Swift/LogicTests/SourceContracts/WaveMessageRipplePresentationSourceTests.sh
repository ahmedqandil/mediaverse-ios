#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
atmo_card="$root/Social/Ripples/RippleCard.swift"

require() {
  grep -Fq -- "$1" "$2" || { echo "FAIL: $3" >&2; exit 1; }
}

require 'private struct MatrixNativeMessageRow: View' "$view" \
  "Wave messages must use the Matrix-native message presentation."
require 'item.replyPreviews.prefix(' "$view" \
  "A Wave message must preview a bounded number of replies."
require 'MatrixNativeWaveActionPolicy.replyPreviewLimit' "$view" \
  "Reply previews must use the shared Matrix-native policy."
require '"Open discussion"' "$view" \
  "Additional replies must open a dedicated discussion."
require 'MatrixNativeThreadView(room: room, root: threadRoot)' "$view" \
  "Discussions must use canonical Matrix threads."
require 'label: item.reactionCount > 0' "$view" \
  "Energy must lead the Matrix message action row."
require 'label: "Reply"' "$view" \
  "Reply must follow Energy."
require 'Label("More", systemImage: "ellipsis")' "$view" \
  "Ownership and moderation actions must remain in More."
require 'Label("Edit", systemImage: "pencil")' "$view" \
  "Authorized authors must retain Matrix edits."
require 'Label("Report", systemImage: "exclamationmark.bubble")' "$view" \
  "Eligible messages must retain Matrix reporting."
require 'Label("Delete", systemImage: "trash")' "$view" \
  "Authorized users must retain Matrix redaction."
require 'presentation: RippleCardPresentation = .social' "$atmo_card" \
  "Westreem Atmo cards must remain independent from Matrix messages."

if grep -Eq 'RippleCard[(]|LegacySocialAPIAdapter|/api/fan-clubs' "$view"; then
  echo "FAIL: Matrix message presentation reused the retired social authority." >&2
  exit 1
fi

echo "Matrix-native Wave message presentation source contracts passed."
