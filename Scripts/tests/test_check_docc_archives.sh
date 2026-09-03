#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/Scripts/check_docc_archives.sh"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-docc-archive-contract-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

products=(
  InnoNetwork
  InnoNetworkAuthAWS
  InnoNetworkDownload
  InnoNetworkUpload
  InnoNetworkWebSocket
  InnoNetworkPersistentCache
  InnoNetworkOpenAPI
  InnoNetworkTrust
  InnoNetworkTestSupport
)

make_fixture() {
  local fixture_root="$1"
  local package_json="$fixture_root/package.json"
  local product

  mkdir -p "$fixture_root/docs" "$fixture_root/DerivedData/Build/Products/Debug"
  cp "$repo_root/docs/public-docc-products.txt" "$fixture_root/docs/public-docc-products.txt"

  python3 - "$package_json" "${products[@]}" <<'PY'
import json
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
products = sys.argv[2:]
payload = {
    "products": [
        {"name": product, "type": {"library": ["automatic"]}}
        for product in products
    ]
}
output.write_text(json.dumps(payload), encoding="utf-8")
PY

  for product in "${products[@]}"; do
    mkdir -p "$fixture_root/DerivedData/Build/Products/Debug/$product.doccarchive"
  done
}

run_checker() {
  local fixture_root="$1"
  INNO_DOCC_CONTRACT_ROOT="$fixture_root" \
    INNO_DOCC_PACKAGE_JSON="$fixture_root/package.json" \
    bash "$checker" "$fixture_root/DerivedData"
}

success_root="$work_dir/success"
make_fixture "$success_root"
run_checker "$success_root" >/dev/null

missing_archive_root="$work_dir/missing-archive"
make_fixture "$missing_archive_root"
rmdir "$missing_archive_root/DerivedData/Build/Products/Debug/InnoNetworkTrust.doccarchive"
if run_checker "$missing_archive_root" \
  > "$work_dir/missing-archive.stdout" \
  2> "$work_dir/missing-archive.stderr"; then
  echo "Expected a missing public DocC archive to fail." >&2
  exit 1
fi
grep -Fq 'expected exactly one InnoNetworkTrust.doccarchive' \
  "$work_dir/missing-archive.stderr"

package_mismatch_root="$work_dir/package-mismatch"
make_fixture "$package_mismatch_root"
python3 - "$package_mismatch_root/package.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["products"] = payload["products"][:-1]
path.write_text(json.dumps(payload), encoding="utf-8")
PY
if run_checker "$package_mismatch_root" \
  > "$work_dir/package-mismatch.stdout" \
  2> "$work_dir/package-mismatch.stderr"; then
  echo "Expected a Package.swift product mismatch to fail." >&2
  exit 1
fi
grep -Fq 'public product contract does not match Package.swift' \
  "$work_dir/package-mismatch.stderr"

duplicate_root="$work_dir/duplicate"
make_fixture "$duplicate_root"
printf '%s\n' InnoNetwork >> "$duplicate_root/docs/public-docc-products.txt"
if run_checker "$duplicate_root" \
  > "$work_dir/duplicate.stdout" \
  2> "$work_dir/duplicate.stderr"; then
  echo "Expected a duplicate public product to fail." >&2
  exit 1
fi
grep -Fq 'duplicate public product(s)' "$work_dir/duplicate.stderr"

echo "DocC archive contract tests passed."
