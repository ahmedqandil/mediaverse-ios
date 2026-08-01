#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"

FILES="
$ROOT/Views/Profile/NotificationsView.swift
$ROOT/Social/Ripples/EchoVibeSheet.swift
$ROOT/Social/Ripples/IncomingShareSheet.swift
$ROOT/Social/Vibes/MatrixNativeDirectNotificationViews.swift
$ROOT/Social/Vibes/MatrixNativeMediaFoundation.swift
$ROOT/Social/Vibes/MatrixNativeMediaViews.swift
$ROOT/Social/Vibes/MatrixNativeRtcRoomView.swift
$ROOT/Social/Vibes/MatrixNativeVibesViews.swift
"

# Matrix remains the internal protocol and SDK, but it must not leak into
# customer-facing string literals. Interpolated MatrixNative* type names do not
# render as branding and are intentionally excluded.
matches="$(
  grep -Ein '"[^"]*matrix[^"]*"' $FILES 2>/dev/null \
    | grep -v '\\(MatrixNative' \
    | grep -v 'sourceType: "MATRIX_EVENT"' \
    | grep -v '\.accessibilityIdentifier(' \
    | grep -v '\.appendingPathComponent(' \
    || true
)"

if [ -n "$matches" ]; then
  echo "FAIL: protocol branding leaked into customer-facing Swift copy"
  echo "$matches"
  exit 1
fi

echo "WeStreem Vibes branding source contract passed"
