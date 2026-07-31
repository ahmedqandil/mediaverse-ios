#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
repository="$root/Social/Vibes/MatrixVibesRepositoryFoundation.swift"
contract="$root/Social/Contracts/MatrixNativeVibesUIContract.swift"

require() {
  pattern="$1"
  file="$2"
  message="$3"
  if ! grep -Fq "$pattern" "$file"; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require 'PhotosPicker(selection: $avatarSelection, matching: .images)' "$view" \
  "creation must expose the native image picker"
require 'data.count <= MatrixNativeCreationContract.maximumAvatarBytes' "$view" \
  "selection must reject oversized avatars before creation"
require 'avatar: creationAvatar' "$view" \
  "the validated creation draft must carry the selected avatar"
require 'maximumAvatarBytes = 10 * 1_024 * 1_024' "$contract" \
  "creation avatars must have an explicit ten-megabyte ceiling"
require 'let avatarURI = try await uploadCreationAvatar(validated.avatar, client: client)' "$repository" \
  "both creation paths must upload the avatar before exposing a room identity"
count=$(grep -Fc 'let avatarURI = try await uploadCreationAvatar(validated.avatar, client: client)' "$repository")
if [ "$count" -ne 2 ]; then
  echo "FAIL: Vibe and Wave creation must both use the avatar upload boundary" >&2
  exit 1
fi
require 'avatar: avatarURI' "$repository" \
  "the validated MXC URI must be sent in native Matrix create-room parameters"
require '(try? MediaSource.fromUrl(url: mediaURI)) != nil' "$repository" \
  "an invalid homeserver media identity must fail closed"
require 'The Wave avatar is Matrix room profile metadata.' "$view" \
  "encrypted creation must explain that profile metadata is not message encryption"

echo "Matrix native creation avatar source contract passed."
