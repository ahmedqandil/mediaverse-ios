#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
tokens="$root/Social/Vibes/DesignTokens.swift"
constants="$root/Constants.swift"

require() {
  grep -Fq -- "$1" "$2" || {
    echo "FAIL: $3" >&2
    exit 1
  }
}

# Exact Design System palette values must live in the shared iOS token layer.
for token in \
  'ink950 = Color(hex: "#06090B")' \
  'ink900 = Color(hex: "#0B0F0E")' \
  'ink800 = Color(hex: "#0E1312")' \
  'ink700 = Color(hex: "#1A201E")' \
  'surfaceSunken = Color(hex: "#0C110F")' \
  'surfaceSelected = Color(hex: "#101614")' \
  'lineSoft = Color(hex: "#131917")' \
  'lineFrame = Color(hex: "#1E2724")' \
  'lineEdge = Color(hex: "#232B29")' \
  'lineHard = Color(hex: "#2C3531")' \
  'green = Color(hex: "#00E676")' \
  'actRow = Color(hex: "#0A1711")' \
  'pink = Color(hex: "#FF3D8A")' \
  'lavender = Color(hex: "#B388FF")' \
  'text = Color(hex: "#E7EFEB")' \
  'textBody = Color(hex: "#D6E2DD")' \
  'muted = Color(hex: "#A9B8B2")' \
  'textFaint = Color(hex: "#5F6E69")'; do
  require "$token" "$tokens" "missing Design System palette token: $token"
done

for token in \
  'static let xs: CGFloat = 4' \
  'static let s: CGFloat = 8' \
  'static let m: CGFloat = 12' \
  'static let l: CGFloat = 16' \
  'static let xl: CGFloat = 24' \
  'static let xxl: CGFloat = 32' \
  'static let chip: CGFloat = 12' \
  'static let row: CGFloat = 14' \
  'static let card: CGFloat = 16' \
  'static let panel: CGFloat = 18' \
  'static let sheet: CGFloat = 26' \
  'static let control: CGFloat = 999'; do
  require "$token" "$tokens" "missing Design System geometry token: $token"
done

require 'static let body = "Manrope"' "$tokens" "body font token must name Manrope"
require 'static let mono = "JetBrains Mono"' "$tokens" "mono font token must name JetBrains Mono"

# Existing semantic consumers must resolve through the token layer, not repeat
# platform-specific hex values in Constants.swift.
for mapping in \
  'static let bg          = WestreemTokens.Palette.ink950' \
  'static let surface     = WestreemTokens.Palette.ink900' \
  'static let elevated    = WestreemTokens.Palette.ink800' \
  'static let overlay     = WestreemTokens.Palette.ink700' \
  'static let sunken      = WestreemTokens.Palette.surfaceSunken' \
  'static let selected    = WestreemTokens.Palette.surfaceSelected' \
  'static let text         = WestreemTokens.Palette.text' \
  'static let textMuted    = WestreemTokens.Palette.muted' \
  'static let borderSubtle  = WestreemTokens.Palette.lineSoft' \
  'static let borderFrame   = WestreemTokens.Palette.lineFrame' \
  'static let borderEdge    = WestreemTokens.Palette.lineEdge' \
  'static let border        = WestreemTokens.Palette.lineHard' \
  'static let watch     = WestreemTokens.Palette.green' \
  'static let accent = WestreemTokens.Palette.green' \
  'static let danger = WestreemTokens.Palette.pink' \
  'static let cardRadius: CGFloat  = WestreemTokens.Radius.card'; do
  require "$mapping" "$constants" "missing Constants token mapping: $mapping"
done

echo "WeStreem Design System iOS token source contract passed."
