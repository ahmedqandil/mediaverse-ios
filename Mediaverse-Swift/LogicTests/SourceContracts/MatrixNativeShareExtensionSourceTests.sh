#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
share="$root/ShareExtension/ShareViewController.swift"

for expected in \
  'api/matrix/native-share/destinations' \
  '/api/matrix/native-share/send' \
  'roomId' \
  'clientRequestId' \
  'IMAGE_REFERENCE' \
  'ShareWestreemEntity' \
  'westreem.sessionJWT' \
  '700_000'; do
  grep -q "$expected" "$share" || {
    echo "Matrix-native Share Extension is missing: $expected" >&2
    exit 1
  }
done

if grep -Eq \
  'LegacySocialAPIAdapter|MatrixWaveClient|/api/fan-clubs|/api/fan-club-posts|MATRIX_ACCESS_TOKEN|matrixAccessToken|matrixRefreshToken' \
  "$share"; then
  echo "Share Extension must not use a legacy Vibe authority or receive Matrix credentials." >&2
  exit 1
fi

grep -q 'selected = selected.intersection' "$share"
grep -q 'publishError = error.localizedDescription' "$share"
grep -q 'Task.sleep(for: .milliseconds(300))' "$share"

echo "Matrix-native scoped Share Extension source contract passed"
