# DocC Deployment Guide

## Overview

DocC documentation is built and deployed to GitHub Pages via:

- `.github/workflows/docc-pages.yml`

The workflow builds and publishes DocC archives for all public products:

1. `InnoNetwork`
2. `InnoNetworkAuthAWS`
3. `InnoNetworkDownload`
4. `InnoNetworkUpload`
5. `InnoNetworkHLS`
6. `InnoNetworkHLSLive`
7. `InnoNetworkHLSAVFoundation`
8. `InnoNetworkHLSAudio`
9. `InnoNetworkWebSocket`
10. `InnoNetworkPersistentCache`
11. `InnoNetworkOpenAPI`
12. `InnoNetworkTrust`
13. `InnoNetworkTestSupport`

The build uses GitHub's `xcode-27` image because the HLS-audio catalog links
SDK declarations that do not exist in Xcode 26.

Each public product owns a same-named DocC catalog. This keeps the generated
module landing page and curated topic groups from depending on DocC's
symbol-only fallback behavior.

## Triggers

- `push` to `main`
- `workflow_dispatch` (manual run)

## Deployment Output

The workflow deploys a static site to GitHub Pages with module-specific entry points:

- `/<repo>/InnoNetwork/documentation/innonetwork`
- `/<repo>/InnoNetworkAuthAWS/documentation/innonetworkauthaws`
- `/<repo>/InnoNetworkDownload/documentation/innonetworkdownload`
- `/<repo>/InnoNetworkUpload/documentation/innonetworkupload`
- `/<repo>/InnoNetworkHLS/documentation/innonetworkhls`
- `/<repo>/InnoNetworkHLSLive/documentation/innonetworkhlslive`
- `/<repo>/InnoNetworkHLSAVFoundation/documentation/innonetworkhlsavfoundation`
- `/<repo>/InnoNetworkHLSAudio/documentation/innonetworkhlsaudio`
- `/<repo>/InnoNetworkWebSocket/documentation/innonetworkwebsocket`
- `/<repo>/InnoNetworkPersistentCache/documentation/innonetworkpersistentcache`
- `/<repo>/InnoNetworkOpenAPI/documentation/innonetworkopenapi`
- `/<repo>/InnoNetworkTrust/documentation/innonetworktrust`
- `/<repo>/InnoNetworkTestSupport/documentation/innonetworktestsupport`

It also publishes a root index page linking to every module. Before upload, the
workflow requires each module's transformed landing HTML and render-node JSON
to exist and requires the root index to link to all thirteen routes. After Pages
deployment, it requests the root and every module URL with bounded retries so a
bad hosting base path or missing route fails the deployment job.

## Local Reproduction

From repo root:

```bash
xcodebuild docbuild \
  -scheme InnoNetwork-Package \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/DocC

bash Scripts/check_docc_archives.sh .build/DocC

mkdir -p .build/docc-site

while IFS= read -r module; do
  archive="$(find .build/DocC/Build/Products -type d \
    -path "*/${module}.doccarchive" -print -quit)"
  xcrun docc process-archive transform-for-static-hosting "$archive" \
    --output-path ".build/docc-site/$module" \
    --hosting-base-path "InnoNetwork/$module"

  slug="$(printf '%s' "$module" | tr '[:upper:]' '[:lower:]')"
  test -s ".build/docc-site/$module/documentation/$slug/index.html"
  test -s ".build/docc-site/$module/data/documentation/$slug.json"
done < docs/public-docc-products.txt
```

Replace the first `InnoNetwork` in each `--hosting-base-path` with the actual
repository name when reproducing a fork's Pages layout.

For local CPU stability, run DocC archive transforms sequentially. Avoid running
symbol graph generation for other Swift packages at the same time; DocC and
SwiftPM symbol extraction are CPU-heavy and can saturate local developer
machines.

## Operational Notes

- Ensure GitHub Pages is enabled in repository settings.
- The workflow uses `actions/upload-pages-artifact` and `actions/deploy-pages`.
- A library product addition or rename must update its DocC catalog,
  `docs/public-docc-products.txt`, this route list, and `docs/site/index.html`
  together. The archive contract rejects drift from `Package.swift`.
