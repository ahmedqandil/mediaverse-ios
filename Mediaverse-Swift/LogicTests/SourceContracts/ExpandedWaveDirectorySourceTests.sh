#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
views="$repo_dir/Social/Vibes/SocialDestinationViews.swift"
models="$repo_dir/Social/Contracts/SocialModels.swift"
routes="$repo_dir/Navigation/AppRoute.swift"
decoding="$repo_dir/LogicTests/MediaverseSocialContractsTests/SocialContractDecodingTests.swift"

assert_contains() {
  needle=$1
  file=$2
  message=$3
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $message"
    return 1
  fi
}

assert_matches() {
  expression=$1
  file=$2
  message=$3
  if ! grep -Eq -- "$expression" "$file"; then
    echo "FAIL: $message"
    return 1
  fi
}

failures=0

assert_contains 'title: "Vibe Home"' "$views" \
  "Vibe Home must remain a first-class directory destination." || failures=$((failures + 1))
assert_matches 'Section\("(All Waves|Conversation spaces)' "$views" \
  "The complete accessible Wave directory must remain available." || failures=$((failures + 1))

assert_contains 'unreadCount' "$models" \
  "Native Wave rows must decode server-owned unread activity." || failures=$((failures + 1))
assert_contains 'lastActivityAt' "$models" \
  "Native Wave rows must decode last visible activity." || failures=$((failures + 1))
assert_matches '(rippleCount|postCount)' "$models" \
  "Native Wave rows must decode canonical Ripple counts." || failures=$((failures + 1))
assert_matches '(participant|lastActivityLabel)' "$models" \
  "Native Wave rows must decode a safe activity preview." || failures=$((failures + 1))

assert_contains 'wave.unreadCount' "$views" \
  "Rich native rows must render unread state." || failures=$((failures + 1))
assert_contains 'wave.lastActivityAt' "$views" \
  "Rich native rows must render activity context." || failures=$((failures + 1))
assert_matches '(requiresPostApproval|Approval required)' "$views" \
  "Rich rows must expose approval restrictions." || failures=$((failures + 1))
assert_contains 'wave.visibility' "$views" \
  "Rich rows must expose restricted visibility without granting access." || failures=$((failures + 1))
assert_contains 'waveSystemImage(wave)' "$views" \
  "Specialized Wave identity must use the established icon mapping." || failures=$((failures + 1))

assert_contains 'initialWaveSlug' "$views" \
  "Canonical Wave deep links must restore the selected destination." || failures=$((failures + 1))
assert_contains 'switchWave(to:' "$views" \
  "Directory selection must navigate to one dedicated Wave feed." || failures=$((failures + 1))
assert_contains 'case vibeWave' "$routes" \
  "Native routing must preserve Vibe and Wave identity." || failures=$((failures + 1))

assert_contains 'selectedWave?.capabilities.canPost' "$views" \
  "The adaptive composer must remain capability-gated." || failures=$((failures + 1))
assert_contains 'composerDestination(for:' "$views" \
  "The composer must receive the selected Wave contract." || failures=$((failures + 1))
assert_contains 'selectedWave?.type == .resources' "$views" \
  "Resource-specific behavior must remain scoped to Resource Waves." || failures=$((failures + 1))
assert_contains 'selectedWave?.type == .events' "$views" \
  "Event creation must remain scoped to Events Waves." || failures=$((failures + 1))

assert_contains '@Environment(\.horizontalSizeClass)' "$views" \
  "Expanded mobile presentation must preserve iPad width behavior." || failures=$((failures + 1))
assert_contains 'horizontalSizeClass == .compact ? 0 : C.pagePad' "$views" \
  "Ripple width must remain edge-to-edge only on compact devices." || failures=$((failures + 1))
assert_contains '.presentationDetents([.medium, .large])' "$views" \
  "The mobile directory must remain an expandable sheet." || failures=$((failures + 1))

assert_contains 'testCanonicalCommentPreviewDerivesLegacyUserIDFromEmbeddedIdentity' "$decoding" \
  "Production comment previews without redundant userId must remain covered." || failures=$((failures + 1))
assert_contains 'testWaveRippleDecodesNormalizedConversationSummaryAndBoundsPresentationData' "$decoding" \
  "Additive summary decoding must remain feed-safe." || failures=$((failures + 1))
assert_contains 'decodeIfPresent([Ripple].self, forKey: .posts) ?? []' "$models" \
  "Missing posts must retain the safe empty-page fallback." || failures=$((failures + 1))

if [ "$failures" -ne 0 ]; then
  echo "$failures expanded Wave directory source contract(s) failed."
  exit 1
fi

echo "Expanded Wave directory source contracts passed."
