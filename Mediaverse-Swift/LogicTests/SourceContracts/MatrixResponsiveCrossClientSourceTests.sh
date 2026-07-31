#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
view="$root/Social/Vibes/MatrixNativeVibesViews.swift"
compat="$root/Social/Contracts/MatrixCrossClientCompatibility.swift"

grep -Fq '@Environment(\.horizontalSizeClass) private var horizontalSizeClass' "$view"
grep -Fq 'if horizontalSizeClass == .regular' "$view"
grep -Fq 'NavigationSplitView {' "$view"
grep -Fq 'List(selection: Binding<VibesSection?>(' "$view"
grep -Fq 'if let next { selectedSection = next }' "$view"
grep -Fq 'private var compactWidthContent' "$view"
grep -Fq 'private var selectedSectionContent' "$view"
grep -Fq '.navigationDestination(item: $routedRoom)' "$view"

grep -Fq '"com.westreem.public_sharing.v1"' "$compat"
grep -Fq 'host == "matrix.to"' "$compat"
grep -Fq '["westreem.com", "www.westreem.com"].contains(host)' "$compat"

echo "Matrix responsive and cross-client source contracts passed"
