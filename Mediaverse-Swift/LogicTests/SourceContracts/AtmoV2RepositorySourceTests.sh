#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
contracts="$root/Social/Contracts/AtmoV2Contracts.swift"
client="$root/Services/APIClient.swift"
features="$root/Social/Contracts/SocialFeatureConfiguration.swift"
surface="$root/Social/Atmosphere/AtmoProfileViews.swift"

grep -Fq 'public static let value = "WESTREEM"' "$contracts"
grep -Fq 'public static let permitsMatrix = false' "$contracts"
grep -Fq 'public static let permitsLegacySocialAdapter = false' "$contracts"
grep -Fq '"/api/v2/atmo"' "$contracts"
grep -Fq 'public func profile(handle: String)' "$contracts"
grep -Fq '"/profiles/by-handle/' "$contracts"
grep -Fq '"/media/upload-url"' "$contracts"
grep -Fq 'public struct AtmoV2UploadTicket' "$contracts"
grep -Fq 'personalAtmoV2Enabled: Bool = false' "$features"
grep -Fq 'extension APIClient: AtmoV2Transport' "$client"
grep -Fq '.id(userID)' "$surface"
grep -Fq 'AtmoUnavailableSurface()' "$surface"
grep -Fq 'case .unavailable:' "$surface"
grep -Fq 'cutover = .unavailable' "$surface"
grep -Fq 'AtmoV2Composer(model: model)' "$surface"
grep -Fq 'AtmoV2CommentsPanel(post: post, model: model)' "$surface"
grep -Fq 'AtmoV2EnergySheet(post: post, model: model)' "$surface"
grep -Fq 'private struct AtmoV2ShareSheet: UIViewControllerRepresentable' "$surface"

if grep -Eq 'MatrixRustSDK|/_matrix/client|LegacySocialAPIAdapter' "$contracts"; then
  echo "Atmo v2 contract crossed a forbidden Matrix/legacy boundary" >&2
  exit 1
fi

if grep -Eq 'fallback: \{ LegacyAtmoProfileView|cutover = \.legacy|case \.legacy:' "$surface"; then
  echo "Personal Atmo can still reactivate the retired FanClub-backed profile" >&2
  exit 1
fi

if [ "$(grep -c 'LegacyAtmoProfileView(handle:' "$surface" || true)" -ne 0 ]; then
  echo "An active Personal Atmo route still renders the legacy profile" >&2
  exit 1
fi

echo "Atmo v2 repository source contract passed"
