#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Collect the package's supported public symbol-graph rows."
    )
    parser.add_argument("repo_root", type=Path)
    parser.add_argument(
        "--only-spi",
        action="store_true",
        help="emit only symbols marked SPI by the Swift symbol graph",
    )
    args = parser.parse_args()
    repo_root = args.repo_root
    symbolgraph_dirs = [path for path in (repo_root / ".build").glob("*/symbolgraph") if path.is_dir()]
    if not symbolgraph_dirs:
        raise SystemExit("No Swift symbol graph directory was generated.")

    symbolgraph_dir = max(symbolgraph_dirs, key=lambda path: path.stat().st_mtime)
    included_modules = {
        "InnoNetwork",
        "InnoNetworkAuthAWS",
        "InnoNetworkDownload",
        "InnoNetworkUpload",
        "InnoNetworkHLS",
        "InnoNetworkHLSLive",
        "InnoNetworkHLSAVFoundation",
        "InnoNetworkHLSAudio",
        "InnoNetworkOpenAPI",
        "InnoNetworkPersistentCache",
        "InnoNetworkTrust",
        "InnoNetworkWebSocket",
        "InnoNetworkTestSupport",
    }
    included_kinds = {
        "swift.actor",
        "swift.associatedtype",
        "swift.class",
        "swift.enum",
        "swift.enum.case",
        "swift.func",
        "swift.init",
        "swift.macro",
        "swift.method",
        "swift.property",
        "swift.protocol",
        "swift.struct",
        "swift.type.method",
        "swift.type.property",
        "swift.typealias",
    }
    rows: set[str] = set()
    seen_modules: set[str] = set()

    for path in sorted(symbolgraph_dir.glob("*.symbols.json")):
        if "@" in path.name or path.name.startswith("InnoNetworkPackageTests"):
            continue
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
        module = data.get("module", {}).get("name")
        if module not in included_modules:
            continue
        seen_modules.add(module)
        # Xcode 27 can copy public declarations from an exported dependency
        # into the importing module's symbol graph. Those rows describe the
        # dependency's API, not a declaration owned by this product. Swift
        # USRs encode the declaring module as `s:<length><module>`, which lets
        # the snapshot remain stable across that toolchain behavior.
        swift_usr_prefix = f"s:{len(module)}{module}"
        for symbol in data.get("symbols", []):
            if symbol.get("accessLevel") != "public":
                continue
            if args.only_spi and symbol.get("spi") is not True:
                continue
            precise_identifier = symbol.get("identifier", {}).get("precise", "")
            if not precise_identifier.startswith(swift_usr_prefix):
                continue
            kind = symbol.get("kind", {}).get("identifier")
            if kind not in included_kinds:
                continue
            components = symbol.get("pathComponents") or []
            if not components:
                continue
            rows.add(f"{module}\t{kind}\t{'.'.join(components)}")

    missing_modules = sorted(included_modules - seen_modules)
    if missing_modules:
        raise SystemExit(f"Missing required symbol graphs: {', '.join(missing_modules)}")

    # Xcode 27 omits the public projection synthesized by `@TaskLocal` when
    # `--skip-synthesized-members` is active, even though the projection is a
    # documented consumer API. Preserve that explicit contract while still
    # excluding unrelated synthesized members.
    task_local_source = repo_root / "Sources/InnoNetwork/NetworkContext.swift"
    if not args.only_spi and task_local_source.is_file():
        source = task_local_source.read_text(encoding="utf-8")
        current_row = "InnoNetwork\tswift.type.property\tNetworkContext.current"
        if "@TaskLocal public static var current" in source and current_row in rows:
            rows.add("InnoNetwork\tswift.type.property\tNetworkContext.$current")

    for row in sorted(rows):
        print(row)


if __name__ == "__main__":
    main()
