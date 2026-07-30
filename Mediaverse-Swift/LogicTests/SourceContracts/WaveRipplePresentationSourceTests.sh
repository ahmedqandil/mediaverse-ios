#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
matrix_view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
atmo_card="$root/Social/Ripples/RippleCard.swift"
atmo_view="$root/Social/Atmosphere/AtmoProfileViews.swift"

require() {
  grep -Fq -- "$1" "$2" || { echo "FAIL: $3" >&2; exit 1; }
}

require 'private struct MatrixNativeMessageRow: View' "$matrix_view" \
  "Community Vibes must use a dedicated Matrix message presentation."
require 'MatrixNativeMessageRow(' "$matrix_view" \
  "Matrix timeline events must render through that presentation."
require 'item.replyPreviews.prefix(' "$matrix_view" \
  "Matrix messages must preview only bounded thread replies."
require 'item.actions.canReply' "$matrix_view" \
  "Reply availability must come from Matrix room permissions."
require 'item.actions.canAddEnergy' "$matrix_view" \
  "Energy availability must come from Matrix reaction permissions."
require 'presentation: RippleCardPresentation = .social' "$atmo_card" \
  "Westreem-owned Atmo cards must remain social by default."
require 'AtmoV2CommentsPanel(post: post, model: model)' "$atmo_view" \
  "Personal Atmo discussion must remain in the Westreem-owned Atmo domain."

if grep -Eq 'RippleCard[(]|LegacySocialAPIAdapter|/api/fan-clubs' "$matrix_view"; then
  echo "FAIL: Matrix Vibes and Westreem Atmo presentation boundaries overlapped." >&2
  exit 1
fi

echo "Matrix-native Wave and Atmo presentation boundary source contracts passed."
