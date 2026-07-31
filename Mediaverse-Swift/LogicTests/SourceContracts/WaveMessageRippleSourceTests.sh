#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
media="$root/Social/Vibes/MatrixNativeMediaViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
tabs="$root/Views/MainTabView.swift"

require() {
  grep -Fq -- "$1" "$2" || { echo "FAIL: $3" >&2; exit 1; }
}

require 'MatrixNativeMessageRow(' "$view" \
  "Wave timelines must render Matrix events as native messages."
require 'MatrixNativeRichComposer(' "$view" \
  "Wave conversations must expose a persistent rich composer."
require '.safeAreaInset(edge: .bottom, spacing: 0)' "$view" \
  "The Wave composer must remain visible while reading."
require 'TextField("Message this Wave"' "$media" \
  "The Wave composer must accept inline text."
require 'try await matrixSession.sendText(' "$view" \
  "Inline messages must send through the Matrix session."
require 'transactionID: transactionID' "$view" \
  "Offline/retry identity must remain idempotent."
require 'case failed(isRecoverable: Bool)' "$repository" \
  "The Matrix timeline must represent recoverable local send failure."
require 'try await handle.tryResend()' "$repository" \
  "Failed Matrix sends must support SDK retries."
require 'MatrixNativeThreadView(room: room, root: root)' "$view" \
  "Additional replies must open a native Matrix thread."
require '.vibe, .vibeWave:' "$tabs" \
  "Vibe and Wave routes must hide global bottom chrome."
require '.matrixWaveVisibilityChanged' "$view" \
  "Matrix-native Wave rooms must announce their bottom chrome visibility."
require 'isMatrixWavePresented' "$tabs" \
  "The app shell must hide its custom bottom navigation while a Matrix-native Wave is open."

if grep -Eq 'api[.]createRipple|LegacySocialAPIAdapter|/api/fan-clubs' "$view" "$media"; then
  echo "FAIL: Wave messages must not write through the retired Ripple authority." >&2
  exit 1
fi

echo "Matrix-native Wave message source contracts passed."
