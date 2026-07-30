#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
features="$root/Social/Contracts/SocialFeatureConfiguration.swift"
session="$root/Services/MatrixSessionCoordinator.swift"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"

require() {
  grep -Fq -- "$1" "$2" || {
    echo "FAIL: $3" >&2
    exit 1
  }
}

require 'matrixNativeVibesEnabled: true' "$features" \
  "Production Vibes must not be disabled by a stale device preference."
require 'func retryConnection() async' "$session" \
  "A failed native session must expose an explicit retry."
require 'guard offered.enabled, offered.ownershipVersion == 2 else {' "$session" \
  "A server-disabled bootstrap must map to rollout state before config validation."
require 'await reconcile(westreemUserID: currentWestreemUserID)' "$session" \
  "Retry must rerun the server-negotiated bootstrap for the current identity."
require 'guard isReady else {' "$session" \
  "Matrix operations must gate on live SDK readiness."
require 'throw MatrixSessionFoundationError.unavailable' "$session" \
  "A disconnected SDK must not be reported as an account rollout denial."
require 'identity.verifies(matrixUserID: restored.userId)' "$session" \
  "Persisted Matrix sessions must match the current canonical Westreem user."
require 'keychain.removeSession()' "$session" \
  "A stale persisted identity must be removable before re-brokering."
require 'retry: {' "$view" \
  "The Vibes root failure state must expose retry."
require 'matrixSession.retryConnection()' "$view" \
  "The Vibes UI must invoke native session recovery."
require '&& matrixSession.isReady' "$view" \
  "Create Vibe must be enabled by live Matrix readiness."
require 'Reconnect to Vibes' "$view" \
  "An already-open creator must offer connection recovery."

if grep -Fq 'Vibes is not enabled for this account and device.' "$view"; then
  echo "FAIL: Temporary session failure must not be presented as account denial." >&2
  exit 1
fi

echo "Matrix native production recovery source contract passed"
