# GoLens Go AST Symbol & Multi-Layer Empty-State Asset Pack

11 custom Go AST & LSP symbol glyphs (`sym-*`) and 7 multi-layer empty-state hero badges (`empty-*`) engineered on the same SF Symbols 3-master variable template and mathematical vector geometry pipeline as [`design/file-icons/`](../file-icons/README.md).

| Path | What |
|---|---|
| `symbols/<name>.svg` | SF Symbols v6.0 variable template (`Ultralight-S`, `Regular-S`, `Black-S` masters, `primary` / `secondary` / `erase` layer annotations) |
| `template/sym-<name>.svg`, `.pdf` | 16 × 16 pt vector template glyphs bundled in `desktop/Resources/SymbolIcons/` |
| `template/empty-<name>.pdf`, `-primary.pdf`, `-secondary.pdf` | 32 × 32 pt multi-layer vector empty-state badges bundled in `desktop/Resources/EmptyStates/` |
| `symbol-mapping.json` | Unified mapping from LSP `SymbolKind` integers, completion kind strings, and `GoDeclaration` kinds to symbol icon + family palette key |
| `preview.html` & `preview/*.png` | Self-contained specimen sheet and `@2x` renders (`symbols-light-2x.png`, `symbols-dark-2x.png`, `popups-mock-2x.png`, `grayscale-2x.png`, `zoom-64px.png`) |
| `tools/` | Generator (`build.py`, `icons.py`, `preview.py`, `render-previews.sh`) |

## Design Rules

- **Distinct silhouettes for every Go AST entity (Grayscale Silhouette Test):**
  Unlike generic letter-in-a-square badges (`s.square`, `i.square`, `v.square`), every Go AST symbol combines a unique outer container silhouette with an inner structural mark:
  - `sym-func`: Circle + hooked italic `ƒ`
  - `sym-method`: Flat-top receiver hexagon + `M`
  - `sym-struct`: Headered record box + 2 memory field rows
  - `sym-interface`: Split contract socket arcs + connection ports + serifed `I`
  - `sym-type`: Rounded diamond + `T`
  - `sym-type-param`: Go generics square brackets `[ T ]`
  - `sym-field`: Leading selector dot `.Field` + horizontal property slot
  - `sym-var`: Pointed-top hexagon cell + `v`
  - `sym-const`: Wide immutable capsule pill + `═`
  - `sym-package`: 3D isometric Go package cube
  - `sym-snippet`: Code template braces `{ •• }`
- **Shared WCAG-verified identity palette (`design/file-icons/palette.json`):**
  - Callable (`func`, `method`) → `go` (cyan)
  - Types (`struct`, `interface`, `type`, `type-param`) → `data` (purple)
  - Members & storage (`field`, `var`, `const`) → `infra` (indigo)
  - Modules & templates (`package`, `snippet`) → `web` (magenta)
  - Respects Settings ▸ General ▸ **Colored File Icons** (`GoLensColoredFileIcons`) and switches to `alternateSelectedControlTextColor` (white) on emphasized selected rows.
- **Multi-Layer Empty-State Hero Badges (`empty-*`):**
  - `empty-profiler`: Tiered Flame Graph bars (`secondary`) + clear-behind gap (`erase`) + Speedometer gauge (`primary`).
  - `empty-safety`: Faceted security shield with AST code tracks (`secondary`) + verification check & concurrency lock (`primary`).
  - `empty-debugger`: Execution call-stack lines (`secondary`) + Breakpoint chevron & step indicator (`primary`).
  - `empty-tests`: Test-suite diamond (`secondary`) + verification check & benchmark target (`primary`).
  - `empty-issues`: Diagnostic radar ring (`secondary`) + clean verification check & badge (`primary`).
  - `empty-git`: Commit trunk (`secondary`) + branch curve & node (`primary`).
  - `empty-terminal`: Console window frame (`secondary`) + shell prompt chevron & cursor (`primary`).
