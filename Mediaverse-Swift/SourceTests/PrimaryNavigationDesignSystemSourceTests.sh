#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
main="$root/Views/MainTabView.swift"

grep -q 'Root page container: Vibes · Videos · Shorts · Discover' "$main"
grep -q 'bottomTabButton(.myVibes, title: vibesTabTitle' "$main"
grep -q 'bottomTabButton(.videos, title: "Videos"' "$main"
grep -q 'bottomTabButton(.shorts, title: "Shorts"' "$main"
grep -q 'bottomTabButton(.explore, title: "Discover"' "$main"
grep -q 'let available: \[AppTab\] = \[.myVibes, .videos, .shorts, .explore\]' "$main"

if grep -q 'if platformConfig.isEnabled("vibes", aspect: .nav)' "$main" \
    || grep -q 'if platformConfig.isEnabled("videos", aspect: .nav)' "$main" \
    || grep -q 'if platformConfig.isEnabled("shorts", aspect: .nav)' "$main"; then
  echo "Design System 04-A destinations must not disappear behind feature flags" >&2
  exit 1
fi

echo "Primary navigation Design System source contract passed"
