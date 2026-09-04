#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$repo_root/Scripts/run_local_release_preflight.sh"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-local-release-preflight-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/expected-fast.txt" <<'EOF'
release-script-fixtures
dependency-lock
static-contracts
documentation-smoke
consumer-examples
openapi-generator
bounded-tests
EOF

cat > "$work_dir/expected-full.txt" <<'EOF'
release-script-fixtures
dependency-lock
static-contracts
documentation-smoke
consumer-examples
openapi-generator
bounded-tests
runtime-coverage
macro-coverage
guarded-benchmarks
sbom-artifacts
all-product-docc
apple-platform-builds
EOF

bash "$runner" --fast --list > "$work_dir/actual-fast.txt"
bash "$runner" --full --list > "$work_dir/actual-full.txt"
diff -u "$work_dir/expected-fast.txt" "$work_dir/actual-fast.txt"
diff -u "$work_dir/expected-full.txt" "$work_dir/actual-full.txt"

bash "$runner" --help | grep -Fq -- '--full'
grep -Fq 'run_package_xcodebuild docbuild' "$runner"
grep -Fq 'prepare_package_xcodebuild_view' "$runner"
grep -Fq "grep -Eo 'Test run with [0-9]+ tests?'" \
  "$repo_root/Scripts/run_bounded_parallel_tests.sh"
grep -Fq 'swift package describe --type json' \
  "$repo_root/Scripts/run_bounded_parallel_tests.sh"
grep -Fq 'Ignoring stale test bundles not declared by the current Package.swift' \
  "$repo_root/Scripts/run_bounded_parallel_tests.sh"
summary_count="$({
  printf '%s\n' 'Test run with 1 test in 1 suite passed.'
  printf '%s\n' 'Test run with 2 tests in 1 suite passed.'
} | grep -Eo 'Test run with [0-9]+ tests?' \
  | awk '{ count += $4 } END { print count + 0 }')"
if [[ "$summary_count" -ne 3 ]]; then
  echo "Expected singular and plural Swift Testing summaries to total 3." >&2
  exit 1
fi

set +e
bash "$runner" --unknown > "$work_dir/unknown.stdout" 2> "$work_dir/unknown.stderr"
status=$?
set -e

if [[ "$status" -ne 64 ]]; then
  echo "Expected an unknown argument to exit 64; got $status." >&2
  exit 1
fi
grep -Fq 'Unknown argument: --unknown' "$work_dir/unknown.stderr"

echo "Local release preflight contract tests passed."
