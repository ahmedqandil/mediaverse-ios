#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
COORDINATOR="$ROOT/Services/MatrixSessionCoordinator.swift"
CRYPTO="$ROOT/Services/MatrixNativeCryptoFoundation.swift"
REPOSITORY="$ROOT/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
DIRECT="$ROOT/Social/Vibes/MatrixNativeDirectNotificationFoundation.swift"
DIRECT_VIEW="$ROOT/Social/Vibes/MatrixNativeDirectNotificationViews.swift"
PROJECT="$ROOT/Mediaverse.xcodeproj/project.pbxproj"

grep -q 'MatrixHomeserverTrustPolicy.accepts' "$COORDINATOR"
grep -q 'client.encryption()' "$CRYPTO"
grep -q 'maintainCryptoLifecycle' "$CRYPTO"
grep -q 'applicationE2eeDisabled' "$CRYPTO"
grep -q 'deviceEnumerationUnavailable' "$CRYPTO"
grep -q 'permitsHandWrittenDeviceAPI = false' "$ROOT/Social/Contracts/MatrixCryptoSecurityContract.swift"

grep -q 'getMediaContent(mediaSource: source)' "$REPOSITORY"
grep -q 'isEncrypted: false' "$REPOSITORY"
grep -q 'isEncrypted: false' "$DIRECT"
if grep -q 'requireCryptoReadyForEncryptedAction' "$DIRECT"; then
  echo "Direct messages must not require application E2EE readiness" >&2
  exit 1
fi
if sed -n '/func mediaData(/,/func setTyping/p' "$REPOSITORY" | grep -q 'encryptedMediaUnavailable'; then
  echo "Encrypted Matrix media must be delegated to MatrixRustSDK" >&2
  exit 1
fi
if sed -n '/private func performAttachmentSend(/,/private func performPollSend/p' "$REPOSITORY" | grep -q 'encryptedMediaUnavailable'; then
  echo "Encrypted Matrix uploads must be delegated to MatrixRustSDK timeline APIs" >&2
  exit 1
fi

if grep -q 'MatrixNativeCryptoSecurityView.swift in Sources' "$PROJECT"; then
  echo "Crypto security UI must not be compiled into the app" >&2
  exit 1
fi
if grep -Eq 'enableRecovery\(|recoverAndFixBackup|enableBackups\(|resetRecoveryKey\(|requestDeviceVerification\(' "$CRYPTO"; then
  echo "Application E2EE key lifecycle calls must remain disabled" >&2
  exit 1
fi
if grep -q 'beginCryptoMaintenance' "$COORDINATOR"; then
  echo "Automatic crypto maintenance must remain disabled" >&2
  exit 1
fi
if grep -q 'showsSecuritySetup' "$DIRECT_VIEW"; then
  echo "Direct-message crypto setup UI must remain disabled" >&2
  exit 1
fi

if sed '/^[[:space:]]*\/\//d' "$CRYPTO" "$DIRECT_VIEW" \
    | grep -Eq 'URLSession|/_matrix/client|accessToken'; then
  echo "Crypto and recovery must not implement a parallel Matrix protocol client" >&2
  exit 1
fi

echo "Matrix native crypto security source contracts passed"
