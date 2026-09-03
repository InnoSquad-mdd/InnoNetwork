#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_state=""
git_ref=""
print_state=0

fail() {
  echo "6.0-release-state: $1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect)
      [[ $# -ge 2 ]] || fail "--expect requires draft or ready"
      expected_state="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || fail "--ref requires a commit-ish"
      git_ref="$2"
      shift 2
      ;;
    --print-state)
      print_state=1
      shift
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

case "$expected_state" in
  ""|draft|ready) ;;
  *) fail "--expect must be draft or ready" ;;
esac

required_paths=(
  API_STABILITY.md
  README.md
  CHANGELOG.md
  SECURITY.md
  Scripts/symbols/README.md
  Sources/InnoNetwork/InnoNetwork.docc/MigrationTo6.md
  docs/Migration-6.0.0.md
  docs/releases/6.0.0.md
  docs/site/index.html
)

validation_root="$repo_root"
temporary_root=""
cleanup() {
  if [[ -n "$temporary_root" ]]; then
    rm -rf "$temporary_root"
  fi
}
trap cleanup EXIT

if [[ -n "$git_ref" ]]; then
  resolved_ref="$(git -C "$repo_root" rev-parse --verify "${git_ref}^{commit}" 2>/dev/null || true)"
  [[ -n "$resolved_ref" ]] || fail "ref '$git_ref' does not resolve to a commit"
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-6-release-state.XXXXXX")"
  validation_root="$temporary_root"
  for path in "${required_paths[@]}"; do
    [[ "$(git -C "$repo_root" cat-file -t "${resolved_ref}:${path}" 2>/dev/null || true)" == "blob" ]] \
      || fail "missing $path in $git_ref"
    mkdir -p "$(dirname "$validation_root/$path")"
    git -C "$repo_root" cat-file blob "${resolved_ref}:${path}" > "$validation_root/$path"
  done
else
  for path in "${required_paths[@]}"; do
    [[ -f "$validation_root/$path" ]] || fail "missing $path"
  done
fi

api="$validation_root/API_STABILITY.md"
readme="$validation_root/README.md"
changelog="$validation_root/CHANGELOG.md"
security="$validation_root/SECURITY.md"
symbols="$validation_root/Scripts/symbols/README.md"
docc_migration="$validation_root/Sources/InnoNetwork/InnoNetwork.docc/MigrationTo6.md"
migration="$validation_root/docs/Migration-6.0.0.md"
notes="$validation_root/docs/releases/6.0.0.md"
site="$validation_root/docs/site/index.html"

require_line() {
  grep -Fqx "$1" "$2" || fail "missing exact line '$1' in ${2#"$validation_root/"}"
}

require_contains() {
  grep -Fq "$1" "$2" || fail "missing '$1' in ${2#"$validation_root/"}"
}

forbid_contains() {
  if grep -Fq "$1" "$2"; then
    fail "unexpected '$1' in ${2#"$validation_root/"}"
  fi
}

marker_count="$(grep -Ec '<!-- release-status: (draft|ready) -->' "$notes")"
[[ "$marker_count" == "1" ]] || fail "release notes require exactly one status marker"
case "$(sed -n '1p' "$notes")" in
  '<!-- release-status: draft -->') state="draft" ;;
  '<!-- release-status: ready -->') state="ready" ;;
  *) fail "release status marker must be the first line" ;;
esac

[[ -z "$expected_state" || "$state" == "$expected_state" ]] \
  || fail "expected $expected_state, found $state"

require_line "# Migration Guide: 6.0.0" "$migration"
require_line "# Migrating to InnoNetwork 6" "$docc_migration"
require_contains '.product(name: "InnoNetworkHLS", package: "InnoStream")' "$migration"
require_contains '.upToNextMajor(from: "1.0.0")' "$migration"
require_contains '.product(name: "InnoNetworkHLS", package: "InnoStream")' "$docc_migration"
require_contains '## Stable macro-first endpoint contract' "$migration"
require_contains '## Stable macro-first endpoint contract' "$docc_migration"
require_contains '### Root Macro Surface (Stable in 6.0)' "$api"
require_contains '<strong>9 Products</strong>' "$site"

if [[ "$state" == "draft" ]]; then
  require_line "Status: Draft (unreleased)" "$notes"
  require_line "Release date: TBD" "$notes"
  require_contains 'must not be used to create a' "$notes"
  require_line "# API Stability (6.0 Draft)" "$api"
  require_contains '`5.1.0` remains the latest stable public release.' "$api"
  require_contains '`6.0.0` is an unreleased draft on this' "$readme"
  require_contains 'unreleased `6.0.0` draft and have not been tagged.' "$changelog"
  require_contains '`6.0.0` is an unreleased draft.' "$security"
  require_contains '## Current sizes (InnoNetwork 6 development baseline)' "$symbols"
  require_contains 'This guide describes the unreleased InnoNetwork 6.0 draft.' "$migration"
  require_contains 'unreleased InnoNetwork 6 contract' "$site"
  forbid_contains '## [6.0.0] -' "$changelog"
else
  require_line "Status: Ready for release" "$notes"
  release_date="$(sed -nE 's/^Release date: ([0-9]{4}-[0-9]{2}-[0-9]{2})$/\1/p' "$notes")"
  [[ -n "$release_date" ]] || fail "ready notes require a release date"
  require_line "# API Stability (6.x)" "$api"
  require_contains '`6.0.0` is the public compatibility baseline' "$api"
  require_contains '`6.0.0` is the latest tagged stable release' "$readme"
  require_contains '.upToNextMajor(from: "6.0.0")' "$readme"
  require_line "## [6.0.0] - $release_date" "$changelog"
  require_contains '`6.x` is the actively supported tagged public release line.' "$security"
  require_contains '## Current sizes (InnoNetwork 6.0.0 release baseline)' "$symbols"
  require_contains 'This guide describes the released InnoNetwork 6.0 compatibility reset.' "$migration"
  require_contains 'latest tagged stable release is 6.0.0' "$site"
  forbid_contains 'Release date: TBD' "$notes"
  forbid_contains 'unreleased `6.0.0` draft' "$changelog"
  forbid_contains '`6.0.0` is an unreleased draft' "$security"
  forbid_contains 'unreleased InnoNetwork 6 contract' "$site"
fi

if [[ "$print_state" == "1" ]]; then
  echo "$state"
else
  echo "6.0-release-state: OK ($state${git_ref:+ at $git_ref})"
fi
