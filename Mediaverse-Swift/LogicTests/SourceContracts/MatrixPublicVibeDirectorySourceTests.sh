#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
foundation="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
views="$root/Social/Vibes/MatrixNativeVibesViews.swift"

require() {
  file="$1"
  needle="$2"
  message="$3"
  if ! grep -Fq "$needle" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require "$foundation" 'let current = try await publicSpacePreview(space)' 'join and leave must revalidate the current public Space preview'
require "$foundation" 'info.roomId == space.id, info.roomType == .space' 'preview must preserve exact Matrix identity and Space type'
require "$foundation" '!(await joined.isEncrypted())' 'joined encrypted targets must fail closed'
require "$foundation" 'if current.membership == .joined { return }' 'joining an already joined public Space must be idempotent'
require "$foundation" 'guard current.membership == .joined else { return }' 'leaving an already-left public Space must be idempotent'
require "$foundation" '.precomposedStringWithCanonicalMapping' 'directory query must normalize canonical Unicode forms'
require "$foundation" 'String($0.prefix(100))' 'directory query work must remain bounded'
require "$views" 'MatrixNativePublicVibePreviewView(space: space)' 'directory selection must open a preview before membership mutation'
require "$views" '@AccessibilityFocusState private var previewHeadingFocused: Bool' 'resolved preview must expose accessibility focus'
require "$views" '.confirmationDialog(' 'leave must require explicit confirmation'
require "$views" 'guard !isChangingMembership, let current = preview else { return }' 'membership actions must reject concurrent activation'
require "$views" 'guard requestID == latestDirectoryRequestID else { return }' 'stale search and cursor results must not replace current results'

echo "PASS: Matrix public Vibe directory preview and membership contracts"
