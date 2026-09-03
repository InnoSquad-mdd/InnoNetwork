# CI DoC (Definition of Completion)

This document defines the minimum completion criteria (DoC) for pull requests in InnoNetwork.

## Scope

- Applies to all PRs targeting `main`.
- Applies to direct pushes to `main`.
- Mirrors local validation commands used in development.

## Required CI Checks

`.github/required-status-checks.json` is the machine-readable merge-gate
contract. It requires dependency review, formatting and dead-code checks, the
pinned Xcode 26 compatibility build/test and bounded-shard lanes, the Xcode 27
full-surface build/test lane, docs and consumer smoke,
benchmark smoke, all five declared Apple platform builds, and CodeQL.
`Scripts/check_required_status_checks.py` validates both this policy and an
exported live GitHub ruleset so remote protection cannot quietly fall back to a
single check. Coverage upload jobs remain post-merge evidence rather than
merge gates because they depend on an external service.

The `CI` workflow must pass all of the following:

1. The root `Package.resolved` must remain tracked
   (`git ls-files --error-unmatch Package.resolved`), then
   `xcrun swift package resolve` must leave it unchanged. This is the
   reproducible CI lock and the input to the `Swift Dependency Submission`
   workflow. Main and pull requests use the same strict, lockfile-only
   converter; the richer release CycloneDX graph remains a separate release
   artifact. The main workflow submits every `main` SHA with job-scoped
   `contents: write`. A privileged `workflow_run` follow-up handles every PR,
   including Dependabot, by checking out only the trusted workflow revision
   and fetching the exact PR-head `Package.resolved` through the base
   repository Contents API as bounded JSON data. It never checks out or
   executes PR code, a PR artifact, `Package.swift`, or SwiftPM. The canonical
   macOS CI leg dry-runs the same converter without submitting it, so malformed
   locks and unsupported package sources fail before merge. Only HTTPS and
   GitHub's `git` SSH/SCP source forms are accepted; every source must resolve
   to one unambiguous GitHub owner/repository pair with both a semantic version
   and immutable revision. Branch-only and revision-only pins fail closed, as
   does changing a revision while retaining the same repository and version.
2. The pull-request-only `Dependency Review` job is blocking at `low` severity
   across runtime, development, and unknown scopes. It receives only
   `contents: read`. Before the pinned review action runs, CI polls the exact
   base/head comparison and requires GitHub's snapshot-warning header to be
   present and empty. A missing or incomplete graph therefore fails closed
   instead of producing an empty false-green review. The same read-only job
   checks out the exact trusted base verifier and revalidates the base/head
   lock transition, so an older persisted head snapshot cannot hide a
   same-version revision substitution after the PR base moves.
3. `xcrun swift build` on both Xcode 26.0.1 and Xcode 27
4. `xcrun swift test --no-parallel --enable-code-coverage` on both toolchains;
   Xcode 26 compiles the HLS-audio compatibility target, while Xcode 27
   compiles and executes its SDK-only public surface.
   The dead-code lane runs Periphery 3.8 on Xcode 27 so it sees that complete
   surface. It passes `--build-system native` only to provide the index-store
   layout Periphery currently requires; the product build and test lanes keep
   Swift 6.4's default build system.
5. A separate blocking `bash Scripts/run_bounded_parallel_tests.sh` job builds
   the suite once, then loads its test bundle in four concurrent, target-filtered
   Swift Testing processes without coverage instrumentation. Every process uses
   `--no-parallel`, so the Swift 6.2 testing runtime cannot exceed the intended
   four-process bound. Direct bundle loading avoids SwiftPM's shared `.build`
   lock; the script also proves that every discovered test belongs to exactly
   one shard.
   The extensions shard includes `InnoNetworkHLSTests`,
   `InnoNetworkHLSLiveTests`, and
   `InnoNetworkHLSAVFoundationTests`, plus the HLS-audio compatibility test on
   Xcode 26. The required Xcode 27 SwiftPM and docs lanes execute the actual
   version 27-only `InnoNetworkHLSAudioTests` surface.
   The canonical coverage lane also repeats the deterministic fixture,
   mutation, scaling, and race subset through
   `bash Scripts/run_hls_quality_gates.sh --skip-build`. That command also runs
   the AVPlayer decoded-audio runtime smoke through an ephemeral loopback HTTP
   fixture on macOS 27 or newer, and Apple's Media Stream Validator plus HLS
   Report when their separate developer download is installed. Unsupported
   hosts or missing Apple tools print `NOT RUN`. The full local release
   preflight passes `--require-runtime-smoke` and `--require-apple-tools`, then
   fails closed when the runtime or either binary is unavailable.
6. `rg -n "@unchecked Sendable"` across production targets, including
   `Sources/InnoNetworkMacros`, returns no matches.
7. `bash Scripts/check_shared_coders_mutation.sh` confirms the shared default
   JSON coders are never mutated after construction.
8. `bash Scripts/check_production_force_unwraps.sh` returns no matches in
   production source targets. Tests and smoke fixtures are excluded.
9. `bash Scripts/check_no_print_in_production.sh` returns no matches in
   production source targets. Tests and smoke fixtures are excluded.
10. Runtime and macro coverage reports are generated from explicit, disjoint
   source roots under `.build/coverage/` and `.build/coverage-macros/`, then uploaded as
   separate workflow artifacts. Missing profiling data, test executables,
   source files, or LCOV records fail the job; artifact upload also uses
   `if-no-files-found: error`. Codecov receives only those explicit reports
   with `disable_search: true`, using separate `core` and `macros` flags.
   Dedicated upload jobs authenticate with short-lived GitHub OIDC credentials
   instead of a repository secret, so dependency builds and tests never receive
   `id-token: write`. They download a fixed Codecov CLI release and verify its
   SHA-256 before handing it to the pinned action, avoiding an unreviewed
   `latest` binary at upload time. Pull requests retain artifact-only fallback
   when CLI installation or an upload fails, while canonical `main` pushes
   require both uploads.
11. `apple-platform-build-smoke` runs `xcodebuild ... build` for macOS and iOS.
   For tvOS, watchOS, and visionOS it uses the installed device SDK plus the
   package's minimum target triple to cross-compile every public library
   product. This avoids depending on hosted-runner simulator runtimes that can
   be pruned independently of their SDKs. All five platforms are unconditional
   hard gates: a missing SDK, undiscoverable public product, or compile failure
   fails CI. `Scripts/check_apple_platform_build_contract.py` derives the five
   deployment floors from `Package.swift` and requires CI, release, local
   preflight, and the cross-build helper to retain the exact matching
   destinations and target triples. SwiftPM test+coverage remains the runtime
   test gate.
12. `python3 Scripts/check_example_platform_floors.py` discovers every
    independent `Examples/*/Package.swift`, requires the root package's exact
    deployment floors, and requires CI and release to invoke the same automatic
    example builder. `Scripts/build_consumer_examples.sh` discovers the same
    manifests at execution time, so a new correctly versioned example cannot
    silently miss CI, release, or local preflight.
13. Consumer smoke verifies `Macros` is a default trait, the default package
   graph includes `swift-syntax`, and the `InnoNetworkMacros` target
   dependency is conditioned on that trait. It then performs a clean
   `--disable-default-traits` root build and rejects compiled macro products
   before building separate core-only (`traits: []`), aggregate, wrapper,
   download-only, websocket-only, test-support, generated-client, event-policy
   observer, and macro usage packages, including
   `Examples/WrapperSmoke` and `Examples/EventPolicyObserver`. The independent
   `Examples/MacroAdopterSmoke` executable then runs macro-generated GET and
   POST endpoints through the public `DefaultNetworkClient` and
   `InnoNetworkTestSupport` boundary so path/query/body/auth generation is a
   runtime release gate rather than compile-only evidence.
   `Examples/OpenAPIAdopterSmoke` independently imports the optional OpenAPI
   product, adapts an `OpenAPIRestOperation`, and verifies query encoding and
   response decoding through the public client and test-support boundaries.
   SwiftPM 6.2 can still resolve, fetch, or list manifest-level dependencies
   during a core-only build; the invariant is that macro products are absent
   from compilation. Traits are unified per package, so another dependency
   enabling default traits re-enables `Macros`.
14. `bash Scripts/check_provisional_enum_cases.sh` confirms guarded public enum
    cases still match their migration-review allowlist.
15. Macro tests run from source with
    `--disable-experimental-prebuilts --filter InnoNetworkMacroTests`, and
    `Scripts/check_macro_compile_failures.sh` verifies that invalid definitions
    fail with the intended diagnostic rather than compiling silently. The
    fixtures also require an unannotated request value to receive the targeted
    `@APIDefinition` correction at the `NetworkClient.request` boundary.
16. The CI benchmark smoke job runs
    `swift run -c release InnoNetworkBenchmarks --quick`
    and uploads the JSON summary to prove the benchmark CLI still builds and
    emits parseable results. Regression enforcement lives in the dedicated
    `Benchmarks` workflow: pull requests, scheduled runs, and manual runs all
    build base and head on the same hosted runner, interleave three samples per
    revision, and enforce the guarded median comparison at 20%. Pull requests
    compare against their base SHA; non-PR and release runs compare against the
    reviewed revision in `Benchmarks/Baselines/source-revision.txt`. This avoids
    treating hosted-runner generation or load differences as source regressions.
    Use `--regression-reason` to annotate an intentional baseline movement;
    the reason appears in the JSON artifact and PR comment but does not bypass
    the regression gate.
17. `python3 Scripts/check_macro_build_baseline_contract.py` validates the
    committed five-repeat SwiftPM and Xcode macro-consumer baselines. It fails
    on missing Core-only or 0/10/50/200-endpoint phases, short sample sets,
    invalid medians, or missing provenance. Absolute local timings are not CI
    thresholds; future comparisons use same-runner medians.
18. `python3 Scripts/check_release_workflow_contract.py` requires a manual
    `workflow_dispatch` validation path, tag-only release-ref validation, and a
    job-level tag-only guard on publication. Manual runs validate the selected
    commit against freshly fetched `origin/main` with
    `Scripts/validate_release_candidate.sh`; they can upload candidate evidence
    but cannot sign artifacts or create a GitHub Release.

The release workflow repeats the root lock, platform-floor, all-example,
platform-build, and full-test gates. It also builds and tests
`Tools/openapi-to-innonetwork`, matching the CI consumer-smoke contract before
release artifacts are generated.

## Pass/Fail Policy

- A PR is considered complete only when all CI checks are green.
- During a pre-release staging cycle, organization administrators may use the
  documented ruleset bypass for the staged direct-to-`main` workflow. The same
  checks still run on the resulting `main` SHA and must be green before the
  next stage proceeds. Remove or narrow that bypass before tagging 5.0.0.
- If any check fails, the PR is not merge-ready.
- Concurrency regressions and `@unchecked Sendable` additions in production sources are blocking failures.
- Force unwrap additions in production sources are blocking failures; fixture
  force unwraps belong in tests or smoke-only targets.
- Adding `print()` to production sources is a blocking failure. The rule is
  enforced by `bash Scripts/check_no_print_in_production.sh`, matching required
  check 9 above.

## Integration Tests Policy

- Network-dependent tests should remain opt-in via `INNO_LIVE=1`.
- Default CI runs deterministic unit tests only.
- `Nightly Live Smoke` runs core live tests, WebSocket, persistent cache,
  Download pause/resume, and OpenAPI as independent jobs so one slow endpoint
  cannot prevent the other surfaces from reporting. WebSocket and OpenAPI stay
  best-effort because their public fixtures are third-party services; the fixed
  Download fixture is a blocking regression signal for completion staging.

## Local Reproduction

Run the same commands locally:

```bash
# Reproduce the backward-compatible package surface first.
sudo xcode-select -s /Applications/Xcode_26.0.1.app
xcrun swift build
xcrun swift test --no-parallel

# Release preflight validates the complete HLS-audio surface and therefore
# requires Xcode 27 / Swift 6.4. On the xcode-27 runner and standard local
# installs, /Applications/Xcode.app resolves to that toolchain.
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -version

# The default fast mode runs the deterministic
# contracts, all independent consumer packages, the OpenAPI generator suite,
# and the same bounded root test shards used by CI.
bash Scripts/run_local_release_preflight.sh

# Before approving a release-state commit, replay every locally reproducible
# release gate: coverage, same-runner guarded benchmarks, both SBOM profiles,
# all-product DocC, and macOS/iOS/tvOS/watchOS/visionOS builds. Generated
# evidence remains under .build/local-release-preflight/ for inspection.
bash Scripts/run_local_release_preflight.sh --full

# The commands below document the individual gates for diagnosis.
git ls-files --error-unmatch Package.resolved >/dev/null
xcrun swift package resolve
git diff --exit-code -- Package.resolved
bash Scripts/tests/test_generate_dependency_snapshot.sh
GITHUB_SHA="$(git rev-parse HEAD)" \
GITHUB_REF="refs/heads/main" \
GITHUB_REPOSITORY="InnoSquadCorp/InnoNetwork" \
GITHUB_SERVER_URL="https://github.com" \
GITHUB_RUN_ID="1" \
GITHUB_RUN_ATTEMPT="1" \
python3 Scripts/generate_dependency_snapshot.py \
  --package-resolved Package.resolved /tmp/innonetwork-snapshot.json
xcrun swift build
# Match both blocking test lanes.
bash Scripts/run_bounded_parallel_tests.sh
xcrun swift test --no-parallel --enable-code-coverage
bash Scripts/run_hls_quality_gates.sh --skip-build
bash Scripts/run_hls_quality_gates.sh --skip-build \
  --require-runtime-smoke --require-apple-tools
rg -n "@unchecked Sendable" \
  Sources/InnoNetwork \
  Sources/InnoNetworkMacros \
  Sources/InnoNetworkDownload \
  Sources/InnoNetworkUpload \
  Sources/InnoNetworkPersistentCache \
  Sources/InnoNetworkWebSocket
bash Scripts/check_production_force_unwraps.sh
bash Scripts/check_no_print_in_production.sh
bash Scripts/check_shared_coders_mutation.sh
bash Scripts/check_provisional_enum_cases.sh
python3 Scripts/check_example_platform_floors.py
python3 Scripts/check_apple_platform_build_contract.py

# Verify default and core-only macro trait profiles.
bash Scripts/check_macro_trait_graphs.sh
bash Scripts/check_core_trait_build.sh
bash Scripts/build_consumer_examples.sh
xcrun swift build --package-path Tools/openapi-to-innonetwork
xcrun swift test --package-path Tools/openapi-to-innonetwork

# Render the same explicit coverage artifacts CI uploads. These commands fail
# instead of silently accepting missing or empty coverage inputs.
# Match the runtime report's explicit exclusion of macro implementation files.
runtime_source_roots=()
while IFS= read -r source_root; do
  runtime_source_roots+=("$source_root")
done < <(
  find Sources -mindepth 1 -maxdepth 1 -type d \
    ! -name InnoNetworkMacros -print | sort
)
bash Scripts/generate_coverage_report.sh \
  .build .build/coverage "${runtime_source_roots[@]}"

xcrun swift test --disable-experimental-prebuilts \
  --filter InnoNetworkMacroTests --enable-code-coverage
bash Scripts/generate_coverage_report.sh \
  .build \
  .build/coverage-macros \
  Sources/InnoNetworkMacros
bash Scripts/check_macro_compile_failures.sh

# Optional: replay the same three-sample median comparison used by hosted CI.
# The runner reads every protected identifier from
# Benchmarks/guarded-benchmarks.txt and compares the current working tree with
# the reviewed baseline source revision on this machine.
bash Scripts/check_guarded_benchmark_contract.sh
bash Scripts/run_same_runner_benchmarks.sh \
  --output-dir .build/local-benchmark-comparison \
  --max-regression-percent 20
```

The full preflight invokes package-owned Xcode schemes through an isolated
package view when a generated `.xcodeproj` or `.xcworkspace` is present beside
`Package.swift`; those local containers are neither selected nor modified.

The base and candidate production sources are built separately on one runner,
but both use the candidate benchmark harness. Three samples per revision are
interleaved and compared by median, so harness methodology and machine class do
not masquerade as implementation regressions. The runtime benchmark disables
default traits because macro compilation is measured by the separate repeated
macro-build baseline rather than this runtime throughput gate.
