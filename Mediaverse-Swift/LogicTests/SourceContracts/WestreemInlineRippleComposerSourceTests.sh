#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/Social/Ripples/RippleComposer.swift"

grep -Fq 'size: 34' "$SOURCE"
grep -Fq 'Text("Post")' "$SOURCE"
grep -Fq '.buttonStyle(WestreemPillButtonStyle(tone: .primary))' "$SOURCE"
grep -Fq 'Image(systemName: "photo")' "$SOURCE"
grep -Fq 'Image(systemName: "paperclip")' "$SOURCE"
grep -Fq 'Image(systemName: "video")' "$SOURCE"
grep -Fq 'Text("⏎ TO POST")' "$SOURCE"
grep -Fq 'Say something to your Pulse…' "$SOURCE"
grep -Fq 'LegacySocialAPIAdapter(transport: APIClient.shared)' "$SOURCE"
grep -Fq 'Task { await publish() }' "$SOURCE"

if grep -Fq 'Publish Ripple' "$SOURCE"; then
  echo "Legacy full-width publish control remains" >&2
  exit 1
fi

echo "Westreem inline Ripple composer source contract passed"
