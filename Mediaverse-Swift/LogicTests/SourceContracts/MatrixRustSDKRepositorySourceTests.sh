#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
REPOSITORY="$ROOT/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
PLAN="$ROOT/Social/Contracts/MatrixCapabilityPlan.swift"
SESSION="$ROOT/Services/MatrixSessionCoordinator.swift"
KEYCHAIN="$ROOT/Services/MatrixSessionKeychain.swift"
LEGACY="$ROOT/Social/Contracts/LegacySocialAPIAdapter.swift"
LEGACY_MATRIX="$ROOT/Social/Contracts/SocialRealtimeContracts.swift"

grep -q 'import MatrixRustSDK' "$REPOSITORY"
grep -q 'client.spaceService().topLevelJoinedSpaces()' "$REPOSITORY"
grep -q 'spaceRoomList(spaceId:' "$REPOSITORY"
grep -q 'room.timeline()' "$REPOSITORY"
grep -q 'room.sendRaw(eventType:' "$REPOSITORY"
grep -q 'timeline.send(msg:' "$REPOSITORY"
grep -q 'rollout.mayStartSDK' "$REPOSITORY"
grep -q 'syncService()' "$SESSION"
grep -q 'withOfflineMode()' "$SESSION"
grep -q 'enableAllSendQueues(enable:' "$SESSION"
grep -q 'SqliteStoreBuilder' "$SESSION"
grep -q 'kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly' "$KEYCHAIN"
grep -q 'LegacyCommunityWriteGuardTransport' "$LEGACY"
grep -q 'matrixNativeCommunityWriteRetired' "$LEGACY"
grep -q 'matrixNativeVibesEnabled else' "$LEGACY_MATRIX"
grep -q 'User strongest-model Matrix-native Vibes prompt (precedence 1)' "$PLAN"
grep -q 'qa/matrix-native-strongest-model-acceptance.json' "$PLAN"
grep -q 'permitsHandWrittenMatrixProtocolClient = false' "$PLAN"

if grep -Eq 'URLSession[(]|/_matrix/client|social(Post|Data)[(]' "$REPOSITORY"; then
  echo "Matrix Vibes repository must not implement the Matrix protocol or use legacy social APIs" >&2
  exit 1
fi

echo "MatrixRustSDK repository source contract passed"
