#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
contract="$root/Social/Contracts/MatrixSessionFoundation.swift"
session="$root/Services/MatrixSessionCoordinator.swift"

grep -q 'enum MatrixNativeSessionAuthMode' "$contract"
grep -q 'case sso = "SSO"' "$contract"
grep -q 'case brokerFallback = "BROKER_FALLBACK"' "$contract"
grep -q 'authMode == .sso' "$contract"
grep -q 'guard redirectURL == nil, idpID == nil' "$contract"

grep -q 'func startNegotiated(' "$session"
grep -q 'switch authMode' "$session"
grep -q 'case .sso:' "$session"
grep -q 'case .brokerFallback:' "$session"
grep -q 'expectedHomeserverURL: bootstrap.homeserverURL' "$session"
grep -q 'guard bootstrap.authMode == .sso' "$session"
grep -q 'normalizedApprovedOrigin(brokered.homeserverURL)' "$session"
grep -q 'refreshToken: brokered.refreshToken' "$session"
grep -q 'restored.refreshToken?' "$session"

reconcile="$(
  sed -n '/func reconcile(westreemUserID:/,/private func beginCryptoMaintenance/p' \
    "$session"
)"
printf '%s\n' "$reconcile" | grep -q 'coordinator.startNegotiated'
if printf '%s\n' "$reconcile" | grep -q 'coordinator.startSSO'; then
  echo "Production reconcile must use the negotiated authentication mode" >&2
  exit 1
fi

echo "Matrix server-negotiated native authentication source contract passed"
