# GoLens file-type icons

37 custom symbols for the project navigator, tabs and Quick Open: Go files (multicolor gopher after Renée French's Go gopher),
containers and deployment (Docker, Compose, Kubernetes, Helm, Terraform), data formats, docs, tooling,
web files and badged Go-layout folders. Open `preview.html` for the whole set, a mock sidebar and the
grayscale test; static renders live in `preview/`.

| Path | What |
|---|---|
| `symbols/<name>.svg` | SF Symbols variable template (Ultralight-S, Regular-S, Black-S masters, annotated layers) |
| `template/<name>.svg`, `.pdf` | Single-color 16 x 16 pt fallback, `isTemplate`-ready (works with plain `swift build`). For the gopher icons this is the one-color cut-out silhouette |
| `template/<name>-color-<variant>.svg`, `.pdf` | Gopher icons only (`go`, `go-test`, `go-generated`): flat multicolor artwork, variant = `light`, `dark`, `light-hc`, `dark-hc` |
| `mapping.json` | Detection rules: file/folder name, glob, path, extension, content, sibling files -> icon + palette key |
| `palette.json` | Identity tints (light, dark, Increase Contrast), contrast ratios, rendering modes, monochrome |
| `preview.html` | Self-contained preview; `?view=grid-light|grid-dark|sidebar|hc|gray|zoom` isolates a section |
| `tools/` | Generator (`build.py`, `icons.py`, `geometry.py`, `gopher.py` for the multicolor gopher), `preview.py`, `render-previews.sh` |

## Design rules

- **One construction.** Every glyph is drawn from centre lines with one stroke weight (Regular = 8.4 template
  units at Medium, the same as SF `doc`), round caps and joins, corner radius >= 10 units. Fills (pupils,
  container blocks, lock body) grow slightly with weight, like SF counters. Exception: the gopher family
  (`tools/gopher.py`) is filled, flat multicolor artwork on a 32-unit grid (16 pt), like Xcode's Swift file
  glyph, with eyes, pupils and eye line on whole pixels at 1x. Its one-color version cuts the eye whites
  and teeth out of the silhouette and keeps the pupils, so it reads at 16 px when colored icons are off and
  in white on a selected row.
- **Optical size matches the system.** Pages are 82 x 104 units like SF `doc` (83 x 105), folders 108 x 86 like
  SF `folder`, square glyphs about 100 x 100; all centred on half cap height, so they sit on the text
  baseline in a 12-13 pt row. Verified side by side with `doc`, `folder`, `shippingbox` in
  `preview/compiled-symbols-appkit-2x.png`.
- **Distinct silhouettes, not just inner marks.** Strong technologies get a standalone glyph: full-body
  gopher (bean body, ears, big eyes, buck teeth), cube, whale, Kubernetes heptagon with an asterisk, Helm ship's helm (round rim, solid hub,
  knobbed handles, no inner spokes), layers, cylinder, branch. JSON `{ }` and TOML `[ = ]` are standalone
  glyphs, Go templates are two stacked pages, and the remaining formats use the page with one centred mark.
  Folders are one filled folder glyph with a thin gap under the tab (the SF `folder.fill` idea, drawn
  from the same outline as before). Go-layout badges are knocked out of the front panel at 1.2x, like
  Finder's special folders, so every folder keeps one silhouette and the badge stays legible at 16 px.
  Expanded folders keep the same glyph, like Xcode and Finder (the disclosure triangle shows state).
  GoLens itself maps every folder to the plain `folder` (owner decision 2026-11-05: one consistent accent
  folder family, like Xcode's navigator; badges pulled the eye away from the name). The badged folder
  glyphs stay in this set for the shared kit and showcases but are not mapped or bundled in the app.
- **Shared badges mean the same thing everywhere:** check = test (`go-test`, `folder-testdata`),
  no-sign = ignore (`.gitignore`, `.dockerignore`), lock = locked or private (`go.sum`, `internal/`),
  prompt = commands (`.sh`, `cmd/`), gear = generated (`*.pb.go`, `// Code generated ... DO NOT EDIT.`; the gear
  reads better than a bolt at 16 px @1x).
- **Layers.** Structure (page, head outline, heptagon) is `secondary`; the identity mark is
  `primary`; badge gaps are `erase` layers (`-sfsymbols-clear-behind`). The filled folder is `primary`;
  its tab gap and knocked-out badges are `erase` layers. A single tint works in hierarchical
  mode with no extra colors.
- **Color is family, never state.** Four tints plus neutral (`palette.json`): Go = cyan, infra = indigo,
  data = purple, web = pink, everything else = `secondaryLabelColor`. None reuses GoLens's reserved hues
  (accent blue = selection, red = error, orange = warning, green = success, DESIGN_SYSTEM.md 2.1). Docs
  and tooling stay neutral on purpose (HIG Sidebars: icon color must serve a clear purpose). Exception
  (owner decision 2026-11-05): folders use the active theme's accent, like the Xcode and Finder
  navigators (`accent` in `palette.json`; the Xcode (System) theme follows the macOS accent color). At
  runtime `FileIconPalette.accent` blends the accent toward black (light) or white (dark) only as far as
  needed for 3:1 (4.5:1 with Increase Contrast) against the sidebar backgrounds.
  Every tint is >= 3:1 against light, dark and unemphasized-selection sidebar backgrounds, and >= 5:1 in
  its Increase Contrast variant. Shape alone identifies every icon (see `preview/grayscale-2x.png`).
- **Selected row:** white on the emphasized (accent) selection, tint kept on unemphasized selection.

## Import into the SF Symbols app or an asset catalog

1. SF Symbols app (not tested here, the app was not installed): File > Import, select `symbols/*.svg`. Each file is a variable template,
   so the app interpolates all 9 weights and 3 scales. Rename to `golens.<name>` if asked. Annotation
   (primary/secondary/erase) is already in the file; check it in the Rendering inspector.
2. Xcode asset catalog: drag `symbols/<name>.svg` into an `.xcassets`, or create
   `golens.<name>.symbolset/` with the SVG and a `Contents.json` (`"symbols":[{"filename":"golens.<name>.svg","idiom":"universal"}]`).
   All 37 files compile with `actool` from Xcode 26.6 without warnings (deployment target macOS 14).
3. Command line, no Xcode project (GoLens uses SwiftPM, and `swift build` does not compile asset catalogs):
   ```sh
   xcrun actool --compile desktop/Resources --platform macosx --minimum-deployment-target 14.0 FileIcons.xcassets
   ```
   puts `Assets.car` in `Resources`; load with `NSImage(symbolName: "golens.go", bundle: .module, variableValue: 1)`.

## `FileIconView` architecture & integration

Owner decision: tinted icons are the default; a Settings toggle "Colored file icons" switches to
monochrome. `palette.json` is the single source of the tint values. Default path (no build changes):
ship the PDFs.

1. Copy `template/*.pdf` to `desktop/Resources/FileIcons/`, with `mapping.json` and `palette.json` beside
   them (already covered by `.process("Resources")`).
2. Add a small `FileIconResolver` that loads `mapping.json` once and returns `(icon, palette)` for a URL.
   Name, glob, path and extension rules are synchronous. Content rules (Kubernetes `apiVersion` + `kind`,
   generated Go header) run off the main thread, are cached per `(path, mtime)`, and show the rule's
   `until` icon until the read finishes. Folder rules need the folder's child names, which the tree has.
3. Load and draw as a template image so SwiftUI tints it:
   ```swift
   let image = Bundle.module.image(forResource: icon)   // PDF, 16 x 16 pt
   image?.isTemplate = true
   Image(nsImage: image ?? fallback)
       .renderingMode(.template).resizable().frame(width: 16, height: 16)
       .foregroundStyle(isSelected ? AnyShapeStyle(.white) : style)
       .accessibilityHidden(true)                          // the row already reads the file name
   ```
   `style` is the palette tint (default; the theme accent for `accent`), or `.secondary` for `neutral` and
   when the toggle is off.
   Multicolor icons (the gopher family): when colored icons are on and the row is not on the emphasized
   selection, `FileIconResolver.colorImage(_:dark:highContrast:)` returns `<name>-color-<variant>.pdf`
   for SwiftUI's `colorScheme` and `colorSchemeContrast`, drawn with `.renderingMode(.original)`; otherwise
   the template silhouette above is used. Copy those PDFs to `desktop/Resources/FileIcons/` too. The SF
   Symbols templates for the gopher hold only the one-color silhouette; the colors live in the PDFs.
4. Tints: a `FileIconPalette` decodes the bundled `palette.json` once and builds one
   `NSColor(name:dynamicProvider:)` per key, picking `light`, `dark`, `lightHighContrast` or
   `darkHighContrast` with `appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
   .accessibilityHighContrastDarkAqua])`. `neutral` maps to `NSColor.secondaryLabelColor`. No tint values
   are copied into Swift, so `palette.json` stays the single source.
5. Settings toggle "Colored file icons" (`@AppStorage`, default on = tinted). Off = monochrome: every icon
   `.secondary`, the previous GoLens rule.
6. Optional upgrade: compile `symbols/` with actool (step 3 above) and swap the PDF for
   `Image("golens.\(icon)", bundle: .module)` with `.font(.system(size: 12))` and
   `.symbolRenderingMode(.monochrome)`. This gains weight matching and baseline alignment with the row text.
   Use `.hierarchical` only at 20 pt and up: secondary layers drop below 3:1 at sidebar size.
7. Update DESIGN_SYSTEM.md 2.5 (file type icons) in the same change: tinted by default, the toggle, and a
   link to `palette.json`. The identity-tint exception is already recorded in DESIGN_SYSTEM.md.

## Regenerate

```sh
python3 -m venv .venv && .venv/bin/pip install skia-pathops fonttools   # boolean ops; SVG path parsing for the gopher
.venv/bin/python tools/build.py      # symbols/, template/ (+ PDF via rsvg-convert), tools/preview-data.json
python3 tools/preview.py             # preview.html
tools/render-previews.sh             # preview/*.png with headless Chrome (no window)
```

Edit a glyph in `tools/icons.py`; the generator keeps point structure identical across masters, so
interpolation stays valid. Add new file types to `mapping.json`, labels to `LABELS` in `icons.py`.

## Attribution

- **Go gopher.** The `go`, `go-test` and `go-generated` glyphs are an original drawing after the Go gopher,
  designed by Renée French and licensed under Creative Commons Attribution 4.0
  (https://creativecommons.org/licenses/by/4.0/; verified from `golang/website` `_content/doc/gopher/README`
  and https://go.dev/blog/gopher on 2026-10-30). Proportions follow her model sheet; nothing was traced.
  Changes: simplified to a flat 16 pt file glyph (bean body, ears, eyes, muzzle, teeth, paws) with a test
  check or generated gear badge. Keep this notice (GoLens's About / acknowledgements) wherever the icons ship.
  Other gopher sources reviewed during the redesign and not used: Egon Elbre's gophers (CC0 1.0),
  MariaLetta/free-gophers-pack (CC0 1.0), Material Icon Theme `go_gopher.svg` (MIT); no notice is needed
  for them. JetBrains/GoLand icons were only rendered as a quality benchmark, never copied or traced.
- **Trademarks.** Go, Docker, Kubernetes (CNCF / Linux Foundation), Helm, Terraform (HashiCorp),
  Protocol Buffers, GraphQL, GitHub, Git, JavaScript, TypeScript and Markdown are names or trademarks of
  their owners. The glyphs here are original simple drawings that only evoke each technology so files can
  be told apart in a personal IDE. No official logo file was copied or traced, and the icons imply no
  endorsement. Do not use them as logos for those projects. The Markdown glyph follows the public-domain
  "M + down arrow" convention.
- **No third-party icon art.** Nothing comes from JetBrains/GoLand or other icon sets; GoLand file names
  were used only as a checklist of concepts. The SF Symbols template structure (guides, H reference) follows
  Apple's template format; no SF Symbol artwork is included, and these symbols must not be used as an app
  icon or logo (Apple SF Symbols terms).
