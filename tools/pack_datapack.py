#!/usr/bin/env python3
"""Package an MCaml `-o` build directory into a loadable Minecraft datapack.

See plans/mcaml-datapack-packaging.md for the design.

Usage:
    python tools/pack_datapack.py --input build/ --name mcaml_test \
        --output dist/mcaml_test.zip
    python tools/pack_datapack.py --input build/ --name mcaml_test \
        --output dist/mcaml_test/

Output mode is picked from the path: trailing `/` or no extension → directory
pack; `.zip` → zipped pack.
"""

import argparse
import json
import os
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

PACK_MCMETA = {
    "pack": {
        "pack_format": 41,
        "supported_formats": [41, 81],
        "description": "MCaml compiled output",
    }
}

INIT_MCFUNCTION = """\
scoreboard objectives add vars dummy
data modify storage mcaml:stk frames set value []
data modify storage mcaml:tmp args set value {}
data modify storage mcaml:conspool pairs set value []
data modify storage mcaml:scratch cells set value []
data modify storage mcaml:permheap cells set value []
data modify storage mcaml:region_tmp conspool set value []
data modify storage mcaml:region_tmp scratch set value []
scoreboard players set $conspool_next vars 0
scoreboard players set $scratch_next vars 0
scoreboard players set $permheap_next vars 0
"""

LOAD_JSON = {"values": ["mcaml:init"]}

DETERMINISTIC_DATE = (2000, 1, 1, 0, 0, 0)


def die(msg: str) -> None:
    print(f"pack_datapack: error: {msg}", file=sys.stderr)
    sys.exit(1)


def collect_mcfunctions(input_dir: Path) -> list[Path]:
    files = sorted(p for p in input_dir.iterdir()
                   if p.is_file() and p.suffix == ".mcfunction")
    if not files:
        die(f"no .mcfunction files in {input_dir}")
    if any(p.name == "init.mcfunction" for p in files):
        die(f"refusing to overwrite existing init.mcfunction in {input_dir} "
            "(reserved for the synthesized load function)")
    return files


def build_tree(staging: Path, name: str, sources: list[Path]) -> None:
    pack_root = staging / name
    fn_dir = pack_root / "data" / "mcaml" / "function"
    tag_dir = pack_root / "data" / "minecraft" / "tags" / "function"
    fn_dir.mkdir(parents=True)
    tag_dir.mkdir(parents=True)

    (pack_root / "pack.mcmeta").write_text(
        json.dumps(PACK_MCMETA, indent=2) + "\n"
    )
    (fn_dir / "init.mcfunction").write_text(INIT_MCFUNCTION)
    (tag_dir / "load.json").write_text(
        json.dumps(LOAD_JSON, indent=2) + "\n"
    )
    for src in sources:
        shutil.copyfile(src, fn_dir / src.name)


def emit_directory(staging_pack: Path, output: Path) -> None:
    if output.exists():
        shutil.rmtree(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(staging_pack, output)


def emit_zip(staging_pack: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()
    entries: list[tuple[str, Path]] = []
    for path in staging_pack.rglob("*"):
        if path.is_file():
            arc = path.relative_to(staging_pack).as_posix()
            entries.append((arc, path))
    entries.sort(key=lambda e: e[0])
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as zf:
        for arc, path in entries:
            info = zipfile.ZipInfo(arc, date_time=DETERMINISTIC_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, path.read_bytes())


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", required=True, type=Path,
                    help="MCaml -o output directory")
    ap.add_argument("--name", required=True,
                    help="datapack name (root dir name inside the pack)")
    ap.add_argument("--output", required=True, type=Path,
                    help="output path: .zip for zipped pack, dir for loose")
    args = ap.parse_args()

    if not args.input.is_dir():
        die(f"--input {args.input} is not a directory")

    sources = collect_mcfunctions(args.input)

    raw = str(args.output)
    zip_mode = raw.endswith(".zip")
    if not zip_mode and not (raw.endswith("/") or args.output.suffix == ""):
        die(f"--output {args.output}: use a .zip extension or a directory path")

    with tempfile.TemporaryDirectory() as td:
        staging = Path(td)
        build_tree(staging, args.name, sources)
        staging_pack = staging / args.name
        if zip_mode:
            emit_zip(staging_pack, args.output)
        else:
            emit_directory(staging_pack, args.output)

    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
