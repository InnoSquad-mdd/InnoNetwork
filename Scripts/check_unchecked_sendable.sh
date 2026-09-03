#!/usr/bin/env bash
# Enforces the package's `@unchecked Sendable` policy.
#
# Two zones with different rules:
#
#   1. Production library and macro targets (Sources/InnoNetwork{,Macros,
#      AuthAWS,Download,PersistentCache,WebSocket,Trust,OpenAPI}) —
#      `@unchecked Sendable` is forbidden. Strict-concurrency static analysis
#      must succeed by construction; if a real escape hatch is needed, design
#      a proper actor or use the per-call locking primitives already in the
#      library, do not push the burden onto reviewers.
#
#   2. InnoNetworkTestSupport — `@unchecked Sendable` is allowed because
#      the target ships `package`-scoped helpers consumed only by the
#      package's own test targets (TestClock, FaultInjection, ...). The
#      gate still enforces *some* due diligence: any file declaring an
#      `@unchecked Sendable` type must also contain at least one doc
#      comment (`///`) so a reviewer can find the safety justification
#      without spelunking through git blame. This catches drive-by
#      additions where someone reaches for `@unchecked` without
#      explaining *why* the manual concurrency contract is sound.
#
# Replaces the previous inline check that lived in `.github/workflows/
# ci.yml` so the rule is reusable from `pre-commit` hooks and so future
# zones (Examples/, Tools/) can be added by editing this file rather
# than the workflow YAML.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

production_paths=(
    "Sources/InnoNetwork"
    "Sources/InnoNetworkMacros"
    "Sources/InnoNetworkAuthAWS"
    "Sources/InnoNetworkDownload"
    "Sources/InnoNetworkUpload"
    "Sources/InnoNetworkHLS"
    "Sources/InnoNetworkHLSLive"
    "Sources/InnoNetworkHLSAVFoundation"
    "Sources/InnoNetworkHLSAudio"
    "Sources/InnoNetworkPersistentCache"
    "Sources/InnoNetworkWebSocket"
    "Sources/InnoNetworkOpenAPI"
)

# InnoNetworkTrust is added when the trust split lands; tolerate it
# missing today so the script stays green on the current tree.
if [[ -d "Sources/InnoNetworkTrust" ]]; then
    production_paths+=("Sources/InnoNetworkTrust")
fi

test_support_path="Sources/InnoNetworkTestSupport"

violations="$(mktemp)"
trap 'rm -f "$violations"' EXIT

# --- Zone 1: production targets - hard fail on any @unchecked Sendable

for path in "${production_paths[@]}"; do
    if [[ ! -d "$path" ]]; then continue; fi

    if command -v rg > /dev/null 2>&1; then
        rg -n "@unchecked Sendable" "$path" >> "$violations" || true
    else
        grep -R -n "@unchecked Sendable" "$path" >> "$violations" || true
    fi
done

if [[ -s "$violations" ]]; then
    echo "::error::@unchecked Sendable detected in production sources"
    cat "$violations"
    exit 1
fi

# --- Zone 2: InnoNetworkTestSupport - require at least one doc comment in
#     any file that uses @unchecked Sendable, so a justification is
#     reachable from the file alone.

if [[ -d "$test_support_path" ]]; then
    while IFS= read -r -d '' file; do
        if ! grep -qE "@unchecked Sendable" "$file"; then
            continue
        fi

        if ! grep -qE '^[[:space:]]*///' "$file"; then
            echo "::error::$file uses @unchecked Sendable but has no doc comment (///) explaining the manual Sendable contract."
            echo "  Add a triple-slash doc comment above the type explaining why the type's mutable state is serialized safely."
            exit 1
        fi
    done < <(find "$test_support_path" -name '*.swift' -type f -print0)
fi

echo "✅ @unchecked Sendable policy holds (production: forbidden, TestSupport: doc-justified)."
