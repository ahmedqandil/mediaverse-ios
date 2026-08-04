#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
push="$root/Services/PushNotificationManager.swift"
app="$root/Utilities/UIKitHelpers.swift"

restore_body="$(sed -n '/func westreemDidRestoreAuthenticatedSession/,/^    }/p' "$push")"
cancel_line="$(printf '%s\n' "$restore_body" | grep -nF 'uploads.forEach { $0.cancel() }' | cut -d: -f1)"
owner_line="$(printf '%s\n' "$restore_body" | grep -nF 'activeWestreemUserID = westreemUserID' | cut -d: -f1)"
replay_line="$(printf '%s\n' "$restore_body" | grep -nF 'refreshVoIPRegistrationIfAvailable()' | cut -d: -f1)"
test -n "$cancel_line" -a -n "$owner_line" -a -n "$replay_line"
test "$cancel_line" -lt "$owner_line"
test "$owner_line" -lt "$replay_line"
printf '%s\n' "$restore_body" | grep -Fq 'for upload in uploads { await upload.value }'
printf '%s\n' "$restore_body" | grep -Fq 'voIPUploadTask = nil'
printf '%s\n' "$restore_body" | grep -Fq 'await uploadLatestVoIPTokenIfPossible()'

tap_body="$(sed -n '/func handleNotificationTap/,/^    }/p' "$push")"
printf '%s\n' "$tap_body" | grep -Fq 'matrix_call_fallback'
printf '%s\n' "$tap_body" | grep -Fq 'presentNotificationFallback(userInfo: userInfo)'
printf '%s\n' "$tap_body" | grep -Fq 'MatrixNativePushRouteStore.shared.stage(matrixRoute)'

fallback_body="$(sed -n '/func presentNotificationFallback/,/^    }/p' "$app")"
printf '%s\n' "$fallback_body" | grep -Fq 'userInfo["kind"] as? String == "matrix_call_fallback"'
printf '%s\n' "$fallback_body" | grep -Fq 'MatrixNativeRtcInvitationExpiryContract.accepts('
printf '%s\n' "$fallback_body" | grep -Fq 'MatrixNativeIncomingCallRuntime.shared.canAcceptCalls'
printf '%s\n' "$fallback_body" | grep -Fq '!isCallCancelled(uuid)'
printf '%s\n' "$fallback_body" | grep -Fq 'if calls[uuid] != nil { return true }'
printf '%s\n' "$fallback_body" | grep -Fq 'redemptionID: UUID()'
printf '%s\n' "$fallback_body" | grep -Fq 'provider.reportNewIncomingCall'
printf '%s\n' "$fallback_body" | grep -Fq 'calls.removeValue(forKey: uuid)'
if printf '%s\n' "$fallback_body" | grep -Fq 'startOutgoing('; then
  echo "ordinary notification fallback must never start an outgoing call" >&2
  exit 1
fi

cancel_body="$(sed -n '/func handleNotificationCancellation/,/^    }/p' "$app")"
printf '%s\n' "$cancel_body" | grep -Fq 'userInfo["kind"] as? String == "matrix_call_cancel"'
printf '%s\n' "$cancel_body" | grep -Fq 'rememberCancelledCall(uuid)'
printf '%s\n' "$cancel_body" | grep -Fq 'center.deliveredNotifications()'
printf '%s\n' "$cancel_body" | grep -Fq 'removeDeliveredNotifications(withIdentifiers: fallbackIdentifiers)'
printf '%s\n' "$cancel_body" | grep -Fq 'call.roomID == roomID'
printf '%s\n' "$cancel_body" | grep -Fq 'MatrixNativeIncomingCallRuntime.shared.end('
printf '%s\n' "$cancel_body" | grep -Fq 'reason: .remoteEnded'

grep -Fq 'didReceiveRemoteNotification userInfo' "$app"
grep -Fq 'handleNotificationCancellation(userInfo: userInfo)' "$app"
grep -Fq 'shouldSuppressOrdinaryCallPresentation' "$app"
grep -Fq 'return isCallCancelled(uuid) || calls[uuid] != nil' "$app"
grep -Fq 'UserDefaults.standard.set(' "$app"
grep -Fq 'cancelledCallsDefaultsKey' "$app"
grep -Fq 'if suppress { return [] }' "$app"

echo "Matrix RTC notification fallback source contract: PASS"
