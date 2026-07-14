# vscode-mcaml

Syntax highlighting for `.mcaml` files in VS Code.

Highlights:

- **Keywords** — `let`/`in`, `fun`, `if`/`then`/`else`, `match`/`with`/`of`,
  `type`, `for`/`to`/`do`/`done`, `ref`, `val`, `region`, `cmd!`
- **Built-in types** — `int`, `float`, `bool`, `unit`, `sel`, `pos`, `arr`,
  `mat`, `list`, `darr`; type variables (`'a`); function-type arrows
  (`int -> int`)
- **Definitions** — top-level `fun name(...)` and `type name = ...` names
- **ADTs & patterns** — capitalized constructors (`Circle`, `Node`), match-arm
  `|`, wildcard `_`, cons `::`
- **Records** — `{ x = 1; y = 2 }` braces and `.field` access
- **Operators** — `:=`, `!`, `|>`, `&&`/`||`, comparisons, integer and
  float-dotted arithmetic (`+.` `-.` `*.` `/.`), `%`, `~`/`^` coordinate
  prefixes
- **Literals** — Minecraft selectors (`@a`, `@e[...]`, …), `(* block
  comments *)`, double-quoted strings with escapes, integer and float
  numerics

## Install (local dev)

Symlink or copy this directory into your VS Code extensions folder:

```
ln -s "$PWD" ~/.vscode/extensions/vscode-mcaml-0.1.0
```

Then reload VS Code. Open any `.mcaml` file (e.g. `scripts/tests/stress_test.mcaml`).

## Package as `.vsix` (optional)

```
npm install -g @vscode/vsce
cd tools/vscode-mcaml
vsce package
```

Produces `vscode-mcaml-0.2.0.vsix`, installable via
`code --install-extension vscode-mcaml-0.2.0.vsix`.
