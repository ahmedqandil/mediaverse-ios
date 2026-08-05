#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
tokens="$root/Social/Vibes/DesignTokens.swift"
constants="$root/Constants.swift"
plist="$root/Info.plist"
project="$root/Mediaverse.xcodeproj/project.pbxproj"
manrope="$root/Resources/Fonts/Manrope-Variable.ttf"
jetbrains="$root/Resources/Fonts/JetBrainsMono-Variable.ttf"

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
  'static let fast: Double = 0.12' \
  'static let standard: Double = 0.20' \
  'static let slow: Double = 0.24'; do
  require "$token" "$tokens" "missing Design System motion token: $token"
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
require 'static let bodyRegular = "Manrope-Regular"' "$tokens" "body font must use the bundled Manrope face"
require 'static let monoMedium = "JetBrainsMonoRoman-Medium"' "$tokens" "mono font must use the bundled JetBrains Mono face"
require '.custom(FontFamily.bodyBold, size: 22, relativeTo: .title2)' "$tokens" "title token must use bundled Manrope"
require '.custom(FontFamily.monoMedium, size: 11, relativeTo: .caption2)' "$tokens" "mono token must use bundled JetBrains Mono"

test -f "$manrope" || { echo "FAIL: bundled Manrope font is missing" >&2; exit 1; }
test -f "$jetbrains" || { echo "FAIL: bundled JetBrains Mono font is missing" >&2; exit 1; }
require '<string>Manrope-Variable.ttf</string>' "$plist" "Info.plist must register Manrope"
require '<string>JetBrainsMono-Variable.ttf</string>' "$plist" "Info.plist must register JetBrains Mono"
require 'Manrope-Variable.ttf in Resources' "$project" "app target must bundle Manrope"
require 'JetBrainsMono-Variable.ttf in Resources' "$project" "app target must bundle JetBrains Mono"
require 'Manrope-OFL.txt in Resources' "$project" "app target must bundle the Manrope license"
require 'JetBrainsMono-OFL.txt in Resources' "$project" "app target must bundle the JetBrains Mono license"

for sheet_contract in \
  'func westreemAdaptiveSheet(' \
  'detents: Set<PresentationDetent>' \
  '.presentationDetents(detents)' \
  '.presentationDragIndicator(.visible)' \
  '.presentationCornerRadius(WestreemTokens.Radius.sheet)' \
  '.presentationBackground(WestreemTokens.Palette.ink900)' \
  '.interactiveDismissDisabled(!dismissible)'; do
  require "$sheet_contract" "$tokens" "missing Design System 04-D sheet contract: $sheet_contract"
done

test "$(shasum -a 256 "$manrope" | awk '{print $1}')" = "d0639be45d0af36e798172419d7bd173c4bd4f29e2b76cbb69db1d11bf8b0a40" || {
  echo "FAIL: bundled Manrope asset differs from the approved source" >&2
  exit 1
}
test "$(shasum -a 256 "$jetbrains" | awk '{print $1}')" = "48715a42ec242c21e9f02692891e147d022299a52e48d5e413e1a942193ffeda" || {
  echo "FAIL: bundled JetBrains Mono asset differs from the approved source" >&2
  exit 1
}

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
