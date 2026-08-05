#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
source_file="$root/Views/Profile/WestreemIrreversibleConfirmation.swift"

test -f "$source_file"
grep -Fq 'westreem-irreversible-confirmation-26-h' "$source_file"
grep -Fq 'THIS WILL REMOVE' "$source_file"
grep -Fq 'THIS WILL STAY' "$source_file"
grep -Fq 'let removes: [String]' "$source_file"
grep -Fq 'let keeps: [String]' "$source_file"
grep -Fq '.westreemAdaptiveSheet(detents: [.medium, .large], dismissible: !busy)' "$source_file"
grep -Fq 'WestreemTokens.Palette.pink' "$source_file"
grep -Fq 'WestreemTokens.Palette.pinkOn' "$source_file"
grep -Fq 'let onConfirm: @MainActor () -> Void' "$source_file"
grep -Fq 'let onCancel: @MainActor () -> Void' "$source_file"

cancel_line="$(grep -n 'Button(value.cancelLabel)' "$source_file" | cut -d: -f1)"
confirm_line="$(grep -n 'Button { onConfirm() }' "$source_file" | cut -d: -f1)"
test "$cancel_line" -lt "$confirm_line"

if grep -Eq 'URLSession|APIClient|fetch\(' "$source_file"; then
  echo "Irreversible confirmation must keep authority injected" >&2
  exit 1
fi

echo "WestreemIrreversibleConfirmationSourceTests: PASS"
