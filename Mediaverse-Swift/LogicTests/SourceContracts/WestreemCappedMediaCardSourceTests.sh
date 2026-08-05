#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
SOURCE="$ROOT/Views/Home/HomeView.swift"

require() {
    needle="$1"
    message="$2"
    if ! grep -Fq "$needle" "$SOURCE"; then
        printf 'FAIL: %s\n' "$message" >&2
        exit 1
    fi
}

require 'VStack(alignment: .leading, spacing: 0)' '04-F card must use the capped zero-gap shell'
require '.aspectRatio(16 / 9, contentMode: .fit)' '04-F media must stay 16:9'
require '.frame(height: 3)' '04-F playback track must be three points high'
require '.fill(C.watch)' '04-F playback progress must use the active green token'
require '.padding(.horizontal, 13)' '04-F metadata horizontal inset must be 13'
require '.padding(.vertical, 11)' '04-F metadata vertical inset must be 11'
require '.font(.system(size: 13, weight: .bold))' '04-F title typography must be 13 bold'
require '.font(.system(size: 9))' '04-F metadata typography must be mono 9'
require '.clipShape(RoundedRectangle(cornerRadius: C.cardRadius' '04-F card must use radius-card'
require '.stroke(C.borderEdge, lineWidth: 1)' '04-F card must use line-edge'
require '.padding(.horizontal, horizontalSizeClass == .compact ? 0 : 12)' '04-F media must be edge-to-edge on phones and inset on wider layouts'
require 'previewManager.currentTime' '04-F progress must remain bound to real preview time'
require 'NavigationLink(value: sourceRoute)' '04-F owner navigation must remain available'
require 'openMediaAction()' '04-F watch navigation must remain available'

printf 'PASS: WeStreem 04-F capped media card source contract\n'
