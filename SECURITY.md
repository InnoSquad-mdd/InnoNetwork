# Security Policy

## Reporting a Vulnerability

Use the following channels in order of preference. Do **not** open a
public issue, post on a discussion thread, or share details in a pull
request before the maintainers have acknowledged the report.

1. **Preferred — GitHub Private Vulnerability Reporting (GHSA).**
   Open a private advisory at
   <https://github.com/InnoSquadCorp/InnoNetwork/security/advisories/new>.
   This routes directly to the maintainers and creates a tracking
   advisory that we can publish alongside the fix.
2. **Fallback — direct contact.** If GHSA reporting is unavailable or
   you cannot complete it, email the maintainer listed as the project's
   primary CODEOWNER. Mark the subject line with `[SECURITY]` so the
   message is triaged ahead of routine issues.

Whichever channel you use, please include:

- affected module and version (e.g. `InnoNetworkPersistentCache @ 5.0.0`, or
  `main` plus the tested commit revision for an unreleased fix)
- reproduction steps (minimal failing case if possible)
- expected impact and threat model (confidentiality / integrity /
  availability, attacker preconditions)
- proof-of-concept, logs, or stack traces if available
- whether you intend to request a CVE or have a coordinated-disclosure
  timeline you would like us to honor

## Supported Versions

- `5.x` is the actively supported tagged public release line.
- `6.0.0` is an unreleased draft. Reports against the 6.0 branch are assessed
  as prerelease findings until the release is tagged.
- `4.x` receives no further routine maintenance after the 5.0 compatibility
  reset; security reports are still assessed according to impact.
- Earlier release lines are unsupported.

## Disclosure

- We will validate the report, assess impact, and coordinate a fix before public disclosure.
- Release notes will identify security-relevant fixes when it is safe to do so.

## Verifying release artifacts

Tagged releases publish the benchmark snapshot (`benchmarks.json`), the root
default-trait SBOM (`sbom.cdx.json`), and the core-only trait-profile SBOM
(`sbom-core-only.cdx.json`), all signed with sigstore cosign keyless signatures.
The signing workflow runs on
`InnoSquadCorp/InnoNetwork`'s release job and uses the GitHub OIDC issuer.
To verify a downloaded artifact:

```bash
# Pre-requisites:
brew install cosign

# Replace <version> with an existing release tag (e.g. 4.0.0).
version="<version>"
artifact="benchmarks.json"   # or sbom.cdx.json / sbom-core-only.cdx.json

curl -sLO "https://github.com/InnoSquadCorp/InnoNetwork/releases/download/${version}/${artifact}"
curl -sLO "https://github.com/InnoSquadCorp/InnoNetwork/releases/download/${version}/${artifact}.sig"
curl -sLO "https://github.com/InnoSquadCorp/InnoNetwork/releases/download/${version}/${artifact}.crt"

cosign verify-blob \
  --certificate "${artifact}.crt" \
  --signature "${artifact}.sig" \
  --certificate-identity-regexp 'https://github.com/InnoSquadCorp/InnoNetwork/.github/workflows/release.yml@refs/tags/.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  "${artifact}"
```

A matching certificate identity confirms the artifact was signed by the
release workflow on the canonical repository at that tag, not a fork or a
re-uploaded copy.

## Supply-chain artifacts

- `sbom.cdx.json` — CycloneDX 1.5 software bill of materials for the root
  package's complete resolved SwiftPM dependency graph with default traits,
  including the macro toolchain inputs.
- `sbom-core-only.cdx.json` — the same root manifest resolved with default
  traits disabled. It records the auditable core-only trait profile separately;
  SwiftPM can still resolve manifest-level packages even when their products
  and compiler plug-ins are excluded from compilation.
- `benchmarks.json` — frozen output of the release-time benchmark run
  ([Benchmarks/README.md](Benchmarks/README.md)).
