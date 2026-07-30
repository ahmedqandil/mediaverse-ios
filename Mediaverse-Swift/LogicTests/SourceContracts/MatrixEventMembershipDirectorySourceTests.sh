#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
views="$root/Social/Events/VibeEventsViews.swift"
api="$root/Services/APIClient.swift"

for required in \
  'case myVibes = "my-vibes"' \
  'case .myVibes: "From Your Vibes"' \
  'try await joinedMatrixSpaceIDs()' \
  'matrixSession.vibes().spaces' \
  '.filter { $0.membership == .joined }' \
  'matrixSpaceIDs: matrixSpaceIDs'; do
  grep -Fq "$required" "$views" || {
    echo "Swift Event directory is missing Matrix membership behavior: $required" >&2
    exit 1
  }
done

for required in \
  'matrixSpaceIDs: [String] = []' \
  'Array(Set(matrixSpaceIDs)).prefix(100)' \
  'URLQueryItem(name: "matrixSpaceId", value: matrixSpaceID)'; do
  grep -Fq "$required" "$api" || {
    echo "Swift Event request is missing bounded Matrix Space filtering: $required" >&2
    exit 1
  }
done

if grep -Eq 'fetchManagedCommunityVibes|/api/fan-clubs' "$views"; then
  echo "Swift From Your Vibes must not derive membership from legacy Fan Clubs." >&2
  exit 1
fi

echo "Swift Matrix Event membership directory source contract passed"
