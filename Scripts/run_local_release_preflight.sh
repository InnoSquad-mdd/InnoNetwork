#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export LC_ALL=C

mode="fast"
list_only=0

usage() {
  cat <<'USAGE'
Usage: bash Scripts/run_local_release_preflight.sh [--fast|--full] [--list]

Run the release checks that can be reproduced before a tag exists.

  --fast  Run deterministic contracts, consumer builds, tools, and bounded tests.
          This is the default. Xcode 27 and Swift 6.4 are required.
  --full  Also generate coverage and SBOMs, enforce same-runner benchmark guards,
          build all-product DocC, and build all five supported Apple platforms.
  --list  Print the selected gate names without running them.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast)
      mode="fast"
      ;;
    --full)
      mode="full"
      ;;
    --list)
      list_only=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

fast_gates=(
  "release-script-fixtures"
  "dependency-lock"
  "static-contracts"
  "documentation-smoke"
  "consumer-examples"
  "openapi-generator"
  "bounded-tests"
)

full_only_gates=(
  "runtime-coverage"
  "macro-coverage"
  "guarded-benchmarks"
  "sbom-artifacts"
  "all-product-docc"
  "apple-platform-builds"
)

gates=("${fast_gates[@]}")
if [[ "$mode" == "full" ]]; then
  gates+=("${full_only_gates[@]}")
fi

if (( list_only == 1 )); then
  printf '%s\n' "${gates[@]}"
  exit 0
fi

required_commands=(git python3 xcrun)
if [[ "$mode" == "full" ]]; then
  required_commands+=(jq xcodebuild)
fi

for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "local-release-preflight: required command is unavailable: $command_name" >&2
    exit 69
  fi
done

swift_version="$(
  xcrun swift --version \
    | sed -nE 's/^Apple Swift version ([0-9]+)\.([0-9]+).*/\1.\2/p' \
    | head -n 1
)"
if [[ -z "$swift_version" ]]; then
  echo "local-release-preflight: unable to determine the active Swift version" >&2
  exit 69
fi
swift_major="${swift_version%%.*}"
swift_minor="${swift_version##*.}"
if (( swift_major < 6 || (swift_major == 6 && swift_minor < 4) )); then
  echo "local-release-preflight: Xcode 27 with Swift 6.4 or newer is required; found Swift $swift_version" >&2
  exit 69
fi

macos_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
macos_sdk_major="${macos_sdk_version%%.*}"
if [[ ! "$macos_sdk_major" =~ ^[0-9]+$ ]] || (( macos_sdk_major < 27 )); then
  echo "local-release-preflight: the macOS 27 SDK or newer is required; found $macos_sdk_version" >&2
  exit 69
fi

if [[ "$mode" == "full" ]]; then
  for sdk in macosx iphonesimulator appletvos watchos xros; do
    if ! xcrun --sdk "$sdk" --show-sdk-path >/dev/null 2>&1; then
      echo "local-release-preflight: required Apple SDK is unavailable: $sdk" >&2
      exit 69
    fi
  done
fi

artifacts_dir="$repo_root/.build/local-release-preflight"
mkdir -p "$artifacts_dir"

package_xcodebuild_root="$repo_root"
package_xcodebuild_view=""

cleanup_package_xcodebuild_view() {
  if [[ -n "$package_xcodebuild_view" ]]; then
    rm -rf "$package_xcodebuild_view"
  fi
}
trap cleanup_package_xcodebuild_view EXIT

prepare_package_xcodebuild_view() {
  if [[ -n "$package_xcodebuild_view" ]]; then
    return
  fi
  if [[ -z "$(find "$repo_root" -maxdepth 1 \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) -print -quit)" ]]; then
    return
  fi

  package_xcodebuild_view="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-package-view.XXXXXX")"
  local package_entry
  for package_entry in Package.swift Package.resolved Sources Tests SmokeTests Benchmarks; do
    if [[ ! -e "$repo_root/$package_entry" ]]; then
      echo "local-release-preflight: package entry is unavailable: $package_entry" >&2
      exit 69
    fi
    ln -s "$repo_root/$package_entry" "$package_xcodebuild_view/$package_entry"
  done
  package_xcodebuild_root="$package_xcodebuild_view"
}

run_package_xcodebuild() {
  prepare_package_xcodebuild_view
  (
    cd "$package_xcodebuild_root"
    xcodebuild "$@"
  )
}

run_release_script_fixtures() {
  bash Scripts/tests/test_validate_docs_release_state.sh
  bash Scripts/tests/test_validate_release_ref.sh
  bash Scripts/tests/test_validate_release_candidate.sh
  bash Scripts/tests/test_generate_sbom.sh
  bash Scripts/tests/test_prepare_release_artifacts.sh
  bash Scripts/tests/test_generate_dependency_snapshot.sh
  bash Scripts/tests/test_check_guarded_benchmark_contract.sh
  bash Scripts/tests/test_run_same_runner_benchmarks.sh
  python3 Scripts/tests/test_run_with_guarded_benchmarks.py
  python3 Scripts/tests/test_check_macro_build_baseline_contract.py
  python3 Scripts/tests/test_check_public_api_tiers.py
  python3 Scripts/check_required_status_checks.py
  python3 Scripts/tests/test_check_required_status_checks.py
  bash Scripts/tests/test_build_consumer_examples.sh
  python3 Scripts/tests/test_check_example_platform_floors.py
  python3 Scripts/tests/test_check_apple_platform_build_contract.py
  bash Scripts/tests/test_check_docc_archives.sh
  python3 Scripts/check_release_workflow_contract.py
  python3 Scripts/tests/test_check_release_workflow_contract.py
}

run_dependency_lock() {
  git ls-files --error-unmatch Package.resolved >/dev/null
  xcrun swift package resolve
  git diff --exit-code -- Package.resolved
}

run_static_contracts() {
  bash Scripts/format.sh --lint
  bash Scripts/check_macro_trait_graphs.sh
  bash Scripts/check_core_trait_build.sh
  bash Scripts/check_guarded_benchmark_contract.sh
  python3 Scripts/check_macro_build_baseline_contract.py
  bash Scripts/check_docs_contract_sync.sh
  bash Scripts/check_stable_examples.sh
  python3 Scripts/check_example_platform_floors.py
  python3 Scripts/check_apple_platform_build_contract.py
  bash Scripts/check_migration_examples.sh
  bash Scripts/check_changelog_sync.sh
  bash Scripts/check_provisional_enum_cases.sh
  bash Scripts/check_macro_compile_failures.sh
  bash Scripts/check_unchecked_sendable.sh
  bash Scripts/check_shared_coders_mutation.sh
  bash Scripts/check_production_force_unwraps.sh
  bash Scripts/check_no_print_in_production.sh
}

run_documentation_smoke() {
  xcrun swift build --target InnoNetworkDocSmoke
  xcrun swift run InnoNetworkDocSmoke
}

run_consumer_examples() {
  bash Scripts/build_consumer_examples.sh
  xcrun swift run --package-path Examples/MacroAdopterSmoke
  xcrun swift run --package-path Examples/OpenAPIAdopterSmoke
}

run_openapi_generator() {
  xcrun swift build --package-path Tools/openapi-to-innonetwork
  xcrun swift test --package-path Tools/openapi-to-innonetwork
}

run_bounded_tests() {
  bash Scripts/run_bounded_parallel_tests.sh
}

run_runtime_coverage() {
  local runtime_source_roots=()
  local source_root

  xcrun swift test --no-parallel --enable-code-coverage
  while IFS= read -r source_root; do
    runtime_source_roots+=("$source_root")
  done < <(
    find Sources -mindepth 1 -maxdepth 1 -type d \
      ! -name InnoNetworkMacros -print | sort
  )
  bash Scripts/generate_coverage_report.sh \
    .build \
    "$artifacts_dir/coverage-core" \
    "${runtime_source_roots[@]}"
}

run_macro_coverage() {
  xcrun swift test \
    --disable-experimental-prebuilts \
    --filter InnoNetworkMacroTests \
    --enable-code-coverage
  bash Scripts/generate_coverage_report.sh \
    .build \
    "$artifacts_dir/coverage-macros" \
    Sources/InnoNetworkMacros
}

run_guarded_benchmarks() {
  bash Scripts/run_same_runner_benchmarks.sh \
    --output-dir "$artifacts_dir/benchmarks" \
    --max-regression-percent 20
}

run_sbom_artifacts() {
  SBOM_VERSION="$(git rev-parse --short HEAD)" \
    SBOM_TRAIT_PROFILE=default \
    bash Scripts/generate-sbom.sh "$artifacts_dir/sbom.cdx.json"
  SBOM_VERSION="$(git rev-parse --short HEAD)" \
    SBOM_TRAIT_PROFILE=core-only \
    bash Scripts/generate-sbom.sh "$artifacts_dir/sbom-core-only.cdx.json"
}

run_all_product_docc() {
  run_package_xcodebuild docbuild \
    -scheme InnoNetwork-Package \
    -destination 'generic/platform=macOS' \
    -skipMacroValidation \
    -derivedDataPath "$artifacts_dir/DocC"
  bash Scripts/check_docc_archives.sh "$artifacts_dir/DocC"
}

run_apple_platform_builds() {
  run_package_xcodebuild \
    -scheme InnoNetwork-Package \
    -destination 'platform=macOS' \
    -skipMacroValidation \
    -derivedDataPath "$artifacts_dir/macos" \
    CODE_SIGNING_ALLOWED=NO \
    build
  run_package_xcodebuild \
    -scheme InnoNetwork-Package \
    -destination 'generic/platform=iOS Simulator' \
    -skipMacroValidation \
    -derivedDataPath "$artifacts_dir/ios" \
    CODE_SIGNING_ALLOWED=NO \
    build
  bash Scripts/build_apple_platform_targets.sh \
    tvOS appletvos arm64-apple-tvos16.0 "$artifacts_dir/tvos"
  bash Scripts/build_apple_platform_targets.sh \
    watchOS watchos arm64_32-apple-watchos9.0 "$artifacts_dir/watchos"
  bash Scripts/build_apple_platform_targets.sh \
    visionOS xros arm64-apple-xros1.0 "$artifacts_dir/visionos"
}

run_gate() {
  local gate="$1"
  echo "::group::Local release preflight: $gate"
  case "$gate" in
    release-script-fixtures) run_release_script_fixtures ;;
    dependency-lock) run_dependency_lock ;;
    static-contracts) run_static_contracts ;;
    documentation-smoke) run_documentation_smoke ;;
    consumer-examples) run_consumer_examples ;;
    openapi-generator) run_openapi_generator ;;
    bounded-tests) run_bounded_tests ;;
    runtime-coverage) run_runtime_coverage ;;
    macro-coverage) run_macro_coverage ;;
    guarded-benchmarks) run_guarded_benchmarks ;;
    sbom-artifacts) run_sbom_artifacts ;;
    all-product-docc) run_all_product_docc ;;
    apple-platform-builds) run_apple_platform_builds ;;
    *)
      echo "local-release-preflight: unknown gate: $gate" >&2
      exit 70
      ;;
  esac
  echo "::endgroup::"
}

for gate in "${gates[@]}"; do
  run_gate "$gate"
done

echo "Local release preflight ($mode) passed ${#gates[@]} gates."
echo "Artifacts: $artifacts_dir"
