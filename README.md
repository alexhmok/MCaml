# MCaml

MCaml is a small ML-family language that compiles to Minecraft
`.mcfunction` files. You write ordinary functional code — typed
functions, pattern matching, closures, arrays — and the compiler emits
a flat directory of command files that run in **vanilla Minecraft**
(1.20.5+, no mods): integers live in a scoreboard objective, structured
data lives in command storage, and control flow becomes `execute
if/unless` chains and `function` dispatch.

The compiler is written in OCaml and built around a real optimizing
middle end: programs are lowered through A-normal form to a CFG-based
IR, then optimized before command emission. Because every emitted
command has a per-tick execution cost in-game, the optimizer is not
cosmetic — it is the difference between a loop that finishes in one
tick and one that freezes the server.

### Language features

- Hindley–Milner type inference with `int`, `bool`, `unit`, `float`
  (Q16.16 fixed-point, backed by scoreboard ints), `sel` (entity
  selector), `pos` (position)
- Algebraic data types, `match` with exhaustiveness/usefulness checking,
  tuples, records, cons lists
- First-class functions: lambdas, closures, and function-typed
  parameters (uncurried, no partial application)
- Arrays (`arr`), matrices (`mat`), dynamic arrays (`darr`), and `ref`
  cells
- `for` loops, `if/else`, sequencing, tail-call optimization
  (self-recursive tail calls become in-place loops)
- `cmd! "..."` — embed a raw Minecraft command anywhere
- A generated standard math library (`lib/math.mcaml`): `exp`, `log`,
  `sigmoid`, `tanh`, `gelu`, etc. over Q16.16 values

### Optimizer

Per-function passes run over the CFG IR: constant folding, copy
propagation, local CSE, and dead-code elimination to a fixed point,
plus a loop pass (LICM, strength reduction, full unrolling of counted
loops, scalar replacement of aggregates). Whole-program passes include
a leaf-call inliner, monomorphization of array-parameter templates, and
closure specialization (turning closure dispatch into direct calls).
Every pass has an environment-variable kill switch for A/B measurement
(see [Flags and options](#flags-and-options)).

Two correctness mechanisms protect the server regardless of
optimization level: **tick_split** fans oversized files into
`schedule`-chained continuations, and **tick_guard** gives every
compiled loop a per-tick iteration budget so long-running work spreads
across ticks instead of stalling one.

### Example

```ocaml
(* Tail-recursive Fibonacci: the self-call compiles to an in-place
   loop, not a stack of function frames. *)
fun fib(n: int, a: int, b: int): int =
  if n = 0 then a
  else if n = 1 then b
  else fib(n - 1, b, a + b)

fun main(): int =
  let result = fib(10, 0, 1) in (
    if result = 55 then cmd! "say fib(10) = 55"
    else cmd! "say something is wrong";
    result
  )
```

In-game, after loading the compiled datapack: run
`/function mcaml:main`, then read the return value with
`/scoreboard players get $ret vars`.

## Language reference

A program is a sequence of top-level declarations, read from stdin:
`type` declarations, `val` globals, and `fun` definitions. Declarations
must appear before use (source order matters for types and for
polymorphic functions). Comments are OCaml-style `(* … *)`.

### Functions, bindings, control flow

```ocaml
fun add(a: int, b: int): int = a + b     (* annotations optional — *)
fun id(x) = x                            (* full HM inference; id : 'a -> 'a *)

fun demo(n: int): int =
  let x = add(n, 1) in       (* let-in binding *)
  let r = ref 0 in           (* mutable ref cell *)
  for i = 0 to n do          (* upper bound is EXCLUSIVE: i in 0..n-1 *)
    r := !r + i              (* := writes, ! reads *)
  done;                      (* ; sequences expressions *)
  if x > 10 then !r else x   (* if/else is an expression *)
```

Functions are uncurried and called `f(x, y)`. Self-recursive **tail**
calls are compiled to in-place loops (no stack frames), so
accumulator-style recursion is the idiomatic way to loop when `for`
doesn't fit. Polymorphic functions compile once — a single uniform
version, not per-type clones.

### Types

| Type | Values |
| --- | --- |
| `int`, `bool`, `unit` | Booleans are scoreboard ints 0/1. |
| `float` | Q16.16 fixed-point (see below). |
| `arr[int, N]` / `arr[float, N]` | Fixed-length static array. |
| `mat[int, M, N]` / `mat[float, M, N]` | Static matrix; a nested array literal with uniform inner lengths promotes to `mat`. |
| `darr` | Dynamic array of ints (`array_make` / `array_get` / `array_set`). |
| `list` | Cons list of ints. |
| `t1 * t2 * …` | Tuple. |
| `{ f1 : t; … }` | Record (declared via `type`). |
| `t -> t`, `(t1, t2) -> t` | Function value. N-ary annotations use the parenthesized comma form; `t1 * t2 -> t` is a one-argument function taking a tuple. |
| `sel`, `pos` | Minecraft entity selector / position (see interop). |

### Numbers

Integer `/` and `%` are **floor** division and modulo (`-7 / 2 = -4`,
`-7 % 3 = 2`) — this matches vanilla scoreboard `/=` / `%=`, not
OCaml's truncating operators.

`float` is Q16.16 fixed-point: the real value ×65536, stored in a
scoreboard int. Literals are written normally (`0.5`, `2.0`); float
arithmetic uses the dotted operators `+.` `-.` `*.` `/.` and unary
`~-.`. A `float` returned to chat via `$ret` reads back as the raw
encoded int (e.g. `3.0` reads as `196608`). `lib/math.mcaml` provides
`exp_fixed`, `log_fixed`, `sigmoid_fixed`, `tanh_fixed`, `gelu_fixed`,
`relu_f`, and friends over this encoding.

### Arrays and matrices

```ocaml
val lut = [| 10; 20; 30; 40; 50 |]      (* top-level global (load-time init) *)

fun demo(): int =
  let a = [| 1; 2; 3; 4 |] in            (* static array literal *)
  a[0] := a[0] + lut[2];                 (* indexed read/write *)
  let m = [| [| 1; 2 |]; [| 3; 4 |] |] in  (* promotes to mat[int, 2, 2] *)
  a[0] + m[1, 0]                         (* matrix indexing: m[i, j] *)
```

Static arrays live at fixed storage locations chosen at compile time.
They can be passed to functions as typed parameters (the compiler
specializes the callee per array — monomorphization) but are not
first-class values. Dynamic arrays (`darr`) are pool-allocated at
runtime: `let a = array_make(len, init)`, `array_get(a, i)`,
`array_set(a, i, v)`.

### Lists, tuples, records, ADTs, pattern matching

```ocaml
type shape = Point | Circle of int | Rect of int * int
type point = { x : int; y : int }

fun area(s: shape): int =
  match s with
  | Point      -> 0
  | Circle(r)  -> 3 * r * r
  | Rect(w, h) -> w * h

fun sum(l: list, acc: int): int =
  match l with
  | []     -> acc
  | h :: t -> sum(t, acc + h)      (* tail call -> loop *)

fun demo(): int =
  let l = [1; 2; 3] in             (* sugar for 1 :: 2 :: 3 :: [] *)
  let (a, b) = (4, 5) in           (* tuple + destructuring let *)
  let p = { x = 9; y = 16 } in     (* record literal, field access p.x *)
  area(Rect(a, b)) + sum(l, 0) + p.x + p.y
```

Type declarations can be parameterized: `type 'a box = Box of 'a`,
`type ('a, 'b) either = Left of 'a | Right of 'b`. Application is
postfix — `int box`, `int box box`, `(int * int) box` — with the
parenthesized comma form for multi-argument types: `(int, bool) either`.
Records cannot be parameterized yet.

Patterns nest (`Node(Leaf(a), _)`), support int literals, wildcards
(`_`), and variable binders; the checker rejects non-exhaustive and
redundant matches. Lists also have builtin accessors `head`, `tail`,
`is_nil`, composable with the pipeline operator: `l |> head`.

All heap values — lists, tuples, records, ADTs, closures — are
represented at runtime as a single int **handle**, so they pass through
`param_N` / `$ret` like any int. Public entry points invoked from chat
should return a primitive, not a handle.

### First-class functions

```ocaml
fun apply_twice(f: int -> int, x: int): int = f(f(x))

fun demo(): int =
  let k = 10 in
  let add_k = fun (y: int) -> y + k in    (* lambda, captures k *)
  apply_twice(add_k, 5)                   (* HOF call *)
```

Lambdas capture by value. When the compiler can resolve which lambda
reaches a call site (the common case), the closure is specialized away
entirely — no allocation, no dispatch. Unresolvable cases fall back to
runtime dispatch; set `MCAML_STRICT_HOT=1` to turn dispatch inside a
hot loop into a compile error.

Closures also flow through factory returns
(`let g = make_adder(5) in g(10)`), `ref` cells
(`let r = ref (fun …) in …; let g = !r in g(4)` — always dispatched at
runtime, so an overwritten ref calls the latest value), and plain
aliases (`let h = f`). Still rejected, loudly: storing a closure in a
tuple/record/ADT field, and call-position locals the compiler can't
prove closure-typed (e.g. the result of a closure that itself returns
a closure).

Explicit partial application works on top-level functions: an
under-applied call evaluates the supplied arguments once and yields a
closure over the rest — `let add5 = add(5) in add5(10)`, or `add()` to
use a named function as a value. There is no implicit currying
(`f(1)(2)` is not syntax), and functions taking array/matrix/`ref`
parameters can't be partially applied (those arguments aren't
first-class values).

### Regions

`region (fun () -> …)` runs its body in an arena: heap allocations made
inside are freed when the region exits. A list returned from a region
is deep-copied into the enclosing region first. Use this to keep
long-running loops from growing the object pool without bound.

```ocaml
fun demo(): int =
  region (fun () ->
    let l = [1; 2; 3; 4; 5] in
    sum(l, 0))                (* int escapes; the list is reclaimed *)
```

### Minecraft interop

```ocaml
fun demo(): int =
  cmd! "say hello from MCaml";
  cmd! "tellraw @a [{\"score\":{\"name\":\"$ret\",\"objective\":\"vars\"}}]";
  0
```

`cmd!` is the escape hatch — its string is emitted verbatim as one
command, so anything the game accepts is expressible, including reading
compiler-managed scoreboard slots like `$ret` (see
[Runtime conventions](#runtime-conventions)). Selectors (`@p`,
`@e[type=cow]`, …) and positions (`<~, ~1, ~>` — absolute, `~` relative,
`^` local parts) are also literal forms with types `sel` and `pos`;
they resolve at compile time and are currently inert at runtime —
in practice you write selectors and coordinates directly inside `cmd!`
strings.

## Building

### Quick start

```sh
cd MCaml
./setup.sh        # installs opam + OCaml deps if missing, builds, runs tests
```

`setup.sh` is idempotent — it skips anything already installed. Run
`./setup.sh --check` to see what's missing without changing anything.
It installs opam via your system package manager (Homebrew / apt /
dnf / pacman) if absent, initializes it, then installs the OCaml
dependencies declared in `mcaml.opam`.

### Manual setup

If you already have [opam](https://opam.ocaml.org/doc/Install.html):

```sh
opam install . --deps-only --with-test   # dune, menhir, alcotest (test-only)
dune build                               # produces _build/default/src/main.exe
```

Prerequisites (what the above installs):

- OCaml (≥ 4.14) and [dune](https://dune.build/) 3.0+
- `ocamllex` (ships with OCaml) and
  [menhir](http://gallium.inria.fr/~fpottier/menhir/) — only needed if
  you modify the lexer or grammar; generated
  `lexer.ml` / `parser.ml` / `parser.mli` are checked in
- [alcotest](https://github.com/mirage/alcotest) — test-only, for
  `dune test`
- Python 3 (stdlib only, no pip packages) — for the datapack packager
  and simulator tooling in `tools/`

Dependencies are declared in `dune-project` (the `package` stanza);
`mcaml.opam` is generated from it by `dune build` — edit the former,
never the latter.

`./mcaml` at the repo root is a symlink to the built executable.

If you change `src/lexer.mll` or `src/parser.mly`, regenerate the
checked-in sources first, then rebuild:

```sh
cd src
ocamllex lexer.mll     # regenerates lexer.ml
menhir parser.mly      # regenerates parser.ml / parser.mli
```

Each module has a checked-in `.mli` containing its full inferred
signature; if you change a module's public shape, refresh its `.mli`
(e.g. with `ocamlc -i`).

## Usage

The compiler reads one program from **stdin** and writes one
`.mcfunction` file per compiled function:

```sh
./mcaml -o build < scripts/tests/test_all.mcaml    # files land in build/
MCAML_OUT=build ./mcaml < prog.mcaml         # env-var alternative
./mcaml < prog.mcaml                         # no flag: files land in cwd
```

The output directory is created if it doesn't exist. There is no module
system yet (no namespacing), but a program can splice other files in
with an `include` directive — a line consisting of exactly
`include "path"` is replaced by that file's contents before lexing:

```ocaml
include "lib/math.mcaml"

fun main(): float = relu_f(3.0)
```

Relative paths resolve against the including file's directory (against
the cwd for the stdin program itself); each file is spliced at most
once per compile, which also makes include cycles harmless; a missing
file is a compile error. Since the semantics are exactly `cat`,
declaration order still matters: include a library before using its
names. Plain concatenation keeps working too:

```sh
cat lib/math.mcaml my_prog.mcaml | ./mcaml -o build
```

### Packaging a datapack

The compiler's output is a flat directory; `tools/pack_datapack.py`
wraps it into a loadable datapack:

```sh
./mcaml -o build < prog.mcaml
python3 tools/pack_datapack.py \
    --input build/ \
    --name my_pack \
    --output dist/my_pack/       # or dist/my_pack.zip
```

The packager copies every `.mcfunction` into `data/mcaml/function/` and
synthesizes `pack.mcmeta` (loads on 1.20.5 through 1.21.x), an
`init.mcfunction` that sets up the scoreboard objective and storage
roots, and a `load.json` tag that runs it at world load. The function
name `init` is reserved by the compiler for this reason. Zip output is
deterministic — rebuilding an unchanged program produces a
byte-identical archive.

Drop the pack into a world's `datapacks/` directory and run `/reload` and `/function mcaml:init`
in game to set up registers and storage.

### Calling compiled functions in-game

Every top-level function is callable from chat:

1. Set arguments: `/scoreboard players set param_0 vars 10` (then
   `param_1`, `param_2`, … for further arguments).
2. Run it: `/function mcaml:<name>`.
3. Read the result: `/scoreboard players get $ret vars`.

`$ret` is only guaranteed until the next function call. If a
computation spreads across ticks (a long loop under tick_guard), store
the final result in a `ref` inside the program and read its
`$ref_result_<N>` slot instead — see `scripts/demos/demo_classifier.mcaml`
for the pattern.

### Example programs

`scripts/` contains the test corpus, from single-feature smoke tests
(`test_fib_tco.mcaml`, `test_ref.mcaml`, `test_adts.mcaml`, …) to full
suites (`mc_test_suite.mcaml`) and an end-to-end demo
(`demo_classifier.mcaml`).

## Flags and options

### Command line

| Flag | Meaning |
| --- | --- |
| `-o <dir>` | Output directory for `.mcfunction` files (created if missing). Takes precedence over `MCAML_OUT`. Default: current directory. |

Everything else is controlled by environment variables, set per
invocation: `MCAML_NO_UNROLL=1 ./mcaml -o build < prog.mcaml`.

### Output

| Variable | Meaning |
| --- | --- |
| `MCAML_OUT=<dir>` | Output directory when `-o` is not given. |

### Optimization switches

Each pass can be disabled individually for A/B measurement, or all at
once with `MCAML_O0`.

| Variable | Disables |
| --- | --- |
| `MCAML_O0=1` | **All seven** pass flags below at once — the unoptimized baseline. Monomorphization, tick_split, and tick_guard still run: they are correctness mechanisms, not optimizations. |
| `MCAML_NO_INLINE=1` | Leaf-call inliner (whole-program Phase 2). |
| `MCAML_NO_CLOSURE_SPEC=1` | Closure specialization (rewriting closure dispatch to direct calls). |
| `MCAML_NO_M3A=1` | The scalar fixed point: constant folding, copy propagation, local CSE, DCE (both sweeps). |
| `MCAML_NO_LICM=1` | Loop-invariant code motion (hoisting array initializers out of loops). |
| `MCAML_NO_SR=1` | Strength reduction (per-iteration index multiplies → carried increments). |
| `MCAML_NO_UNROLL=1` | Full unrolling of counted `for`-loop helpers. |
| `MCAML_NO_SROA=1` | Scalar replacement of aggregates (small static-access arrays → registers). |

### Optimization tuning

| Variable | Default | Meaning |
| --- | --- | --- |
| `MCAML_UNROLL_LIMIT=N` | 16 | Maximum trip count a loop may have to be fully unrolled. |
| `MCAML_SROA_LIMIT=N` | 16 | Maximum array length eligible for scalar promotion. |
| `MCAML_SPECIALIZE_LIMIT=N` | 8 | Maximum specialized clones per closure-taking function. |

### Tick safety

| Variable | Default | Meaning |
| --- | --- | --- |
| `MCAML_NO_TICK_SPLIT=1` | off | Skip splitting oversized files into scheduled continuation chains. |
| `MCAML_NO_TICK_GUARD=1` | off | Skip the per-loop per-tick iteration budget guard. |
| `MCAML_TICK_BUDGET=N` | 50000 | Command-count threshold above which a file is split. |
| `MCAML_TICK_COMMANDS=N` | 60000 | Per-tick command budget for tick_guard; each guarded loop's iteration limit is `N / its per-iteration body cost`. |
| `MCAML_LOOP_ITER_LIMIT=N` | — | Legacy override: a uniform per-tick iteration limit for every guarded loop, ignoring per-iteration cost. |

Disabling tick safety is only appropriate for simulator runs or
programs you know terminate quickly — an unguarded hot loop can freeze
a real server for the duration of the computation.

### Diagnostics

All dumps go to stderr; compilation output is unaffected.

| Variable | Meaning |
| --- | --- |
| `MCAML_DUMP_CFG=1` | Dump the post-regalloc CFG and emitted commands per function. |
| `MCAML_DUMP_LOOPS=1` | Dump immediate dominators and detected natural loops. |
| `MCAML_DUMP_IV=1` | Dump the strength-reduction induction-variable analysis per function. |
| `MCAML_DUMP_COSTS=1` | Dump the estimated per-file command cost after lowering. |
| `MCAML_STRICT_HOT=1` | Turn the "closure dispatched inside a hot loop" diagnostic into a hard compile error, instead of best-effort annotation. Useful when a loop body must stay allocation- and dispatch-free. |

## Testing and simulation

You don't need a running Minecraft server to test compiled output.
`sim/sim.py` is a Python model of the exact command subset MCaml
emits — scoreboard set/operation, `execute if/unless … matches`,
`execute store success/result`, `function` dispatch with macro
arguments, `data modify storage`, `$(key)` macro substitution,
`return 0`, and `return run` — so a suite can compile a program,
"run" a function file-by-file, and assert on `$ret` values and `say`
output.

The regression gate is:

```sh
python3 tools/verify_canary.py
```

It compiles the five canonical test suites (the `mc_test_suite*`,
`stress_test*` sources under `scripts/`, concatenated with
`lib/math.mcaml`), runs each suite's simulator checker
(`tools/sim_check_*.py`), and prints a sha256 hash of every build
directory. Comparing hashes across commits proves a refactor produced
byte-identical output; a hash change means behavior changed and the
sim checkers say whether it's still correct.

For changes that touch codegen, the runtime conventions, or the
packager, `tools/MANUAL_TEST.md` is a five-minute checklist for
verifying a packed datapack inside real Minecraft against the
simulator's expected values.

## Runtime conventions

Everything below is the contract between compiled code and the game —
useful when debugging output, writing `cmd!` lines that cooperate with
compiled code, or reading results from chat.

**Scoreboard.** All integers live in one objective, `vars`. Notable
players (slots):

| Slot | Role |
| --- | --- |
| `$ret` | Return value of the most recent call. Every function writes it on exit, so it is only valid until the next call — and **not across tick boundaries**. For results that must survive ticks, use a `ref` and read its slot. |
| `param_0`, `param_1`, … | Call arguments; set these before `/function mcaml:<name>`. |
| `$r0`, `$r1`, … | Register-allocated locals, per-function pool. |
| `$ref_<name>_<N>` | User `ref` cells. Reserved namespace: no compiler-generated code touches them except your own reads/writes, which is what makes them tick-safe. |
| `$tick_iters_<fname>` | Per-loop iteration counter used by tick_guard (one per guarded loop, so nested loops don't share a budget). |
| `$arr_result`, `$arr_set_val` | Scratch slots for dynamic array indexing helpers. Reserved. |
| `$objpool_next` | Bump pointer for heap-cell allocation. |

**Storage.** Structured data lives in command storage:

- `mcaml:heap <aid>` — static arrays and matrices, one compile-time id
  (`arr3`, …) per source array.
- `mcaml:objpool cells` — the heap: an NBT list of tagged cells backing
  lists, tuples, records, ADTs, and closures. A runtime "value" of any
  of these types is an int index into this list.
- `mcaml:stk frames` — the frame stack for non-tail calls; each frame
  saves the caller's live `$rN` slots.
- `mcaml:tmp args` — argument compound for macro-based dynamic array
  indexing.

**Dispatch.** Every function compiles to `function mcaml:<name>` (plus
synthesized helper files: per-call-site save/restore helpers
`<fname>_callN`, macro getters/setters, loop continuation files).
Self-recursive tail calls compile to `return run function mcaml:<self>`
— this is why the emitted packs require Minecraft **1.20.5+**.

**Semantics pinned to vanilla.** Booleans are 0/1 and `if` tests
`matches 1`; comparisons use `execute store success`; integer division
and modulo are floor-semantics, exactly matching scoreboard `/=` and
`%=` (verified in-game). `sim/sim.py` and the constant folder implement
the same rules, so folded and runtime results always agree.

**Known hazard: calling a long-running loop from a wrapper.** When a
tick_guard-instrumented loop yields mid-run (`schedule … 1t; return 0`),
Minecraft returns control to the *immediate caller* — one level, not
the whole chain. A wrapper entry point that plain-calls such a loop
therefore resumes right away: it reads a partial `$ret`, and — worse —
its own end-of-invocation heap reset then wipes `mcaml:scratch` /
`mcaml:objpool` while the loop's scheduled continuation still depends
on that state next tick (confirmed by direct repro; the full
adjudication lives in a comment block in `src/main.ml`). There is
deliberately no compiler check for this: every self-recursive loop
gets the yield machinery whether or not it will ever exceed its budget
for real inputs, so a static rejection cannot tell "structurally has a
loop" from "will actually span ticks" and broke working programs when
it was tried. The safe pattern (`stress_test.mcaml`'s S8): make the
self-tail loop itself the sole public entry — fold one-time setup into
a first-iteration guard inside it — and store results that must
survive ticks in a `ref`, reading its `$ref_result_<N>` slot from
chat. Loops that stay comfortably under the per-tick budget
(`MCAML_TICK_COMMANDS / body cost` iterations) never yield and are
safe to call from wrappers.

## Compiler architecture

```
source
  → lex → parse → alpha (scope/renaming) → for_lift (for-loops → helper funs)
  Phase 1  (per function)   type check → A-normal form → TCO → CFG
  Phase 2  (whole program)  inline → closure specialization → monomorphize
  Phase 3  (per function)   optimize → register allocation → command emission
  Phase 4  tick_split   (fan oversized files into scheduled continuation chains)
  Phase 5  tick_guard   (per-tick iteration budgets at every self-loop entry)
```

Phase 3's `optimize` is itself two fixed-point sweeps of the scalar
passes (constant folding, copy propagation, local CSE, DCE) around a
loop pass (LICM → strength reduction → unrolling → SROA); the second
sweep cleans up the copy chains the loop pass leaves behind.

Module map (`src/`):

| Area | Modules |
| --- | --- |
| Frontend | `lexer.mll`, `parser.mly` (menhir), `alpha`, `for_lift`, `typing_*` (HM unification, declarations, patterns, inference behind the `typing` facade) |
| Middle end | `knormal` (A-normal form), `tco`, `cfg` / `cfg_build` (the CFG IR every later pass runs on) |
| Whole-program | `inline`, `closure_spec` + `closure_layout`, `monomorphize` |
| Loop analysis | `dominators`, `loop_detect`, `liveness` |
| Optimizations | `optimize` (driver), `const_fold`, `copy_prop`, `local_cse`, `dce`, `licm`, `unroll`, `sroa`, `strength_reduce` |
| Backend | `regalloc_cfg` (linear scan), `codegen_cfg`, `codegen_helpers`, `codegen` |
| Tick safety | `cost` (per-command cost model), `tick_split`, `tick_guard` |
| Driver | `main` |

A distinctive IR detail: CFG blocks carry a **guard chain** — the stack
of branch conditions enclosing the block. Codegen folds the chain into
single-head `execute if … unless … run` prefixes instead of nested
dispatch, and liveness treats every guard condition as live through its
whole block, which is the correctness linchpin for conditions used
inside their own branches.
