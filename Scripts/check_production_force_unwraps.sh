#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

production_paths=(
  Sources/InnoNetwork
  Sources/InnoNetworkMacros
  Sources/InnoNetworkAuthAWS
  Sources/InnoNetworkDownload
  Sources/InnoNetworkUpload
  Sources/InnoNetworkOpenAPI
  Sources/InnoNetworkPersistentCache
  Sources/InnoNetworkTrust
  Sources/InnoNetworkWebSocket
)

pattern='[A-Za-z0-9_)\]}]!(?![=A-Za-z0-9_])'
temp_matches="$(mktemp)"
trap 'rm -f "$temp_matches"' EXIT

if command -v rg > /dev/null 2>&1 && rg --pcre2-version > /dev/null 2>&1; then
  rg_status=0
  rg -n --pcre2 --glob '*.swift' "$pattern" "${production_paths[@]}" > "$temp_matches" || rg_status=$?
  if [[ "$rg_status" -gt 1 ]]; then
    exit "$rg_status"
  fi
else
  find "${production_paths[@]}" -name '*.swift' -type f \
    -exec perl -ne 'print "$ARGV:$.:$_" if /[A-Za-z0-9_)\]}]!(?![=A-Za-z0-9_])/; close ARGV if eof' {} + \
    > "$temp_matches"
fi

if [[ -s "$temp_matches" ]]; then
  echo "Found force unwrap-like expressions in production sources:"
  cat "$temp_matches"
  exit 1
fi
