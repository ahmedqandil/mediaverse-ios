#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
push="$root/Services/PushNotificationManager.swift"
client="$root/Services/APIClient.swift"
matrix="$root/Services/MatrixSessionCoordinator.swift"
auth="$root/Services/AuthManager.swift"

grep -Fq 'authority == "MATRIX_PUSHER_API"' "$push"
grep -Fq 'eventFormat == "event_id_only"' "$push"
grep -Fq 'canonicalReadAuthority == "MATRIX_RECEIPT"' "$push"
grep -Fq '!storesNotificationContent' "$push"
grep -Fq 'C.isTrustedBackendURL(gateway)' "$push"
grep -Fq 'func installMatrixPusherManager' "$push"
grep -Fq 'func matrixSessionDidBecomeReady()' "$push"
grep -Fq 'func unregisterForSignOut() async' "$push"
grep -Fq 'APIClient.shared.unregisterPushToken' "$push"

grep -Fq 'func registerPushToken(' "$client"
grep -Fq 'PushTokenRegistrationResponse' "$client"
grep -Fq 'func unregisterPushToken(' "$client"
grep -Fq 'PushTokenRemovalResponse' "$client"

grep -Fq 'try await client.setPusher(' "$matrix"
grep -Fq 'format: .eventIdOnly' "$matrix"
grep -Fq 'try await client.deletePusher(' "$matrix"
grep -Fq 'PusherIdentifiers(' "$matrix"
grep -Fq 'PushNotificationManager.shared.matrixSessionDidBecomeReady()' "$matrix"
grep -Fq 'MatrixNativePusherManaging' "$matrix"

grep -Fq 'await PushNotificationManager.shared.unregisterForSignOut()' "$auth"

if grep -Eq 'NotificationRecord|prisma|devicePushToken' "$push" "$matrix"; then
  echo "Swift attempted to duplicate Matrix push authority" >&2
  exit 1
fi

echo "Matrix native pusher source contract passed"
