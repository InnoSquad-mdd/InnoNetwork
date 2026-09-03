#!/usr/bin/env bash
# Validates that a release workflow was triggered from a trustworthy Git tag.
#
# The release tag must be a SemVer 2.0.0 version, be an annotated tag that
# names that same version, peel to the exact commit at the configured main ref,
# and contain versioned release notes explicitly marked ready. By default the
# configured remote main ref is fetched first, so a stale local tracking ref is
# never accepted.
#
# Environment overrides are intentionally explicit so the validator can be
# exercised with local refs and local remotes in deterministic tests:
#   RELEASE_TAG             Version to validate (defaults to GITHUB_REF_NAME)
#   RELEASE_TAG_REF         Tag ref (defaults to GITHUB_REF or refs/tags/<tag>)
#   RELEASE_REMOTE          Remote to fetch (defaults to origin)
#   RELEASE_MAIN_REMOTE_REF Remote main source ref (defaults to refs/heads/main)
#   RELEASE_MAIN_REF        Local validation ref (defaults to
#                           refs/remotes/<remote>/main)
#   RELEASE_FETCH_MAIN      1 to fetch main first; 0 for an injected local ref

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf '❌ Release ref validation failed: %s\n' "$1" >&2
    exit 1
}

release_tag="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
[[ -n "$release_tag" ]] || fail "RELEASE_TAG or GITHUB_REF_NAME is required."

# SemVer 2.0.0 without a leading "v". The GitHub release trigger is *.*.*,
# so every accepted tag has the same unprefixed major.minor.patch core while
# still allowing standard prerelease and build metadata suffixes.
numeric_identifier='(0|[1-9][0-9]*)'
prerelease_identifier='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
semver_pattern="^${numeric_identifier}\\.${numeric_identifier}\\.${numeric_identifier}(-${prerelease_identifier}(\\.${prerelease_identifier})*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"

if [[ ! "$release_tag" =~ $semver_pattern ]]; then
    fail "tag '$release_tag' is not an unprefixed SemVer 2.0.0 version."
fi

release_remote="${RELEASE_REMOTE:-origin}"
main_remote_ref="${RELEASE_MAIN_REMOTE_REF:-refs/heads/main}"
main_ref="${RELEASE_MAIN_REF:-refs/remotes/${release_remote}/main}"
fetch_main="${RELEASE_FETCH_MAIN:-1}"

if [[ -n "${RELEASE_TAG_REF:-}" ]]; then
    tag_ref="$RELEASE_TAG_REF"
elif [[ -n "${GITHUB_REF:-}" ]]; then
    tag_ref="$GITHUB_REF"
else
    tag_ref="refs/tags/$release_tag"
fi

git -C "$repo_root" check-ref-format "$tag_ref" >/dev/null 2>&1 \
    || fail "tag ref '$tag_ref' is not a valid full Git ref."
git -C "$repo_root" check-ref-format "$main_ref" >/dev/null 2>&1 \
    || fail "main ref '$main_ref' is not a valid full Git ref."
git -C "$repo_root" check-ref-format "$main_remote_ref" >/dev/null 2>&1 \
    || fail "remote main ref '$main_remote_ref' is not a valid full Git ref."

case "$fetch_main" in
    0)
        ;;
    1)
        if ! git -C "$repo_root" fetch --no-tags "$release_remote" \
            "+${main_remote_ref}:${main_ref}"; then
            fail "could not fetch '$main_remote_ref' from '$release_remote'; refusing to use a stale main ref."
        fi
        ;;
    *)
        fail "RELEASE_FETCH_MAIN must be 0 or 1, got '$fetch_main'."
        ;;
esac

tag_object_type="$(git -C "$repo_root" cat-file -t "$tag_ref" 2>/dev/null || true)"
if [[ "$tag_object_type" != "tag" ]]; then
    fail "'$tag_ref' must exist as an annotated tag (found '${tag_object_type:-nothing}')."
fi

declared_tag="$(git -C "$repo_root" cat-file -p "$tag_ref" \
    | sed -n 's/^tag //p' \
    | head -n 1)"
if [[ "$declared_tag" != "$release_tag" ]]; then
    fail "annotated tag object declares '$declared_tag', not '$release_tag'."
fi

tag_commit="$(git -C "$repo_root" rev-parse --verify "${tag_ref}^{commit}" 2>/dev/null || true)"
[[ -n "$tag_commit" ]] \
    || fail "annotated tag '$tag_ref' does not peel to a commit."

main_commit="$(git -C "$repo_root" rev-parse --verify "${main_ref}^{commit}" 2>/dev/null || true)"
[[ -n "$main_commit" ]] \
    || fail "configured main ref '$main_ref' does not resolve to a commit."

if [[ "$tag_commit" != "$main_commit" ]]; then
    fail "tag commit '$tag_commit' does not exactly match configured main ref '$main_ref' ($main_commit)."
fi

release_notes="docs/releases/${release_tag}.md"
if ! git -C "$repo_root" cat-file -e "${tag_commit}:${release_notes}" 2>/dev/null; then
    fail "tagged commit does not contain required release notes '$release_notes'."
fi

notes_type="$(git -C "$repo_root" cat-file -t "${tag_commit}:${release_notes}" 2>/dev/null || true)"
if [[ "$notes_type" != "blob" ]]; then
    fail "'$release_notes' must be a file in the tagged commit (found '${notes_type:-nothing}')."
fi

notes_content="$(git -C "$repo_root" cat-file blob "${tag_commit}:${release_notes}")"
status_marker_count="$(printf '%s\n' "$notes_content" | LC_ALL=C awk '
    /<!--[[:space:]]*release-status[[:space:]]*:/ { count += 1 }
    END { print count + 0 }
')"
ready_marker='<!-- release-status: ready -->'

if [[ "$status_marker_count" != "1" ]]; then
    fail "'$release_notes' must contain exactly one release-status marker as its first line; use '$ready_marker' only when the notes are publishable (found $status_marker_count)."
fi

first_line="${notes_content%%$'\n'*}"
case "$first_line" in
    "$ready_marker")
        ;;
    '<!-- release-status: draft -->'|'<!-- release-status: unreleased -->')
        release_status="${first_line#'<!-- release-status: '}"
        release_status="${release_status%' -->'}"
        fail "'$release_notes' is marked '$release_status'; replace its first line with '$ready_marker' only when the release notes are publishable."
        ;;
    *)
        fail "'$release_notes' must begin with the exact marker '$ready_marker' when the release notes are publishable."
        ;;
esac

# Major baselines change the repository's documented stable line as well as
# the code.
# A ready marker by itself is therefore insufficient: the tagged Git tree must
# atomically move README, API stability, changelog, security, symbols, and
# migration claims out of preview state. Later patch/minor releases keep using
# their versioned ready marker above without replaying this one-time baseline
# transition.
if [[ "$release_tag" == "5.0.0" ]]; then
    docs_state_validator="$repo_root/Scripts/validate_docs_release_state.sh"
    [[ -f "$docs_state_validator" ]] \
        || fail "required 5.0 documentation state validator is missing: '$docs_state_validator'."
    if ! bash "$docs_state_validator" --expect ready --ref "$tag_commit"; then
        fail "tagged 5.0.0 documentation does not form one coherent ready release state."
    fi
fi

if [[ "$release_tag" == "6.0.0" ]]; then
    six_docs_state_validator="$repo_root/Scripts/validate_6_release_state.sh"
    [[ -f "$six_docs_state_validator" ]] \
        || fail "required 6.0 documentation state validator is missing: '$six_docs_state_validator'."
    if ! bash "$six_docs_state_validator" --expect ready --ref "$tag_commit"; then
        fail "tagged 6.0.0 documentation does not form one coherent ready release state."
    fi
fi

printf '✅ Release ref validated: %s peels to exact %s at %s and contains ready release notes %s.\n' \
    "$release_tag" "$tag_commit" "$main_ref" "$release_notes"
