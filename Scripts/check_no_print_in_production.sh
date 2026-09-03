#!/usr/bin/env bash
# Forbids `print(` calls in shipping library targets.
#
# print() in production code is almost always a leftover debug
# statement that escapes review and ships to App Store builds where
# it pollutes Console.app and exfiltrates state. Operational logging
# should go through `NetworkLogger` / `OSLogNetworkEventObserver`
# instead.
#
# Excluded from the check:
#   - Tests / SmokeTests / Examples / Benchmarks: print() is allowed
#     for human-readable diagnostics in CLI smoke targets.
#   - DocC tutorial resources (Sources/**/.docc/Resources/*.swift):
#     these are example snippets surfaced to the reader, not shipped
#     code paths.
#   - InnoNetworkTestSupport: shipped to consumer test targets only;
#     not part of any production binary.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

production_paths=(
    "$repo_root/Sources/InnoNetwork"
    "$repo_root/Sources/InnoNetworkMacros"
    "$repo_root/Sources/InnoNetworkDownload"
    "$repo_root/Sources/InnoNetworkUpload"
    "$repo_root/Sources/InnoNetworkPersistentCache"
    "$repo_root/Sources/InnoNetworkWebSocket"
)

violations="$(mktemp)"
trap 'rm -f "$violations"' EXIT

for path in "${production_paths[@]}"; do
    if [[ ! -d "$path" ]]; then continue; fi

    while IFS= read -r -d '' file; do
        # Skip DocC tutorial resource snippets — they live under
        # `*.docc/Resources/` and are surfaced as example code in
        # tutorials, not part of any compile target's shipped code.
        case "$file" in
            *.docc/Resources/*) continue ;;
        esac

        # Match `print(` after a word boundary, ignoring matches
        # inside line comments. Block comments / string literals
        # containing `print(` are rare in this codebase and would
        # surface as false positives, which is acceptable — strip
        # them by review when they appear.
        if grep -nE '(^|[^A-Za-z0-9_.])print[[:space:]]*\(' "$file" \
            | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' >> "$violations"; then
            :
        fi
    done < <(find "$path" -name '*.swift' -type f -print0)
done

if [[ -s "$violations" ]]; then
    echo "::error::print() detected in production sources"
    cat "$violations"
    exit 1
fi

echo "✅ No print() calls in production sources."
