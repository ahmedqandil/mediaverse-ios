#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
COORDINATOR="$ROOT/Services/MatrixSessionCoordinator.swift"
CRYPTO="$ROOT/Services/MatrixNativeCryptoFoundation.swift"
REPOSITORY="$ROOT/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
VIEW="$ROOT/Social/Vibes/MatrixNativeCryptoSecurityView.swift"
DIRECT="$ROOT/Social/Vibes/MatrixNativeDirectNotificationFoundation.swift"
DIRECT_VIEW="$ROOT/Social/Vibes/MatrixNativeDirectNotificationViews.swift"

grep -q 'MatrixHomeserverTrustPolicy.accepts' "$COORDINATOR"
grep -q 'client.encryption()' "$CRYPTO"
grep -q 'enableRecovery(' "$CRYPTO"
grep -q 'recoverAndFixBackup' "$CRYPTO"
grep -q 'maintainCryptoLifecycle' "$CRYPTO"
grep -q 'enableBackups()' "$CRYPTO"
grep -q 'waitForBackupUploadSteadyState' "$CRYPTO"
grep -q 'getSessionVerificationController' "$CRYPTO"
grep -q 'deviceEnumerationUnavailable' "$CRYPTO"
grep -q 'permitsHandWrittenDeviceAPI = false' "$ROOT/Social/Contracts/MatrixCryptoSecurityContract.swift"

grep -q 'getMediaContent(mediaSource: source)' "$REPOSITORY"
grep -q 'isEncrypted: creation.isEncrypted && !isSpace' "$REPOSITORY"
grep -q 'isEncrypted: true' "$DIRECT"
grep -q 'requireCryptoReadyForEncryptedAction' "$DIRECT"
if sed -n '/func mediaData(/,/func setTyping/p' "$REPOSITORY" | grep -q 'encryptedMediaUnavailable'; then
  echo "Encrypted Matrix media must be delegated to MatrixRustSDK" >&2
  exit 1
fi
if sed -n '/private func performAttachmentSend(/,/private func performPollSend/p' "$REPOSITORY" | grep -q 'encryptedMediaUnavailable'; then
  echo "Encrypted Matrix uploads must be delegated to MatrixRustSDK timeline APIs" >&2
  exit 1
fi

grep -q 'WeStreem does not store this key' "$VIEW"
grep -q 'requestDeviceVerification' "$VIEW"
grep -q 'approveVerification' "$VIEW"
grep -q 'I saved it — continue' "$VIEW"
grep -q '.localOnly: true' "$VIEW"
grep -q '.expirationDate: Date().addingTimeInterval(120)' "$VIEW"
grep -q 'UIPasteboard.general.string == generatedRecoveryKey' "$VIEW"
grep -q 'interactiveDismissDisabled(generatedRecoveryKey != nil)' "$VIEW"
grep -q 'showsSecuritySetup' "$DIRECT_VIEW"
grep -q 'autoEnableBackups(autoEnableBackups: true)' "$COORDINATOR"

if grep -Eq 'URLSession|/_matrix/client|accessToken' "$CRYPTO" "$VIEW" "$DIRECT_VIEW"; then
  echo "Crypto and recovery must not implement a parallel Matrix protocol client" >&2
  exit 1
fi

echo "Matrix native crypto security source contracts passed"
