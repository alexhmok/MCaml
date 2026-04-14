# vscode-mcaml

Syntax highlighting for `.mcaml` files in VS Code.

Highlights keywords (`let`, `fun`, `if`/`then`/`else`, `for`/`to`/`do`/`done`,
`in`, `ref`, `val`, `cmd!`), built-in types (`int`, `bool`, `unit`, `sel`,
`pos`, `arr`, `mat`), operators (`:=`, `|>`, `&&`, `||`, comparisons,
arithmetic, `~`/`^` coordinate prefixes), Minecraft selectors (`@a`, `@e[...]`,
…), `(* block comments *)`, double-quoted strings with escapes, and numeric
literals.

## Install (local dev)

Symlink or copy this directory into your VS Code extensions folder:

```
ln -s "$PWD" ~/.vscode/extensions/vscode-mcaml-0.1.0
```

Then reload VS Code. Open any `.mcaml` file (e.g. `scripts/demo_classifier.mcaml`).

## Package as `.vsix` (optional)

```
npm install -g @vscode/vsce
cd tools/vscode-mcaml
vsce package
```

Produces `vscode-mcaml-0.1.0.vsix`, installable via
`code --install-extension vscode-mcaml-0.1.0.vsix`.
