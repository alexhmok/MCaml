# Manual datapack test procedure

A 5-minute checklist for verifying that an MCaml-compiled datapack
loads in real Minecraft and produces the same `$ret` value as the
simulator (`sim/sim.py`). Use this whenever a compiler change touches
codegen, the runtime conventions, or `tools/pack_datapack.py`.

This is the gate that catches what `sim.py` cannot:

- Macro expansion (`function … with storage`, `$(key)` substitution)
  edge cases — Minecraft's parser is the source of truth.
- `pack_format` mismatches — silent at compile time, fatal at load.
- Storage type coercion — `sim.py` is loosely typed; the real runtime
  distinguishes int/long/string and may reject NBT we get away with.
- Command-length and per-tick execution caps for very long unrolled
  bodies.

## Pre-reqs

- Minecraft Java Edition 1.20.5 or later (the `pack_format: 41`
  baseline; `supported_formats: [41, 81]` widens the accepted range
  through 1.21.x).
- A creative-mode test world. A fresh flat world is fine; the test
  suites don't touch blocks or entities. (Exception: the graph
  visualization demo — `mcaml_graph`, see tools/README.md — builds
  block structures around 0,58,0 and summons tagged `text_display`
  entities; `/function mcaml:graph_despawn` removes everything.)
- `mcaml` built from the project root per CLAUDE.md.

## Procedure

1. **Compile a known-good test program.**

   ```sh
   cd /Users/alexmok/MCaml
   ./mcaml -o build/ < scripts/tests/test_full_chain.mcaml
   ```

   `build/` should now contain a flat directory of `.mcfunction`
   files. No `init.mcfunction` — the compiler refuses any user
   program that defines a top-level `init` so the slot stays free for
   the packager.

2. **Pack into the save's `datapacks/` directory.** Use the directory
   form (not `.zip`) so `/reload` picks up edits without re-copying.

   - macOS:
     ```sh
     python3 tools/pack_datapack.py --input build/ --name mcaml_test \
         --output ~/Library/Application\ Support/minecraft/saves/<world>/datapacks/mcaml_test/
     ```
   - Linux:
     ```sh
     python3 tools/pack_datapack.py --input build/ --name mcaml_test \
         --output ~/.minecraft/saves/<world>/datapacks/mcaml_test/
     ```
   - Windows (PowerShell):
     ```powershell
     python tools\pack_datapack.py --input build\ --name mcaml_test `
         --output "$env:APPDATA\.minecraft\saves\<world>\datapacks\mcaml_test\"
     ```

   Replace `<world>` with the test-world folder name.

3. **Reload the datapack.** In the world, run:

   ```
   /reload
   ```

   No errors should appear in chat. If the pack failed to load,
   Minecraft prints the reason here — most commonly a `pack_format`
   mismatch or a malformed JSON file.

4. **Confirm `init` ran.** The `#minecraft:load` tag should have
   already fired `mcaml:init`:

   ```
   /scoreboard objectives list
   ```

   The output must include `vars`. If it doesn't, `init.mcfunction`
   didn't run — check `data/minecraft/tags/function/load.json` in the
   packed datapack. Also confirm the chain limit was raised:

   ```
   /gamerule maxCommandChainLength
   ```

   should print 10000000 (the packer default), not 65536. At the
   vanilla 65536, long-running steps can stop silently mid-chain
   ("Command execution stopped due to limit" appears only in the
   server log, not chat) and any `schedule`-driven animation freezes.

5. **Run the entrypoint.** For `test_full_chain.mcaml` (parameterless):

   ```
   /function mcaml:main_test
   /scoreboard players get $ret vars
   ```

   For a function with scalar parameters (e.g. `fun add(a, b)`), set
   `param_N` first per the convention in `tools/README.md`:

   ```
   /scoreboard players set param_0 vars 7
   /scoreboard players set param_1 vars 5
   /function mcaml:add
   /scoreboard players get $ret vars
   ```

6. **Compare against the simulator.** `sim/sim.py` is a library, not
   a CLI. For the standard test programs, the checked-in expectation
   lives in the matching harness under `/tmp/mcaml_out/` (e.g.
   `test_adts.py`, `test_cons.py`, `test_regions.py`) — run it and
   the in-game `$ret` must match the harness's `want` values:

   ```sh
   python3 /tmp/mcaml_out/test_adts.py
   ```

   (The harnesses are uncommitted by convention; if `/tmp` was
   cleared, regenerate them per DYNMEM_PLAN §2 before comparing.)

   For an ad-hoc program with no harness, drive the sim directly on
   the same `build/` directory you packed:

   ```sh
   python3 - <<'EOF'
   import sys; sys.path.insert(0, "/Users/alexmok/MCaml/sim")
   import sim
   sim.DIR = "/Users/alexmok/MCaml/build"   # the compiled -o dir
   w = sim.World()
   w.storage["mcaml:objpool"]  = {"cells": []}
   w.storage["mcaml:scratch"]  = {"cells": []}
   w.storage["mcaml:permheap"] = {"cells": []}
   w.storage["mcaml:region_tmp"] = {"objpool": [], "scratch": []}
   for s in ("$objpool_next", "$scratch_next", "$permheap_next"):
       w.scores[s] = 0
   sim.run_function(w, "main_test")          # the entry point name
   print("$ret =", w.scores.get("$ret"))
   EOF
   ```

   (The storage/counter seeding mirrors what `mcaml:init` does at
   datapack load — §§4.3/4.5 of DYNMEM_PLAN.md.)

   The two `$ret` values must agree. For `test_full_chain.mcaml` the
   expected value is **70** (`1*5 + 2*6 + 3*7 + 4*8`).

7. **A/B an optimizer toggle.** Recompile with one of the M4 flags
   off, repack, `/reload`, re-check `$ret`. The result must be
   identical — this is the correctness gate for the optimizer toggles
   in a real runtime.

   ```sh
   MCAML_NO_LICM=1 ./mcaml -o build/ < scripts/tests/test_full_chain.mcaml
   python3 tools/pack_datapack.py --input build/ --name mcaml_test \
       --output <save>/datapacks/mcaml_test/
   ```

   In-game: `/reload`, then `/function mcaml:main_test`,
   `/scoreboard players get $ret vars`. Still `70`.

   Repeat for `MCAML_NO_UNROLL=1`, `MCAML_NO_SROA=1`, `MCAML_NO_SR=1`,
   and `MCAML_NO_INLINE=1` whenever you're verifying a change to the
   corresponding pass.

## Troubleshooting

- **`/reload` reports a pack error.** Inspect
  `<save>/datapacks/mcaml_test/pack.mcmeta` — it should be the exact
  literal from `tools/pack_datapack.py::PACK_MCMETA`. If you've edited
  the script, re-pack from a clean `build/`.
- **`$ret` reads as `0` or is missing.** Check
  `/scoreboard objectives list` for `vars`. If it's missing, `init`
  didn't run; verify `data/minecraft/tags/function/load.json`
  contains `{"values": ["mcaml:init"]}`.
- **`/function mcaml:<name>` says "Unknown function".** The compiler
  emits a flat function namespace; confirm the file is in
  `data/mcaml/function/<name>.mcfunction` (not nested in a
  subdirectory). The packager copies every `*.mcfunction` from
  `--input` flat into that directory, so a missing entry means the
  compiler didn't emit it.
- **Result diverges from `sim.py`.** This is the failure mode the
  manual test exists to catch. Capture the source, both `$ret`
  values, the optimizer flag set, and the Minecraft version, then
  report — it's almost certainly a real codegen bug.
