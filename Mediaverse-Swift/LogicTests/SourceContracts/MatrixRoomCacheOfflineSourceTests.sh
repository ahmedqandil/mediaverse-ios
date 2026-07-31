#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
coordinator="$root/Services/MatrixSessionCoordinator.swift"
keychain="$root/Services/MatrixSessionKeychain.swift"
foundation="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
media="$root/Social/Vibes/MatrixNativeMediaCache.swift"

require() {
  file="$1"; needle="$2"; message="$3"
  if ! grep -Fq "$needle" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require "$keychain" 'SHA256.hash(data: Data(identity.matrixUserID.utf8))' 'native store directory must be isolated by immutable Matrix identity'
require "$keychain" 'kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly' 'store passphrase must remain device-bound in Keychain'
require "$keychain" 'FileProtectionType.completeUntilFirstUserAuthentication' 'native store files must use iOS data protection'
require "$coordinator" '.passphrase(passphrase: try keychain.storePassphrase())' 'Rust SQLite must be encrypted with the device-bound passphrase'
require "$coordinator" 'clearMetadataCaches()' 'account reconciliation must clear all in-memory metadata'
require "$coordinator" '"\(currentWestreemUserID ?? "anonymous")::\(roomID)"' 'memory timelines must remain account scoped'
require "$foundation" 'let handle = try await timeline.send(msg: message)' 'offline text sends must use the Matrix SDK durable send queue'
require "$foundation" 'represented as successfully queued offline until the SDK exposes a' 'unsupported raw-event queueing must not claim success'
require "$media" 'if runningCount <= maxEntries && runningBytes <= byteBudget { break }' 'native media cache must enforce both count and byte budgets'

echo "PASS: Matrix native room cache isolation, encryption, queue and eviction contracts"
