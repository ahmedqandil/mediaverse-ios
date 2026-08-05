#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SOURCE="$ROOT/Views/Auth/WestreemEntryAuthSurface.swift"

grep -Fq 'struct WestreemBrowseFirstSurface<LivePreview: View>: View' "$SOURCE"
grep -Fq 'Button("Look around first", action: browse)' "$SOURCE"
grep -Fq 'Button("Sign in", action: signIn)' "$SOURCE"
grep -Fq 'Communities, live voice and video\nin one place.' "$SOURCE"
grep -Fq 'YOU CAN WATCH, BROWSE AND SEARCH SIGNED OUT\nSIGNING IN HAPPENS WHEN YOU ACT' "$SOURCE"
grep -Fq 'let browse: @MainActor () -> Void' "$SOURCE"
grep -Fq 'let signIn: @MainActor () -> Void' "$SOURCE"
grep -Fq '@ViewBuilder let livePreview: () -> LivePreview' "$SOURCE"
grep -Fq 'WestreemTokens.Palette.surfaceSelected' "$SOURCE"
grep -Fq 'WestreemTokens.Palette.lineEdge' "$SOURCE"
grep -Fq 'WestreemTokens.Radius.panel' "$SOURCE"
grep -Fq 'WestreemTokens.Palette.green' "$SOURCE"
grep -Fq 'WestreemTokens.Palette.surfaceRaisedEnd' "$SOURCE"
grep -Fq 'westreem-browse-first-24-a' "$SOURCE"

echo "Westreem browse-first 24-A source checks passed"
