# MCaml datapack tooling

This directory holds the host-side scripts that wrap MCaml's compiler
output into a loadable Minecraft datapack. See
`~/.claude/plans/mcaml-datapack-packaging.md` for the design.

## Build a datapack

Two-step flow (Stage 5/6 of the plan; the OCaml side has no
`--datapack` flag in v1):

```sh
# 1. compile to a flat directory of .mcfunction files
./mcaml -o build/ < scripts/test_full_chain.mcaml

# 2. wrap the directory into a real datapack
python3 tools/pack_datapack.py \
    --input build/ \
    --name mcaml_test \
    --output dist/mcaml_test/        # or dist/mcaml_test.zip
```

The packager copies every `*.mcfunction` from `--input` into
`data/mcaml/function/` and synthesizes:

- `pack.mcmeta` — `pack_format: 41` (1.20.5 baseline) with
  `supported_formats: [41, 81]` so the same pack loads on 1.21.x.
- `data/mcaml/function/init.mcfunction` — registers the `vars`
  scoreboard objective and zeroes the `mcaml:stk frames` and
  `mcaml:tmp args` storage roots.
- `data/minecraft/tags/function/load.json` — wires `mcaml:init` to
  `#minecraft:load` so the runtime is set up at world load.

The compiler refuses any program that defines a top-level function
named `init` so user code can't clobber the synthesized loader.

## Entrypoint convention (chat-driven invocation)

Once the datapack is dropped into a save's `datapacks/` directory and
`/reload`'d, every compiled top-level function is callable from chat as
`mcaml:<function_name>`. The runtime uses fixed scoreboard slots for
parameters and the return value:

| slot      | objective | role                                |
|-----------|-----------|-------------------------------------|
| `param_0` | `vars`    | first scalar argument               |
| `param_1` | `vars`    | second scalar argument              |
| `param_N` | `vars`    | Nth scalar argument                 |
| `$ret`    | `vars`    | scalar return value                 |

To call `fun add(a: int, b: int): int = a + b` with `a=7`, `b=5`:

```
/scoreboard players set param_0 vars 7
/scoreboard players set param_1 vars 5
/function mcaml:add
/scoreboard players get $ret vars
```

The last command prints the return value to chat.

`unit`-returning functions still write `$ret` (the codegen treats unit
as `0`); you can ignore it. `cmd!` strings — including `say` — execute
in-line, so output lands in chat as the function runs.

### Worked example: `test_full_chain.mcaml`

This program is parameterless: `main_test()` builds two length-4 arrays
inline and calls `dot`. The chat sequence is just:

```
/function mcaml:main_test
/scoreboard players get $ret vars
```

Expected: `$ret = 70` (`1*5 + 2*6 + 3*7 + 4*8`). Cross-check against
`/tmp/mcaml_out/sim.py` for the same source — both runtimes must
agree.

### Array-taking entrypoints

Currently impossible. Arrays are not first-class runtime values in
M1/M2: a `let a = [| ... |]` binds `a` to a compile-time storage ID,
and arrays can't cross function boundaries from the chat side. Once
microGPT lands and we need real array I/O, we'll add a per-entrypoint
wrapper file that writes the input to `storage mcaml:heap <aid>`,
calls the function, and reads back from the result aid. Out of scope
for v1.
