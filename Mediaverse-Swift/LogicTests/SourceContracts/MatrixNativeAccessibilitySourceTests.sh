#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
views="$root/Social/Vibes/MatrixNativeVibesViews.swift"
stage="$root/Social/Vibes/MatrixNativeLiveStageView.swift"
threads="$root/Social/Vibes/MatrixNativeThreadPanelView.swift"

require() {
  file="$1"
  text="$2"
  reason="$3"
  if ! grep -Fq "$text" "$file"; then
    printf 'Matrix native accessibility source contract failed: %s\n' "$reason" >&2
    exit 1
  fi
}

require "$views" '@Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion' 'Wave timeline must observe Reduce Motion'
require "$views" 'if accessibilityReduceMotion {' 'Wave timeline must bypass animated scrolling under Reduce Motion'
require "$stage" '@Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion' 'Live Stage must observe Reduce Motion'
require "$stage" 'accessibilityReduceMotion ? nil : .easeInOut(duration: 0.35)' 'speaker activity animation must stop under Reduce Motion'
require "$threads" '@Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion' 'thread panel must observe Reduce Motion'
require "$threads" 'accessibilityReduceMotion ? nil : WestreemTokens.Easing.standard' 'thread transition must stop under Reduce Motion'

printf 'Matrix native accessibility source contracts passed.\n'
