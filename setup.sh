#!/usr/bin/env bash
# One-shot dev-environment bootstrap for MCaml.
#
#   ./setup.sh          # install toolchain + deps, then build
#   ./setup.sh --check  # only report what's missing, change nothing
#
# Idempotent: safe to re-run; every step is skipped if already satisfied.
set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
miss() { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '\033[1m%s\033[0m\n' "$1"; }
die()  { printf 'error: %s\n' "$1" >&2; exit 1; }

cd "$(dirname "$0")"

# ---------------------------------------------------------------- opam
info "Checking opam (OCaml package manager)..."
if command -v opam >/dev/null 2>&1; then
  ok "opam $(opam --version)"
else
  miss "opam not found"
  [ "$CHECK_ONLY" = 1 ] || {
    case "$(uname -s)" in
      Darwin)
        command -v brew >/dev/null 2>&1 \
          || die "opam is missing and so is Homebrew. Install Homebrew (https://brew.sh) or opam (https://opam.ocaml.org/doc/Install.html) and re-run."
        info "Installing opam via Homebrew..."
        brew install opam
        ;;
      Linux)
        if command -v apt-get >/dev/null 2>&1; then
          info "Installing opam via apt..."
          sudo apt-get update && sudo apt-get install -y opam
        elif command -v dnf >/dev/null 2>&1; then
          info "Installing opam via dnf..."
          sudo dnf install -y opam
        elif command -v pacman >/dev/null 2>&1; then
          info "Installing opam via pacman..."
          sudo pacman -S --noconfirm opam
        else
          die "no known package manager found; install opam manually: https://opam.ocaml.org/doc/Install.html"
        fi
        ;;
      *)
        die "unsupported platform $(uname -s); install opam manually: https://opam.ocaml.org/doc/Install.html"
        ;;
    esac
  }
fi

# ------------------------------------------------- opam init + switch
if command -v opam >/dev/null 2>&1; then
  if ! opam var root >/dev/null 2>&1; then
    miss "opam not initialized"
    [ "$CHECK_ONLY" = 1 ] || {
      info "Initializing opam (this compiles an OCaml toolchain; takes a few minutes)..."
      opam init --auto-setup --yes
    }
  else
    ok "opam initialized (root: $(opam var root))"
  fi
  # Make the current switch visible to the rest of this script.
  eval "$(opam env 2>/dev/null)" || true
fi

# ---------------------------------------------------------- OCaml deps
if command -v opam >/dev/null 2>&1 && opam var root >/dev/null 2>&1; then
  info "Checking OCaml dependencies (from mcaml.opam)..."
  if [ "$CHECK_ONLY" = 1 ]; then
    for pkg in dune alcotest menhir; do
      if opam list --installed --short "$pkg" 2>/dev/null | grep -q .; then
        ok "$pkg"
      else
        miss "$pkg"
      fi
    done
  else
    # --deps-only reads mcaml.opam; --with-test pulls alcotest for `dune test`.
    opam install . --deps-only --with-test --yes
    eval "$(opam env)"
    ok "dependencies installed"
  fi
fi

# ------------------------------------------------------------ python3
info "Checking Python 3 (packager + simulator tooling)..."
if command -v python3 >/dev/null 2>&1; then
  ok "$(python3 --version)"
else
  miss "python3 not found — needed for tools/pack_datapack.py and sim/sim.py (stdlib only, no pip packages)"
fi

# --------------------------------------------------------------- build
if [ "$CHECK_ONLY" = 1 ]; then
  info "Check complete (nothing was installed)."
  exit 0
fi

info "Building..."
dune build
ok "built _build/default/src/main.exe (./mcaml)"

info "Running tests..."
dune test
ok "tests pass"

printf '\nDone. Try it:\n  ./mcaml -o build < scripts/test_all.mcaml\n'
