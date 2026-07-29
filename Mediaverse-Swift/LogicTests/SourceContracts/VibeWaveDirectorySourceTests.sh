#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
view="$repo_dir/Social/Vibes/SocialDestinationViews.swift"
card="$repo_dir/Social/Ripples/RippleCard.swift"

assert_contains() {
  needle=$1
  file=$2
  message=$3
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $message"
    return 1
  fi
}

failures=0

assert_contains 'private var isCompactCommunityDirectory: Bool' "$view" \
  "Compact community Vibes must have a directory-first state." || failures=$((failures + 1))
assert_contains 'detail?.club.isPersonal == false' "$view" \
  "Personal Atmospheres must be excluded from the community directory flow." || failures=$((failures + 1))
assert_contains 'horizontalSizeClass != .compact' "$view" \
  "The existing iPad Wave presentation must remain available." || failures=$((failures + 1))
assert_contains 'mobileWaveDirectoryRow(' "$view" \
  "Vibe Home and Waves must reuse the information-rich directory row." || failures=$((failures + 1))
assert_contains 'waveDirectoryPreviews[wave.slug]' "$view" \
  "Wave rows must display additive activity and unread preview data." || failures=$((failures + 1))
assert_contains 'specializedLabel: waveTypeLabel(wave.type)' "$view" \
  "Specialized Wave behavior must be visible in the directory." || failures=$((failures + 1))
assert_contains 'private func openDedicatedWave(_ waveSlug: String) async' "$view" \
  "Wave selection must open a dedicated conversation state." || failures=$((failures + 1))
assert_contains 'returnToWaveDirectory()' "$view" \
  "Dedicated Wave conversations must provide back navigation." || failures=$((failures + 1))
assert_contains 'composerDestination(for: detail)' "$view" \
  "Dedicated Wave composition must reuse the capability-aware adaptive composer." || failures=$((failures + 1))
assert_contains 'selectedWave?.capabilities.canPost ?? detail.capabilities.canPost' "$view" \
  "Posting permissions must remain server capability driven." || failures=$((failures + 1))
assert_contains 'initialWaveSlug' "$view" \
  "Canonical Wave deep links must continue selecting their destination." || failures=$((failures + 1))
assert_contains 'presentation: detail.club.isPersonal ? .social : .waveConversation' "$view" \
  "Community Wave cards must retain the contextual conversation presentation." || failures=$((failures + 1))
assert_contains 'ripple.conversationSummary?.unreadCount' "$card" \
  "Directory activity must share the normalized conversation contract used by cards." || failures=$((failures + 1))

if [ "$failures" -ne 0 ]; then
  echo "$failures native Vibe Wave-directory source contract(s) failed."
  exit 1
fi

echo "Native Vibe Wave-directory source contracts passed."
