# GoLens Design System

> Based on Apple Human Interface Guidelines for macOS.

## Approved design language — 2026-11-08 (synchronized 2026-11-12)

**Native, Focused, Explicit** is the normative direction for GoLens, including Gopilot. Read [Design Language](docs/design/design-language.md), [Component Contracts](docs/design/component-contracts.md), and [UI Review Checklist](docs/design/ui-review-checklist.md) before UI work. These owner-approved rules supersede conflicting historical prescriptions below; compatible tokens and the approved file-icon palette remain in force. Current official HIG remains the design authority. Target verification is macOS 26 and later, with Liquid Glass first and accessibility modes included. This specification reflects the shipped macOS 26+ implementation enforced by `scripts/design/token-ratchet.py`, `hig-lint.py`, and `scripts/smoke/gate5-audit.py`.

---

## 1. Design Principles

### 1.1 Aesthetic Integrity
Visual appearance and behavior match the function. GoLens is a code editor — it prioritizes readability, focus, and precision. Every visual element serves a purpose; decorative flourishes are minimal and functional.

### 1.2 Consistency
Use standard macOS patterns (NavigationSplitView, sheets, popovers, menus). People should never wonder whether different words, icons, or gestures mean the same thing. Reuse system controls unless there is a compelling reason to customize.

### 1.3 Direct Manipulation
Let people interact directly with content. Click to place cursor, drag to select, double-click a tab to close. Minimize modal interruptions. Inline renaming in the file tree rather than dialogs.

### 1.4 Feedback
Acknowledge every action. Selection highlights, cursor position, completion popup, diagnostics underline, save indicator. Keep feedback subtle — a gentle highlight or material change — never intrusive.

### 1.5 Metaphors
Use familiar mental models. File tree = folder hierarchy, tabs = open documents, console = terminal, status bar = context + position. Don't invent new paradigms where system conventions already exist.

### 1.6 User Control
The user initiates all actions. GoLens never moves focus, opens files, or modifies content without explicit direction. Undo works. Autocomplete suggests but never commits without confirmation.

### 1.7 Clarity
Text is the primary interface in a code editor. Use system fonts (SF Mono for code, SF Pro for UI). Maintain adequate contrast. Avoid jargon in UI labels. Status bar info (Ln/Col, encoding, line endings) is compact but legible.

---

## 2. Visual Style

### 2.1 Color

#### Semantic System Colors
Use `NSColor` / `Color` system semantic colors. Never hardcode RGB values for text/background.

| Role | Token | Light | Dark |
|------|-------|-------|------|
| Window background | `NSColor.windowBackgroundColor` | White | Near-black |
| Content background | `NSColor.controlBackgroundColor` | Light gray | Dark gray |
| Text background | `NSColor.textBackgroundColor` | White | Dark |
| Primary label | `NSColor.labelColor` | Near-black | Near-white |
| Secondary label | `NSColor.secondaryLabelColor` | Gray | Light gray |
| Tertiary label | `NSColor.tertiaryLabelColor` | Dim gray | Dim light gray |
| Separator | `NSColor.separatorColor` | Light gray | Dark gray |
| Accent | `NSColor.controlAccentColor` | System blue | System blue |
| Selected content | `NSColor.selectedContentBackgroundColor` | Blue | Blue |
| Unemphasized selected | `NSColor.unemphasizedSelectedContentBackgroundColor` | Gray | Gray |
| Grid | `NSColor.gridColor` | Light gray | Dark gray |
| Link | `NSColor.linkColor` | Blue | Blue |

#### Chrome vs. Code Surface color roles (code tokens)

Window chrome (toolbars, sidebars, tab bars, status bars, sheets, popovers, and floating panels) always uses native macOS system materials, Liquid Glass, and system semantic colors (`ChromeColor` / `ThemeColor` in `desktop/Views/Main/DesignTokens.swift`), independent of the selected syntax theme. Syntax themes apply strictly to code, diff, console log, and terminal canvases (`CodeSurfaceTheme` and `ThemeManager.swift`), respecting Light, Dark, and Increase Contrast. Quantitative profiler/trace palettes use `DataVizTone` (never `StatusTone` error hues), and monospaced code/telemetry typography uses `TechnicalTypography`.

| Role | Token | Source | Use |
|---|---|---|---|
| Chrome text | `ChromeColor.textPrimary` / `textSecondary` / `textTertiary` (aliased by `ThemeColor`) | `.primary`, `.secondary`, `tertiaryLabelColor` | Names, values, metadata, placeholders in chrome |
| Chrome accent / selection / hover | `ChromeColor.accent` / `selection` / `hover` / `separator` | `.accentColor`, `selectedContentBackgroundColor`, `quaternarySystemFill`, `separatorColor` | Selection, pointer hover, hairlines in chrome |
| Panel / content surface | `ChromeColor.panelSurface` (`ThemeColor.panelSurface`), `ThemeColor.contentSurface` | `controlBackgroundColor`, `textBackgroundColor` | Banners, bars, non-code inspector and document surfaces |
| Code canvas | `CodeSurfaceTheme.background` (`ThemeColor.editorSurface`), `textPrimary`, `textSecondary`, `lineNumber`, `currentLineFill`, `indentGuide`, `lensMarginBackground`, `lensDivider`, `lensActionText`, `lensMetadataText` | `ThemeManager` per syntax theme (`textBackgroundColor` on Xcode System) | Editor, diff, code previews, console log, terminal |
| Data visualization | `DataVizTone.heatFill(fraction:isDark:)`, `heatStroke(fraction:isDark:)`, `TraceStateKind` | Warm amber to copper to terracotta sequential scale; 5-state trace palette | Flame graph heat and execution trace states (never `StatusTone.failure`) |
| Technical typography | `TechnicalTypography.codeCanvas(size:)`, `lensRail(size:weight:)`, `codeCompact`, `metricMono`, `badgeMicro` | SF Mono / monospaced-digit system styles | Code canvas, lens rail, compact technical chips, telemetry numbers |
| Well fill / stroke | `ThemeColor.wellFill` / `wellStroke`, or `.wellBackground(cornerRadius:)` | `.primary` at 0.045 / 0.08, 0.5 pt | Grouped content inside sheets and inspectors |
| Tint fill | `ThemeColor.tintFill(color)`, `StatusTone.fill` | color at 0.14 | Badge and capsule backgrounds behind a status or identity color |
| Status | `StatusTone.tint` | system green, orange, red, secondary | Status symbols only, with text or symbol |

Zero views check `usesSystemMaterials`: `scripts/design/token-ratchet.py` enforces this boundary alongside spacing, radius, stroke, and color ratchets.

#### Syntax Highlighting Colors
Use fixed distinct colors (not semantic) for code tokens. These must work on `NSColor.textBackgroundColor`.

| Token | Color | Rationale |
|-------|-------|-----------|
| Keyword | `NSColor.systemBlue` | High visibility, standard |
| String | `NSColor.systemRed` | Warm contrast to blue keywords |
| Comment | `NSColor.systemGreen` | Subdued, distinguishable |
| Number | `NSColor.systemPurple` | Distinct from keywords/strings |
| Builtin | `NSColor.systemTeal` | Secondary highlight |
| Type | `NSColor.systemOrange` | Type names stand out |
| Function call | `NSColor.systemYellow` (dim) | Deliberate, not primary |

#### Diagnostic Underline Colors

| Severity | Color | Style |
|----------|-------|-------|
| Error (severity 1) | `NSColor.systemRed` | Dotted underline + 15% alpha background |
| Warning (severity > 1) | `NSColor.systemOrange` | Dotted underline + 15% alpha background |
| Hint/Info | `NSColor.secondaryLabelColor` | Dotted underline (blue is reserved for the accent) |

#### Accent Colors
- Use `NSColor.controlAccentColor` for selection highlights, button tints, active indicators — never for non-interactive text or icons

#### Color Meanings (UI chrome)
Each hue has exactly one meaning across the app (HIG Color: "Avoid using the same color to mean different things"). Color is never the only signal — every status also has a symbol or letter, so the UI passes a grayscale check.

| Color | Meaning | Examples |
|-------|---------|----------|
| Accent | Selection, interaction | Selected row, selected segment, links |
| Red | Error, removal | Error count, failed test, git `D` / `U` |
| Orange | Warning | Warning count and underline |
| Green | Success, new | Passed test, git `A` / `?` |
| `.secondary` | Neutral state | git `M` / `R`, info diagnostics, "running…" log lines, running/idle test, neutral file icons (and all file icons when "Colored File Icons" is off), row actions |

File-type icons are the one scoped exception: their identity tints (Go cyan, infra indigo, data purple, web pink) say which family a file belongs to, never a state, and avoid the reserved hues above. They are defined once in [`design/file-icons/palette.json`](./design/file-icons/palette.json) (copied to `desktop/Resources/FileIcons/`) as dynamic colors with light, dark and Increase Contrast variants, used only inside file glyphs, never in text or controls (§2.5). The Go gopher (`.go`, `_test.go`, generated Go) is a flat multicolor glyph like Xcode's Swift file icon: Go brand cyan `#00ADD8` body in light, `#4CC9EB` in dark, `#007A99` / `#8ADCF2` with Increase Contrast, white eyes and teeth, dark pupils and nose, tan muzzle and paws (`palette.json` → `multicolor.gopher`). The light body is below 3:1 against the sidebar by owner decision: the file name always sits next to it and the eyes carry the shape; its test check and generated gear use the go tint, which keeps ≥ 3:1.

Gutter & diff use the same meanings:

| Element | Color |
|---------|-------|
| Added line (gutter stripe, diff text/background) | Green |
| Removed line (gutter marker, diff text/background) | Red |
| Modified line (gutter stripe, diff text/background) | `secondaryLabelColor` — same meaning as the `M` badge |
| Gutter run triangle (test not run in this session) | `secondaryLabelColor` (monochrome, like toolbar Run) |
| Gutter test result | Passed: green `checkmark.circle.fill`; failed: red `xmark.circle.fill`; skipped: `minus.circle`, running: `circle.dotted` (both `secondaryLabelColor`) |
| Breakpoint (hover preview at 30% accent) | Xcode-style tag over the line-number column, filled with `selectedContentBackgroundColor` (the accent-derived emphasized selection color, ≥ 5.3:1 against the white number in light and dark), line number drawn inside in `alternateSelectedControlTextColor`. Plain = tag with a pointed right tip; conditional / hit count = same tag with a small white dot at the left; logpoint = tag pointed at both ends. Test run/result marks replace the number instead (no tag) |
| Lens text (usages, blame, go.mod notes) | `lensTextColor`: `secondaryLabelColor` mixed 25 % toward `labelColor`, resolved per appearance. Measured with `pixel-check`: 5.49:1 light, 7.26:1 dark (was 4.81:1 / 5.99:1 at 55 % alpha) |
| Inlay hints (types, parameter names) | Text in `lensTextColor`, SF Mono at editor size − 2 (min 9 pt), on a `quaternarySystemFill` rounded rect (radius 3) drawn in a kerning gap inside the line; no shadow, no stroke. Measured with `pixel-check`: 4.57:1 light, 7.38:1 dark. Drawing is clipped to the dirty rect so partial redraws never stack the fill |
| AI suggestion (gray inline text) | `ghostTextColor` (`GhostTextRenderer.swift`): `tertiaryLabelColor` mixed 35 % toward `secondaryLabelColor`, and with Increase Contrast `secondaryLabelColor` mixed 20 % toward `labelColor`; resolved per appearance. Editor font and size, no syntax color, italics or background, no animation. Text after the cursor that is only closers is redrawn after the suggestion; following lines move down for a multi-line suggestion and the gutter numbers real lines only |
| HTTP request result lens (`.http` files) | Text in `lensTextColor` (green or red 10pt text measured 2.24:1 / 3.61:1 on white, below 4.5:1); a leading green `checkmark.circle.fill` when the response is 2xx (gRPC `OK`) and every test passed, red `xmark.circle.fill` on an error, non-success status or failed test; the text always says the outcome ("200 OK · 42 ms · 2 tests passed", "Could not connect") |
| go.mod deprecated / retracted module note | Orange `exclamationmark.triangle.fill` + note text in the lens color |
| Merge conflict regions (editor background) | Current side `systemTeal`, incoming side `systemIndigo`, diff3 base and separator `secondaryLabelColor`; body lines at 7 % (light) / 10 % (dark), marker lines at 16 % / 22 %. Teal and indigo carry only this meaning in chrome; green and blue stay reserved for success and accent |

- File and folder names always use the label color; status never recolors a name
- Toolbar, debug-control and row action buttons (Run, Debug, Continue, Stop) are monochrome; state is shown by symbol (`play.fill` ↔ `stop.fill`)

#### Git Status Badge
`GitStatusBadge` is the single source for git status in the file tree, Source Control navigator and diff header: a trailing monospaced letter (10pt semibold) in the color above, white on an active selection, with the full word as tooltip and VoiceOver label.

| Letter | Status | Color |
|--------|--------|-------|
| `M` | Modified (on a folder: contains changes) | `.secondary` |
| `A` | Added | Green |
| `?` | Untracked | Green |
| `D` | Deleted | Red |
| `U` | Merge conflict — shown as `exclamationmark.circle.fill` instead of a letter, label "Merge Conflict" | Red |
| `R` | Renamed | `.secondary` |

### 2.2 Surface Grammar, Material & Vibrancy

GoLens organizes every window into a strict **4-layer Surface & Liquid Glass Grammar**:

1. **Navigation**: `NavigationSplitView` leading sidebar (`Files`, `Source Control`, `Search`, `Issues`, `Tests`), document tab bar, breadcrumb bar, and the optional trailing `GopilotPanelSurface` (`CornerRadius.sidebarPanel`, `18pt`).
2. **Floating Control**: Unified macOS 26 toolbar (`ProjectTitleButton`, `CenterActivityCluster` with `ActivityPill` and `IssuesToolbarBadge`, trailing `Run/Debug` cluster) and transient overlays (`OmniFinderView`, `LocalSearchView`, `CompletionPanel`, `ReferencesPopupView`, `HierarchyPopupView`, `SignatureHelpPopupView`, `QuickDocumentationPopoverView`, `RecentFilesPopupView`) built on `.floatingPanelBackground(cornerRadius:)`, `.glassControlCapsule(interactive:)`, and `.chromeMaterialSurface(_:)`.
3. **Content Canvas**: Opaque `CodeSurfaceTheme` code, diff, console, and terminal canvases plus `ThemeColor.contentSurface` (`NSColor.textBackgroundColor`) document views — never wrapped in Liquid Glass or translucent materials.
4. **Contextual Feedback**: `InlineBanner`, `CommandFeedbackPresenter` (structured non-blocking banner replacing silent `NSSound.beep()` failures), `UnifiedEmptyState`, and status-bar workspace health popovers anchored directly at the affected surface.

Materials belong only to navigation chrome and transient floating control layers. Glass first (owner 2026-10-30 / 2026-11-08): control-layer overlays above the editor use Liquid Glass (`NSGlassEffectView` / `glassEffect(.regular)`), and an opaque `windowBackgroundColor` fill with a `separatorColor` border when Reduce Transparency is enabled. Chrome always uses native macOS system materials and semantic colors (`usesSystemMaterials == 0` across views); syntax themes apply strictly to `CodeSurfaceTheme` canvases (plus Light/Dark window appearance and control accent tint).

| Context | Material |
|---------|----------|
| Window chrome (title bar, toolbar) | System — no custom background |
| Sidebar | System sidebar (NavigationSplitView) — no custom fill |
| Gopilot panel | Treated as a trailing sidebar (owner decision 2026-11-08): one Liquid Glass container (`GopilotPanelSurface`, `glassEffect(.regular)`) in a `CornerRadius.sidebarPanel` continuous rounded rectangle, 8pt from the window's trailing edge, the status bar and the editor, like the system sidebar; the 8pt gap next to the editor is the resize handle. Header row matches the navigator selector row (6pt vertical padding, `NavigatorTabCluster` capsule of `TabButton`s), no hairline bars; transcript and composer sit directly on the glass, actionable cards and code use fills, never a second glass layer. Opaque `windowBackgroundColor` with a `separatorColor` edge under Reduce Transparency. Opens with a trailing edge slide (offset only — never `.opacity` on glass, so refraction stays intact; the editor resizes once, Reduce Motion skips it) |
| Tab bar | None — sits on the window background |
| Breadcrumb bar | Editor background, flat (no card, border or material) |
| Editor background & Optical Lens Margin | Opaque `CodeSurfaceTheme.background` (`NSColor.textBackgroundColor` on Xcode System) with `CodeSurfaceTheme.lensMarginBackground` and `CodeSurfaceTheme.lensDivider` |
| Status bar | None — plain bar under the content, 0.5pt top divider |
| Completion popup | Liquid Glass (`NSGlassEffectView`, regular) in a borderless child panel, 8pt corners; opaque fill with Reduce Transparency |
| Find bar | Liquid Glass (`glassEffect(.regular)` in an 8pt continuous rounded rectangle); opaque fill with Reduce Transparency |
| `OmniFinderView` (`⇧⌘O`, `>` Commands, `@` File Symbols), Recent Files, References, Hierarchy | Same as the find bar (`floatingPanelBackground()`), 14pt continuous corners, no dimming scrim — a click outside or Esc dismisses (Xcode Open Quickly, Spotlight) |
| Build HUD | Same floating material, 16pt corners, clipped to its shape before the shadow |
| Hover, signature help, rename | Borderless child panels (`FloatingPopup`) — a SwiftUI overlay renders under the AppKit editor |
| Hover tooltip/popover | `.popover` appearance (system) |
| Console/terminal | Opaque `CodeSurfaceTheme.background` (content layer, never glass/material) |
| Sheet backgrounds | System default (vibrancy) |

**One floating material.** Everything that floats over the editor uses `floatingPanelBackground(cornerRadius:)` (`desktop/Views/Main/FloatingPopup.swift`); no popup draws its own card, scrim or shadow. **One popup at a time:** `WorkspaceState.activePopup` holds the open one per workspace window (`Popup.omniFinder(OmniFinderScope)` unifies Quick Open, Command Palette, File Symbols, and Workspace Symbols); opening another replaces it, and only the open popup's key monitor runs.

### 2.3 Typography

#### System Fonts

| Usage | Family | Size | Weight |
|-------|--------|------|--------|
| Code | SF Mono (`NSFont.monospacedSystemFont`) | 13pt | Regular |
| UI labels | SF Pro (`NSFont.systemFont` / `.system`) | 11–12pt | Medium/Semibold |
| Tab titles | SF Pro | 11pt | Medium (active), Regular (inactive) |
| Status bar | SF Pro | 10pt | Medium |
| Path/breadcrumb | SF Mono | 11pt | Regular |
| Line numbers | SF Mono (`NSFont.monospacedDigitSystemFont`) | 11pt | Regular |
| Diagnostics tooltip | SF Pro | 10pt | Regular |
| File tree | SF Pro | 13pt | Regular, 16pt file icons in 24pt rows (Xcode navigator size) |
| Placeholder text | SF Pro | 12pt | Regular, secondary color |
| Completion names and signatures | SF Mono (editor font) | Editor size; typed matches semibold | Regular |
| Completion type / package | SF Mono | Editor size − 1 | Regular, secondary (package too: tertiary falls under 4.5:1 on glass) |
| Completion doc footer | SF Pro | Body | Regular (signature line in SF Mono) |
| Welcome window app name | SF Pro | 32pt | Bold |
| Welcome window version | SF Pro | 13pt | Regular, secondary, monospaced digits |
| Welcome actions | SF Pro | 13pt | Medium |
| Welcome recent project name / path | SF Pro | 13pt / 11pt | Semibold / Regular, secondary |

#### Text styles (macOS)

UI text uses the system text styles, not `.system(size:)`. On macOS they resolve to fixed point sizes (HIG Typography, macOS built-in text styles), so this changes no pixels; it keeps one scale and lets the system own the metrics. Weight and design are modifiers on the style, never a new size.

| Role | Style | Size | Use |
|---|---|---|---|
| Primary UI text, file tree, welcome actions | `.body` | 13 | Rows, field values, buttons that carry a task |
| Section heading | `.headline` | 13 bold | Group and pane titles |
| Secondary UI text, placeholders | `.callout` | 12 | Labels, notes, empty-state explanation |
| Dense UI text, tab titles, breadcrumb, row detail | `.subheadline` | 11 | Anything that sits beside code at editor density |
| Footers, help, validation | `.footnote` | 10 | Text below a group or field |
| Status bar, metadata, tooltips | `.caption` | 10 | Counts, paths, timestamps |
| Badges and tags | `.caption2` | 10 medium | `SettingsBadge`-style capsules |

- Emphasis: `.weight(.medium)` or `.weight(.semibold)` on the style. Monospaced text: `.monospaced()` or `.monospacedDigit()` on the style. Never a literal size.
- Code and anything that must follow the editor font uses `TechnicalTypography.codeCanvas(size:)` / `codeCanvasNSFont(size:weight:)` (SF Mono, 13 pt default), while code lenses use `TechnicalTypography.lensRail(size:weight:)`, compact technical chips use `TechnicalTypography.codeCompact`, telemetry counters use `TechnicalTypography.metricMono`, and compact badges use `TechnicalTypography.badgeMicro`.
- SF Symbol size comes from the text style of the adjacent label or `imageScale`, not from a literal size.
- Display sizes (welcome app name 32, empty-state heroes 24/28/36) are defined once as named constants beside the view that owns them, not repeated per call site; 8–9 pt fixed font literals (`fixed_fonts_small`) are forbidden (`0` in `scripts/design/token-ratchet.py`).
- Reading content must not use `.caption` or `.footnote`; essential information cannot depend on 10 pt text.

#### Line Spacing
- Code: `0` (default, controlled by NSTextView)
- UI text: System default

### 2.4 Layout & Spacing

#### Grid
Use an **8-point grid** for all layout decisions. 4-point increments allowed for nested content.

Spacing comes from `Spacing` in `desktop/Views/Main/DesignTokens.swift`; padding and stack spacing never use a literal. The scale keeps the two documented off-grid values (6 and 10) so existing layouts migrate without moving a pixel.

| Token | Value | Role |
|-------|-------|------|
| `Spacing.hairline` | 2 | Title to message, icon nudges |
| `Spacing.compact` | 4 | Items inside one group |
| `Spacing.row` | 6 | Vertical padding of compact rows and header bars |
| `Spacing.standard` | 8 | Default between items; horizontal row padding |
| `Spacing.inset` | 10 | Standard inset of popovers and panels |
| `Spacing.comfortable` | 12 | Horizontal padding of banners and cards |
| `Spacing.section` | 16 | Between groups; sheet content inset |
| `Spacing.content` | 24 | Reading content margins (markdown preview) |

Values outside the scale (1, 3, 5, 7, 14, 20) are not tokens: a new use is not allowed, existing ones migrate to the nearest role when their view is redesigned, and `SettingsMetrics.contentInset` (20) stays because it matches the native grouped form inset. `scripts/design/token-ratchet.py` counts both.

| Layout | Value |
|-------|-------|
| Window minimum size | `920×580pt` (`WindowLayout.minWidth × minHeight`) |
| Window default size | `1280×820pt` (`WindowLayout.defaultWidth × defaultHeight`) |
| Sidebar width | `210–320pt` (ideal `256pt`) |
| Gopilot trailing column width | `300–480pt` (ideal `360pt`; auto-collapses leading sidebar below `980pt` window width) |
| Editor minimum width / height | `380pt` / `240pt` |
| Optical Lens Margin width | `200pt` right-edge rail when editor pane width `>= 680pt` (collapses to inline end-of-line below `680pt`) |
| Console min height | `120pt` |

#### Alignment
- Text always left-aligned
- Icons in lists center-aligned
- Status bar: left (model indicator) / right (cursor position, encoding)
- Console tabs: left-aligned with scroll

### 2.5 Iconography

#### App icon
The source is the Icon Composer file `design/app-icon/GoLens.icon`: the 2D cel-shaded Boba Milk Tea Go Gopher artwork (`BobaGopher.png` from the native `1024×1024` full-bleed `design/app-icon/boba-master-1024.png` master, paired with a translucent `Glass.png` cup-wall specular layer) over an `automatic-gradient` warm milk-tea fill (`extended-srgb:0.89000,0.68000,0.44000,1.00000`). `design/app-icon/build-icon-layers.py` writes it from `boba-master-1024.png`; never edit the bundle layers by hand. The seasonal icons in `desktop/Resources/AppIcons` (`tet`, `noel`, `halloween`, `hacker`) follow the same unified 2D hand-illustrated comic-ink & cel-shaded mascot direction (`design/mascot/studio_art.py`), built by `design/app-icon/build-seasonal-icons.py` through `actool` so they carry the same Liquid Glass edge. `scripts/make-app-icon.sh` (Xcode 26) compiles `GoLens.icon` to `design/app-icon/Assets.car`, which the bundle carries as `CFBundleIconName` so macOS 26 draws it in the person's icon style (default, dark, clear, tinted), and renders `desktop/Resources/GoLens.icns` (16–1024 px) for the in-app icon images. Commit both outputs after changing the icon. The default costume leaves the Dock icon to the system; seasonal costumes replace it while selected.

#### SF Symbols
Prefer SF Symbols for all UI controls (toolbar icons, status indicators, buttons).

| Context | Symbol |
|---------|--------|
| Run | `play.fill` (monochrome) |
| Stop | `stop.fill` (monochrome) |
| New window | `macwindow.badge.plus` |
| New file | `doc.badge.plus` |
| New folder | `folder.badge.plus` |
| Save | `square.and.arrow.down` |
| Search | `magnifyingglass` |
| Close | `xmark` |
| Terminal | `terminal` |
| Console | `text.alignleft` |
| Diagnostics | `exclamationmark.triangle` |
| Go to line | `text.cursor` |
| Comment toggle | `slash.circle` |
| Keyboard (empty state) | `keyboard` |

#### Symbol registry

One concept, one symbol, everywhere: menu, toolbar, context menu, palette, banner, empty state. A symbol never stands for two unrelated concepts on surfaces a person sees together. Before choosing a symbol, look it up here; a concept that is missing is added here in the same change. Changing a registered symbol changes recognition across the app, so it needs the owner's sign-off.

| Concept | Symbol | Notes |
|---|---|---|
| Success / passed / connected | `checkmark.circle.fill`, green | From `StatusTone.success`; never picked by hand |
| Warning | `exclamationmark.triangle.fill`, orange | From `StatusTone.warning` |
| Error / failed | `xmark.circle.fill`, red | From `StatusTone.failure`: diagnostics severity, Issues badge, build and test results, Gopilot failures |
| Panic / exit (subject) | `xmark.octagon` (outline) | The Panic & Exit inspector only; never a status |
| Markdown callouts | GitHub alert glyphs (Caution `xmark.octagon.fill`) | Rendered document content, not app status |
| Inactive / skipped / stopped | `minus.circle`, secondary | From `StatusTone.inactive` |
| Information | `info.circle`, secondary | From `StatusTone.info` (findings of information severity) |
| In progress | small `ProgressView` | Not a symbol |
| Merge conflict | `exclamationmark.circle.fill`, red | Object identity, used by the navigator badge and the merge banner |
| Mark as resolved | `checkmark.seal` | |
| Commit signature | `checkmark.seal.fill` green (verified), `checkmark.seal` secondary (signed by another key), warning status (invalid) | Source Control history |
| Issues navigator / diagnostics | `exclamationmark.triangle` (outline) | Navigator identity; the filled glyph is the warning status |
| Next / previous match or issue | `chevron.down` / `chevron.up` | Find Next / Find Previous, Next Issue / Previous Issue |
| Refresh / reload | `arrow.clockwise` | |
| Reset to default | `arrow.uturn.backward` | |
| Discard / revert changes | `arrow.uturn.backward.circle` | Destructive menu items |
| Copy | `doc.on.doc` | |
| Delete | `trash` | |
| Close / dismiss | `xmark` | |
| Add | `plus` | |
| Stage / unstage | `plus.circle` / `minus.circle` | |
| More actions | `ellipsis.circle` | |
| Filter | `line.3.horizontal.decrease.circle` | |
| Open externally (browser, hosting service) | `arrow.up.right.square` | Also Open in Browser for a container's published port (Services context menu, Tools ▸ Containers & Compose, Details Ports link) |
| Show in Finder, open project folder | `folder` | |
| Code generation, Regenerate, Run go generate | `gearshape.2` | Product menu and generated-file inline banner |
| Compare / diff | `arrow.left.arrow.right` | |
| Collapsed unchanged lines (diff) | `ellipsis` | Gap row in `UnifiedDiffTextView` ("12 unchanged lines (Lines 4–15)"); approved (owner, 2026-11-17) |
| Branch | `arrow.triangle.branch` | |
| Merge | `arrow.triangle.merge` | |
| Merge editor (three columns) | `rectangle.split.3x1` | Open in Merge Editor in the Source Control menu and the conflict row menu |
| Interactive rebase | `list.bullet.indent` | Interactive Rebase… and Interactively Rebase from Here… |
| File history (git), recent files | `clock` | |
| Local History | `clock.arrow.circlepath` | |
| Debug | `ladybug.fill` | |
| Pause (debugger) | `pause.fill` | Replaces Continue `play.fill` in the debugger controls while the program runs |
| Run to Cursor | `arrow.right.to.line` | Debug menu and editor context menu |
| Live templates | `text.badge.plus` | Settings ▸ Editing drill-down tile |
| Surround With | `curlybraces` | Editor menu, editor context menu, chooser field |
| Complete Current Statement | `return` | Editor menu, Command Palette |
| Add Cursor Above / Below | `text.line.first.and.arrowtriangle.forward` / `text.line.last.and.arrowtriangle.forward` | Edit menu |
| Join Lines | `arrow.merge` | Edit menu, Command Palette |
| Move Line Up / Down | `arrow.up` / `arrow.down` | Edit menu; same meaning as Move Up / Move Down in the interactive rebase sheet |
| Move Statement Up / Down | `arrow.up.square` / `arrow.down.square` | Edit menu, Command Palette |
| Breakpoint | `arrowshape.right.fill` (enabled, accent) / `arrowshape.right` (disabled, secondary) | Breakpoints scope rows and its empty state; the gutter draws its own tag shape |
| Test | `checkmark.diamond` | |
| Coverage | `checkmark.shield` | |
| Profile | `gauge.with.dots.needle.67percent` | |
| Docker / container | `shippingbox` | |
| Services tab, View ▸ Show Services | `server.rack` | |
| Compose project (This Project, project groups) | `square.stack.3d.up` | Services list |
| Container image | `cube.transparent` | Services list, Images group |
| Volume | `externaldrive` | Services list, Volumes group |
| Show Logs | `text.alignleft` | Same glyph as the Console: log output |
| Show Details | `list.bullet.below.rectangle` | Services context menu and Tools ▸ Containers & Compose |
| Restart (container) | `arrow.clockwise.circle` | Distinct from Refresh `arrow.clockwise` |
| Open Shell (in a container) | `terminal` | Same glyph as Terminal |
| Start / Stop (container) | `play.fill` / `stop.fill` | Same glyphs as Run / Stop; also Start Service / Stop Service for a Compose service |
| Docker network | `point.3.connected.trianglepath.dotted` | Services list Networks group and rows (`network` is HTTP); owner-approved 2026-11-16 |
| Clean Up (unused Docker data) | `xmark.bin` | Docker section header menu, Tools ▸ Containers & Compose ▸ Clean Up…; owner-approved 2026-11-16 |
| Docker context | `cable.connector` | Context selection menu in the Docker section header and above engine failure states; owner-approved 2026-11-16 |
| Kubernetes context | `cable.connector` | Same concept as the Docker context: the context selection menu in the Kubernetes section header and Tools ▸ Kubernetes ▸ Context |
| Kubernetes (section, Tools ▸ Kubernetes, Show Kubernetes) | `helm` | Owner-approved 2026-11-17 |
| Pod, Pods group, Show Pods | `circle.grid.2x2` | Owner-approved 2026-11-17 |
| Deployment, Deployments group | `rectangle.stack` | Owner-approved 2026-11-17 |
| Kubernetes Service, Services group | `dot.radiowaves.left.and.right` | Owner-approved 2026-11-17 (`network` is HTTP, `point.3.connected.trianglepath.dotted` is the Docker network) |
| Namespace (Kubernetes) | `square.dashed` | Namespace selection menu, Choose Namespace…; owner-approved 2026-11-17 |
| Port Forward…, forward child rows | `arrow.right.circle` | Owner-approved 2026-11-17 |
| Apply to Cluster… | `arrow.up.doc` | Tools ▸ Kubernetes, editor context menu, section header menu; owner-approved 2026-11-17 |
| Use as kubectl Default… | `pin` | Owner-approved 2026-11-17 |
| Read-only Kubernetes context | `lock` | Same concept as the read-only data source: the Apply sheet banner |
| Rollout Restart… | `arrow.clockwise.circle` | Same concept as Restart (container) |
| Build Image, Rebuild and Restart (Compose service) | `hammer` | Tools ▸ Containers & Compose and the Services context menu (`docker compose up -d --build <service>`) |
| Show Value / Hide Value (masked secret) | `eye` / `eye.slash` | Services Details, environment values |
| HTTP requests and handlers | `network` | |
| Data source | `cylinder.split.1x2` | Tools ▸ Database ▸ Data Sources…, the Data Sources sheet rows and its empty state |
| Database panel | `cylinder` | Show Database Panel |
| Query console | `square.and.pencil` | New Query Console |
| Run statement / run all statements | `play.fill` / `play.square.stack` | Run Statement is the Run concept; Run All Statements in File runs each statement in order. Run SQL (a SQL string in Go code) and Run Query (a sqlc query) are the same Run concept |
| Stop a running request or statement | `stop.circle` | Stop HTTP Requests, Stop Statement |
| Attach to a data source | `link` | Attach Console To ▸ |
| Disconnect | `bolt.slash` | Disconnect a data source |
| Go to source (request, statement) | `arrow.up.forward.square` | Detail header of the `Requests` and `Database` tabs |
| Schema | `square.3.layers.3d` | Schema outline (`square.stack.3d.up` is the Compose project) |
| Table, Open Table | `tablecells` | Schema outline, results empty state |
| View (database) | `tablecells.badge.ellipsis` | Schema outline |
| Column | `rectangle.portrait` | Schema outline |
| Primary key / foreign key | `key` / `key.horizontal` | Schema outline |
| Index (database) | `list.bullet.rectangle` | Schema outline (`list.number` is Generate Enum Methods) |
| Read-only data source | `lock` | Console controls in the breadcrumb bar; production uses the warning status |
| NULL value | `circle.slash` | Cell viewer |
| Query History | `clock.arrow.trianglehead.counterclockwise.rotate.90` | Tools ▸ Database, Query History popup |
| Explain Plan / Explain Analyze | `chart.bar.doc.horizontal` | Tools ▸ Database, explain outline |
| Submit Changes | `arrow.up.circle` | Table editor |
| Commit / Roll Back (transaction) | `checkmark.circle` / `arrow.uturn.backward.circle` | `DatabaseTransactionControls` in the `.sql` file controls and the Database tab header |
| Export Result | `square.and.arrow.up` | Export Result sheet, result header |
| Detect Data Sources | `sparkle.magnifyingglass` | Tools ▸ Database, Detect Data Sources sheet |
| Show Referenced Row | `arrow.turn.down.right` | Table grid context menu on a foreign key cell; opens the referenced table filtered by the key; approved (owner, 2026-11-17) |
| Show Referencing Rows | `arrow.turn.up.left` | Table grid context menu; a submenu of the tables whose foreign keys point at the row; approved (owner, 2026-11-17) |
| Gopilot / AI | `sparkles` | |
| Keyboard shortcuts and key bindings | `keyboard` | Settings ▸ Key Bindings, Help ▸ Keyboard Shortcuts menu item and window |
| Report a problem | `exclamationmark.bubble` | Help ▸ Report a Problem… and the sheet's empty state |
| Diagnostics archive | `doc.zipper` | Redacted `.zip` summary in Report a Problem |
| Cut / Paste | `scissors` / `doc.on.clipboard` | Edit menu and editor context menu |
| Comment / uncomment | `text.bubble` | Editor menu, editor context menu |
| Quick Documentation | `questionmark.circle` | View menu, editor context menu, Command Palette |
| Quick Definition | `rectangle.and.text.magnifyingglass` | View menu, editor context menu, Command Palette |
| Parameter Info | `parentheses` | View menu, Command Palette |
| Documentation Browser, Open Documentation | `book` | View menu, Command Palette, go.mod require lens, Quick Documentation and Hover popovers |
| Go to Implementation | `arrow.down.right.circle` | Navigate menu, editor context menu |
| Rename symbol | `character.cursor.ibeam` | Refactor submenu, editor context menu |
| Refactor / Code Actions / Generate | `slider.horizontal.3` / `wand.and.stars` / `wand.and.rays` | Editor menu, editor context menu, Command Palette |
| Change Signature / Move Symbol | `signature` / `arrow.right.doc.on.clipboard` | Editor ▸ Refactor submenu |
| Extract Function / Variable / Interface / Inline Variable | `function` / `equal.square` / `puzzlepiece.extension` / `arrow.down.to.line.compact` | Editor ▸ Refactor submenu |
| Struct tags / Inlay hints | `tag` | Editor ▸ Generate submenu, Command Palette |
| Enum / Stringer methods | `list.number` | Editor ▸ Generate submenu |
| Benchmark | `stopwatch` | Product menu, Editor ▸ Generate submenu, Command Palette |
| Interface mock | `theatermasks` | Editor ▸ Generate submenu |
| Run HTTP Request / Run All in File | `paperplane.fill` / `paperplane.circle` | Tools ▸ HTTP Client, editor context menu, Command Palette |
| Bookmark / Remove Bookmark | `bookmark` / `bookmark.slash` | Navigate menu, editor gutter context menu, Command Palette |
| Edit action (inline) | `pencil` | Gutter breakpoint editor and inline edit triggers |
| Workspace navigation history | `chevron.backward` / `chevron.forward` | Navigate ▸ Back / Forward, History back, toolbar history pill |
| Navigator / sidebar reveal | `sidebar.leading` | View ▸ Navigator / Navigators menu, Reveal in Navigator |
| Sidebar selection prompt | `sidebar.left` | Master-detail empty selection (`DataSourcesSheet`, `DetectDataSourcesSheet`, `RunConfigurationsModal`) |
| Bottom console panel toggle | `rectangle.bottomthird.inset.filled` | View ▸ Console, status bar panel toggle |
| Split editor / side-by-side comparison | `rectangle.split.2x1` / `square.split.2x1` | Menus and split actions (`rectangle.split.2x1`); compact tab-bar toggle (`square.split.2x1`) |
| Inline diff comparison | `rectangle.grid.1x2` | Editor ▸ Inline Comparison toggle |
| Collapse / expand diff context | `arrow.up.and.down.text.horizontal` | Diff view Collapse Unchanged toggle |
| Edit source code from diff | `pencil.line` | Diff view Edit Code action |
| Minimap / word wrap / indentation | `sidebar.squares.right` / `text.word.spacing` / `increase.indent` | View menu toggles and Editor indentation picker |
| Folding & selection scope | `chevron.down.square` / `chevron.right` / `arrow.down.right.and.arrow.up.left` / `arrow.up.left.and.arrow.down.right` | Code Folding submenu, Shrink/Expand Selection, Collapse/Expand All |
| Code lenses & inline git blame | `eyeglasses` / `person.text.rectangle` | View menu and Code Lens margin; `person` marks author blame chip |
| Escape analysis & memory layout | `memorychip` | View ▸ Escape Analysis, Tools ▸ Inspect Struct Memory Layout |
| Target architecture & disassembly | `cpu` / `desktopcomputer` | Run Destination menu (`desktopcomputer`), Compiler Optimization & Build Target (`cpu`) |
| Text zoom | `plus.magnifyingglass` / `minus.magnifyingglass` / `1.magnifyingglass` | View ▸ Zoom In / Out / Actual Size and Profiler timeline zoom |
| Project search / quick open | `text.magnifyingglass` / `doc.text.magnifyingglass` | Find in Project, Code Analysis menu, Debugger inspect, Diff inspect |
| Command palette | `command.square` | View ▸ Command Palette and empty-state keyboard prompt |
| Project & tab management | `plus.rectangle.on.folder` / `plus.square.on.square` / `xmark.rectangle` / `checkmark.rectangle` / `chevron.backward.square` / `chevron.forward.square` | New Project/Git Repo, Duplicate, Close Window/All Tabs, Close Saved Tabs, Previous/Next Tab |
| Unsaved tab dot / pinning | `circle.fill` / `pin.circle` / `pin.fill` / `pin.slash` | Dirty indicator (`circle.fill`), Keep Tab Open, Pinned Tab / Benchmark Baseline, Clear Baseline |
| Jump to symbol / line / match | `number.square` / `number` / `t.square` | Workspace Symbol (`number.square`), Go to Line / Identifier (`number`), Type Definition (`t.square`) |
| Stepper & bookmark markers | `arrowtriangle.right.fill` / `bookmark.fill` | Debugger program counter and gutter/next bookmark |
| Next / previous change or conflict | `arrow.down.to.line` / `arrow.up.to.line` / `arrow.left.circle` | Jump to Next/Previous Change, Scroll to Top/Bottom, Merge conflict navigation & Accept Right (`arrow.left.circle`) |
| Multi-buffer & reference collections | `rectangle.stack.fill` | Multi-buffer editor and Open in Multi-Buffer |
| Debugger controls | `arrow.uturn.forward` / `arrow.down.right` / `arrow.up.left` / `ladybug` / `hammer.fill` | Step Over / Into / Out, Attach to Process (`ladybug`), Build (`hammer.fill`) |
| Profiler & benchmarks | `flame` / `flame.fill` / `doc.badge.gearshape` / `chart.bar.xaxis` / `speedometer` / `arrow.left.and.right` / `arrow.triangle.swap` | Flame graph, Open `.pprof`, Complexity/Benchmark comparison, Zoom to Fit Timeline, Compare Diff |
| Testing status & coverage actions | `circle` / `bolt.badge.checkmark` / `xmark.shield` / `testtube.2` | Pending test or Get Started step (`circle`), Auto-Test on Save, Clear Coverage, No Counterpart Test |
| Source control push / pull / fetch / stash | `arrow.up` / `arrow.down` / `arrow.down.circle` / `archivebox` / `tray` / `tray.and.arrow.down` / `tray.and.arrow.down.fill` | Push, Pull, Fetch, Stash, Empty staging tray, Apply Stash / Apply and Delete |
| App update | `arrow.down.app` | GoLens ▸ Check for Updates… |
| Rebase & remote branch operations | `arrow.triangle.pull` / `arrow.turn.left.up` / `cloud` / `person.crop.circle` | Rebase onto branch, Drop/Fixup return (`arrow.turn.left.up`), Remote header (`cloud`), Author / Account |
| HTTP & networking files | `globe` / `lock.doc` / `network.badge.shield.half.filled` | HTTP Environment, private env file, New HTTP Request File |
| Add Go module & safety audit packages | `shippingbox.and.arrow.backward` / `shippingbox.fill` | Product ▸ Add Go Module and Safety dependency cards |
| Diagnostics & quick fix triggers | `stethoscope` / `wrench.and.screwdriver` / `arrow.up.forward.circle.fill` | Workspace Diagnostics, Optical margin quick fixes, Hover quick-open action |
| File, folder & note states | `doc` / `doc.text` / `doc.richtext` / `doc.questionmark` / `doc.badge.clock` / `doc.badge.ellipsis` / `folder.badge.minus` / `folder.badge.questionmark` / `note.text` / `note.text.badge.plus` | Generic doc, Markdown, Unreadable file, History/Review checkpoints, File omissions, Missing folder, Scratch files |
| Editor text & markdown controls | `quote.opening` / `text.quote` / `text.insert` / `chevron.left.forwardslash.chevron.right` / `photo.badge.exclamationmark` / `selection.pin.in.out` | String transforms, Quote selection, Insert SQL statement, Code preview, Missing image, Use Selection for Find / Select All |
| Task checklist & inline selections | `checklist` / `checkmark` / `chevron.left` / `chevron.right` / `chevron.up.chevron.down` | TODOs / tool checklist / Help ▸ Get Started, Selected item check, Settings Back, Disclosure, Model picker |
| Editor organize imports / inline stage | `arrow.up.arrow.down` / `minus` | Organize Imports, Unstage Selected Files / Remove pattern |
| Inline play lenses & environment apply | `play.circle` / `play.square` | Inline runnable lens and Apply to Run Config |
| Gopilot composer & approvals | `arrow.up.circle.fill` / `stop.circle.fill` / `hand.raised.fill` / `xmark.circle` | Send, Stop generation, Waiting for approval, Rejected / Close Other Tabs / Clear Shortcut |
| Compiler optimization hint | `lightbulb.fill` | `CompilerOptimizationSheetView` optimization hint callout |
| Interface mock (Command Palette) | `rectangle.on.rectangle.angled` | Generate Interface Mock… palette action (`theatermasks` in Editor ▸ Generate submenu) |
| Read suggestion aloud | `speaker.wave.2` | Read Suggestion Command Palette action |
| Struct type target | `s.square` | Target Types struct badges in `ExtractTypeSheetView` |
| Run configurations empty state | `play.rectangle` | `RunConfigurationsModal` empty state |
| Default model route | `star` | Set as Default action in `GopilotSettingsPane` route menu |
| Reasoning profile | `brain` | Reasoning Profile submenu in `GopilotSettingsPane` route menu |
| Fallback AST symbol glyph | `circle.grid.cross` | Fallback SF Symbol in `SymbolIconResolver` when a bundled PDF symbol is absent |

Known drift, fixed when the surface is touched (with sign-off, since it changes recognition): `checkmark.shield` also marks Safety Audit, Validate methods and Verify Connection; `checkmark.seal` also marks Implement Interface, Validate Compose File and Token & HMAC safety; `clock.arrow.circlepath` also marks Switch to commit; `arrow.triangle.2.circlepath` marks unrelated inspectors and Fetch Models; `minus.circle` is both Unstage and the inactive status; `checkmark.circle` is both Commit (transaction) and the rebase Pick; `exclamationmark.bubble` is both Report a Problem and the Inline Issues toggle; `arrow.up.right.square` also marks a line jump and an inspector; `scripts/design/token-ratchet.py` counts octagon glyphs and hand-picked status colors; both may only go down.

#### File Type Icons
`FileIconView` draws one custom template glyph per file role from [`design/file-icons/`](./design/file-icons/README.md) (37 icons as PDFs bundled in `desktop/Resources/FileIcons/`, including `pprof` for CPU/Heap/Trace profiles, plus 4 color variants for each gopher icon; 16 × 16 pt for a 13 pt row, scaled with the row size). Shape alone identifies each icon (grayscale test in `design/file-icons/preview/grayscale-2x.png`); color only adds the family.

- **Detection** (`FileIconResolver`, rules in `mapping.json`): name, glob, path and extension rules resolve synchronously while the row draws. Rules that need file I/O (Kubernetes `apiVersion`/`kind` content, `// Code generated … DO NOT EDIT.` header, Helm `values*.yaml` next to `Chart.yaml`, `templates/` under a chart) run off the main thread, are cached per (path, mtime) (≤ 2,000 paths), and show the next synchronous match (the rule's `until` icon) until they finish.
- **Folders**: one filled folder glyph in the theme accent, like the Xcode and Finder navigators (owner decision 2026-11-05, overriding the earlier neutral folders). Every folder, Go layout folders included, uses this one plain glyph: badges read heavy at sidebar size and pulled the eye from the name (the badged glyphs stay in the design set only). Expanded folders keep the same glyph (the disclosure triangle shows state). The accent is `ThemeManager.accentNSColor` (the Xcode (System) theme follows the macOS accent color); `FileIconPalette.accent` blends it toward black (light) or white (dark) only as far as needed for 3:1 against the sidebar, 4.5:1 with Increase Contrast. Selection and Colored File Icons off behave like every other icon (white, `.secondary`).
- **Color**: tinted by default with the identity palette (Go = cyan, infra = indigo, data = purple, web = pink, folders = theme accent, everything else `secondaryLabelColor`), dynamic for light, dark and Increase Contrast ([`palette.json`](./design/file-icons/palette.json), §2.1). Settings ▸ General ▸ **Colored File Icons** (`GoLensColoredFileIcons`, on by default) turns every icon `.secondary`.
- **Gopher family** (`go`, `go-test` with a check, `go-generated` with a gear): multicolor artwork, never tinted. With colored icons on, `FileIconView` draws `<name>-color-<light|dark|light-hc|dark-hc>.pdf` for the current color scheme and contrast; with colored icons off, and on the emphasized selection, it draws `<name>.pdf`, a one-color silhouette with the eyes and nose cut out (pupils look in toward the nose), as a template image like every other icon (`.secondary`, or white).
- **Selection**: `alternateSelectedControlTextColor` (white) on the emphasized (accent) selected row, detected by `FileIconView` from the row's `backgroundProminence` as well as the caller's flag; the tint (or multicolor gopher) stays on unemphasized selection and on light row highlights (Source Control rows).
- **Everywhere a file icon appears**: navigator (files, folders, new-item row), tabs, breadcrumb and its menus, Recent Files, project search results, references, Source Control rows and the diff header.
- `.accessibilityHidden(true)`: the row already reads the file name.
- Attribution: the gopher glyphs are an original drawing after the Go gopher by Renée French (CC BY 4.0); the notice is in About GoLens (Acknowledgements).

#### Go AST Symbol Icons & Multi-Layer Empty-State Hero Badges
`SymbolIconView` and `EmptyStateBadgeView` (`desktop/Views/Editor/SymbolIconView.swift`, [`design/symbol-icons/`](./design/symbol-icons/README.md)) unify AST symbol iconography and workflow empty states across the IDE:

- **11 Go AST Symbol Glyphs** (`sym-func`, `sym-method`, `sym-struct`, `sym-interface`, `sym-type`, `sym-type-param`, `sym-field`, `sym-var`, `sym-const`, `sym-package`, `sym-snippet` bundled in `desktop/Resources/SymbolIcons/`): every symbol combines a distinct outer container silhouette with an inner structural mark (passing the grayscale silhouette test at 16 px in `design/symbol-icons/preview/grayscale-2x.png`).
- **Unified Resolution (`SymbolIconResolver`, `symbol-mapping.json`)**: maps LSP `SymbolKind` integers, completion kind strings, and `GoDeclaration` kinds to the same symbol set across `CompletionRowView`, `GoToSymbolPopupView` (`⌃6`), `HierarchyPopupView` (`⌃H` / `⌃⌥H`), and `BreadcrumbBarView` jump menus.
- **Tinting & Selection**: shares the dynamic `FileIconPalette` (`go`, `data`, `infra`, `web`), respects Settings ▸ General ▸ **Colored File Icons**, and switches to `alternateSelectedControlTextColor` (white) on emphasized selected rows.
- **4 Multi-Layer Empty-State Hero Badges** (`empty-profiler`, `empty-safety`, `empty-debugger`, `empty-tests` bundled in `desktop/Resources/EmptyStates/`): rendered by `EmptyStateBadgeView` as 2-layer hierarchical vector artwork (`secondary` layer in `.tertiary` + `primary` layer in `.secondary` with clear-behind `erase` cut-outs).

### 2.6 Shapes & Borders

Radii come from `CornerRadius` (`Views/Main/DesignTokens.swift`): `panel` 14, `hud` 16, `sidebarPanel` 18, `compactPanel` 8, `panelRow` / `control` 6, `small` 4 (badges, chips, small inline wells), always `style: .continuous` for new shapes. Anything inside a rounded container is concentric with it: inner radius = outer radius − inset (a 14pt panel with an 8pt content inset has 6pt row selections).

| Token | Value | Used by |
|-------|-------|---------|
| `panel` | 14 | Open Quickly, palettes, references |
| `panelRow` | 6 | Row selection inside a `panel` (14 − 8) |
| `compactPanel` | 8 | Completion list, find bar |
| `control` | 6 | Tabs, tab-bar buttons, text areas and buttons in sidebars |
| `hud` | 16 | Build HUD |
| `sidebarPanel` | 18 | Gopilot panel: matches the macOS 26 floating sidebar corner, measured on 2x captures (2026-11-08) |

**Separators.** A hairline marks a structural boundary only — between bars and the editor, the editor and the console, sidebar regions — and is the system separator (`Divider()` / `separatorColor`) at full strength. Inside a region, group with spacing and weight; never a faded `Divider().opacity(x)` or a near-invisible `primary.opacity(0.01…0.04)` fill. (Developer density: the structural hairlines stay — Xcode keeps them too.)

| Element | Corner Radius | Border |
|---------|--------------|--------|
| Tab bar | `RoundedRectangle(cornerRadius: 6)` | None |
| Tab items | `CornerRadius.control`, continuous | None (background only) |
| Completion popup, find bar | `CornerRadius.compactPanel` on the glass / material | None (glass draws its own edge) |
| Console | `RoundedRectangle(cornerRadius: 8)` | None |
| Editor | `RoundedRectangle(cornerRadius: 8)` | None |
| Buttons | `RoundedRectangle(cornerRadius: 6)` | 0.5pt, `primary.opacity(0.1)` |
| Status bar | None | 0.5pt top divider |
| Popover | System (rounded) | System |
| Tooltips | System | System |

### 2.7 Shadows

| Layer | Shadow |
|-------|--------|
| Completion popup | System window shadow (child panel) |
| Hover popover | System (NSView `shadow`) |
| Sheets | System |

---

## 3. Components

### 3.1 Window & Multi-Window Architecture (`WindowGroup`, `WorkspaceSession`, `AppEnvironment`)
- Standard macOS windows with title bar and traffic lights
- `NavigationSplitView` with `.balanced` style
- Scenes (`GoLensApp.swift`):
  - **Multi-window workspace scene**: `WindowGroup("GoLens", id: "workspace", for: URL.self)` backed by **`AppEnvironment`** (`desktop/State/AppEnvironment.swift` — global app-wide services: `ThemeManager`, `KeymapStore`, `SandboxVMManager`, `GitAccountStore`, global recent projects, global theme selection) and per-window **`WorkspaceSession`** + **`WorkspaceSessionRegistry`** (`desktop/State/WorkspaceSession.swift` — per-window `WorkspaceState`, `WindowPresentationRouter`, `sessionID`, and `workspaceURL`, injected via `@Environment(WorkspaceSession.self)` and passed down as `@Bindable var workspace`).
  - **Multi-window routing & isolation**: Two or more Go projects open simultaneously in separate macOS windows with independent `activeWorkspacePath`, `openFiles`, `activeFilePath`, `EditorPaneState` split panes, `Console` / `Terminal` sessions, `editedFiles`, and modal sheet routing. `File ▸ New Window` (`⌃⇧⌘N`, `macwindow.badge.plus`) opens an additional workspace picker window alongside open project windows. Opening a project from `WelcomeView` or `File ▸ Open Recent` when another project window is already open launches a dedicated `WindowGroup` window (or focuses the existing window if that canonical path is already open). `Open Project` from a project window also opens the project in a new window and leaves the original window unchanged. Every view, the editor and its popovers read their own window's workspace: SwiftUI views through `@Environment(\.windowWorkspace)`, `NSHostingView` / `NSHostingController` roots through `.windowScope(workspace)` (hosted roots do not inherit the window's environment), `GoLensTextView` through `workspaceState`, NSViews through `WorkspaceState.owning(window:)`. `WorkspaceState.shared` follows `WorkspaceSessionRegistry.shared.activeWorkspace` and is used only where the key window is meant: app menu commands and the Settings window. One gopls serves every open project as a workspace folder, so activating another window does not restart or re-index it (gopls in the Linux VM still serves one project at a time and restarts when the active project changes); diagnostics route by file path and PTY output by terminal ID. Every program, build, go command, external command and test run (benchmarks, fuzzing, coverage and profiles included) carries a core task id: its output, results and exit status reach only the window that started it, and are dropped once that window has closed. Test runs in different projects run side by side. Debug and search output go to the window that started them; only log lines the core writes before a task exists (for example "Open a folder first.") fall back to the window that started the latest task. The core runs one debug session at a time; starting one while another window is debugging says so and names that project. Cold launch with `-GoLensLastWorkspacePath <path>` (and optional `-GoLensLastFilePath <file>`) claims the initial `1280×820` window directly without opening duplicate windows.
  - **Auxiliary scenes**: compact Welcome window (`Window` id `welcome`), About window (`Window` id `about`), Acknowledgements window (`Window` id `acknowledgements`), and `Settings` scene (`⌘,`).
  - **About GoLens** shows the app version, the installed Go version (`go env GOVERSION` from the toolchain GoLens finds, or "Not installed"), architecture and theme, Copy System Info, the copyright line from `NSHumanReadableCopyright`, the gopher credit and an Acknowledgements link. **Check for Updates…** follows About GoLens in the app menu and Settings ▸ General ▸ Updates holds the automatic check; both use Sparkle 2 and are disabled in builds without a `SUFeedURL` (local builds), which cannot update themselves. **Acknowledgements** (`AcknowledgementsView`, `SheetSize.inspector`) has the same structure as Help ▸ Keyboard Shortcuts: header and summary, `PanelFilterBar` ("Search Components", filters by component name), then a native inset `List` with one `Section` per license text, titled by the first component it covers, an "Applies to" line when it covers several, and the license in monospaced caption text that can be selected. Its data is `desktop/Resources/Legal/ThirdPartyNotices.json`, generated with `THIRD_PARTY_NOTICES.txt` by `scripts/release/generate-notices.py` from the license files of every linked Go module, the Go standard library, every resolved Swift package and the bundled artwork; the release workflow fails when either file is stale.
- Main window minimum size: `920×580`, default size: `1280×820` (`WindowLayout` in `desktop/Views/Main/DesignTokens.swift`), with true side-by-side columns: sidebar (`min: 210, ideal: 256, max: 320`), editor/console (`minWidth: 380`), and non-overlapping Gopilot column (`min: 300, ideal: 360, max: 480`, auto-collapsing the sidebar when opened below `980pt` window width)
- Welcome window: fixed `760×480`, centered, content full-size under a transparent title bar with only the close button (minimize, zoom and full screen off), movable by its background. An empty unified toolbar gives it the system toolbar-window corner radius (~26pt) instead of a clipped view. Shown only when no project is open; it closes when a project opens and the main window takes over (HIG Windows: a window's size and purpose match its content). Reopen it from the Window menu.
  - Left pane (`WelcomeView.introPane`, `440pt` wide): a `136×136` pt circular 2D cel-shaded diorama medallion (`welcome-medallion-<default|tet|noel|halloween|hacker>.png`, `272×272` `@2x` in `desktop/Resources/WelcomeArt/`, clipped to a `Circle()` with a concentric `Stroke.hairline` border, or `Stroke.standard` under Increase Contrast; clicking cycles the seasonal costume), "GoLens", "Version x.y (build)" from the bundle, then three full-width capsule actions with an SF Symbol: Create New Project… (`plus.square`, ⇧⌘N), Clone Git Repository… (`square.and.arrow.down`), Open Existing Project… (`folder`, ⌘O); the former subtitles are their tooltips. Capsules are Liquid Glass (`glassEffect(.regular.interactive())` in one `GlassEffectContainer`) with a resting `quaternarySystemFill` that steps to tertiary on hover and secondary on press; system fills only with Reduce Transparency; a `separatorColor` border with Increase Contrast. Pane background (`desktop/Resources/WelcomeArt/`, `171.4 KB` total `< 400 KB`, static with zero launch delay): opaque calm studio vector PDF canvas (`welcome-canvas-<light|dark>[-hc].pdf`, `440×480` pt) in `ChromeColor.panelSurface` under Reduce Transparency, maintaining `>= 10:1` measured WCAG text contrast across Light, Dark, and Increase Contrast while leaving bottom room for `ToolSetupChecklist` when Go tools are missing.
  - Right pane: content layer, never glass — `.thickMaterial` (system theme) or the theme editor background. A filter field (hidden when there are no recents), then the recent projects: folder icon (`FileIconView`), bold name, path abbreviated with `~` and truncated in the middle; the full path is the tooltip. The first project is selected and the list has focus on open: ↑/↓ move, Return or double click opens, Esc clears the filter then closes (⌘W closes too). Selection is a 12pt continuous rounded rectangle in `selectedContentBackgroundColor` (theme `panelSelectionColor` for custom themes) with `alternateSelectedControlTextColor`, unemphasized when the list or window is inactive. Context menu: Open, Reveal in Finder. VoiceOver reads each row as "name, path". Empty state: "No Recent Projects" (or "No Matching Projects") in secondary text. Above the filter field sits one setup card at a time, a `.wellBackground()` group of `SetupChecklistRow`s: `ToolSetupChecklist` ("Set Up Your Mac for Go") while Go, gopls, Git or Delve is missing, otherwise the Get Started card (`GetStartedChecklistView`) until hidden. Get Started lists five real tasks in order (Open a Go Project, Go to a Definition, Run a Test from the Gutter, Stop at a Breakpoint, Find Any Command), each with a one-line how-to whose shortcuts come from `KeymapStore.shared.display(id)`; a task shows `circle` in secondary until the person does it, then `StatusTone.success`. Tasks check themselves when they happen (opening a project, a definition jump, a gutter test run, a stop at a breakpoint, opening the Command Palette), never by a click on the row. The header shows "n of 5 done" ("All done" at the end) and a Hide button; Help ▸ Get Started (`help.getStarted`, `checklist`) shows the card again and brings the Welcome window forward. Progress and the hidden state persist in `UserDefaults`.
- Settings window (⌘, from the app menu): see §3.11a. No Settings button in any toolbar.
- Title shows the project name; subtitle shows the current branch (`navigationSubtitle`), as in Xcode 26; represented URL points to the project folder. The open file is named by its tab and the jump bar, not the title. Owner request 2026-11-06 (Xcode 26 toolbar layout) supersedes the earlier file-name title.
- Toolbar (Xcode 26 layout, system placements only — macOS 26 draws the Liquid Glass; no custom glass, material or `.toolbarBackground`):
  - Leading: `ProjectTitleButton`, as in Xcode 26: `arrow.triangle.branch`, the project name (13pt semibold) and the branch below it (11pt secondary) with a `chevron.down` that appears on hover, no glass (`sharedBackgroundVisibility(.hidden)`); the window's own title is hidden but still set for the Window menu. Clicking opens the branch popover: a Find field, "Current Branch" and "Branches" (newest commit first, each with "<author> committed <date>"), choosing one switches to it, and New Branch… at the bottom. Trailing (`.primaryAction`): Run/Stop (`play.fill` ↔ `stop.fill`) and Debug (`ladybug.fill`) as one glass cluster. Deliberate deviation from Xcode 26, which leads with Run (owner decision 2026-11-06, after weighing Xcode familiarity against GoLand and VS Code habits); ⌘R, ⇧⌘R and ⌘. are unchanged.
  - Center (`.principal`): one activity pill, `ActivityPill` in `MainToolbar.swift`, 360–640pt wide. Left: the run configuration menu (`terminal`, or `shippingbox` for Docker), a tertiary `chevron.forward`, then the run destination menu (`desktopcomputer` / `square.stack.3d.up` / `server.rack`) — borderless menus without indicators, the same `RunConfigurationMenuItems` / `RunDestinationMenuItems` as the Product menu. Right: the activity status, 12pt, one line, truncated at the tail: secondary "<project>:" then the state in semibold — Ready; Building…; Running <go command>…; Testing…; Running <configuration> on <destination> (only while the current target runs); Running <program> or Running <program> and N more (when only other runs are live); Debugging <configuration> on <destination> (each live state with a mini `ProgressView`); otherwise the last finished activity (Build Succeeded / Build Failed / Tests Passed / Tests Failed / Run Failed / Finished Running <target> / Stopped <target>) plus a secondary "| Today at 14:07" (relative date, short time). Failures add the failure status symbol (`StatusTone.failure`: red `xmark.circle.fill`). The status is one accessibility element ("Activity", value = the full sentence) with the same text as its tooltip.
  - Issues: as in Xcode 26, a separate glass capsule right of the activity pill (`IssuesToolbarBadge`; the `.principal` item hides the shared toolbar background and `CenterActivityCluster` draws the pill and the badge as two `.glassEffect` capsules in one `GlassEffectContainer`, because separate `.principal` items merge into one glass shape), shown only while there are errors or warnings: `xmark.circle.fill` (white on `systemRed`) with the error count, `exclamationmark.triangle.fill` (black on `systemYellow`) with the warning count, 12pt monospaced digits; click opens the Issues navigator; VoiceOver reads "N errors, N warnings. Show Issues". The status bar no longer shows issues.
  - Every toolbar command is also in the Product menu.
- Control tint: the system theme sets no `.tint` (system accent, neutral bordered buttons); custom themes tint with their accent.
- Restore last workspace and file on launch via `UserDefaults`

### 3.2 Sidebar & Sidebar Navigators (§3.3)
- `NavigationSplitView` sidebar; no custom header (location lives in the window title/subtitle)
- Navigator selector: one compact capsule cluster at the top of the sidebar, like Xcode 26: a `quaternarySystemFill` capsule, never a second glass layer on the glass sidebar (WWDC25 "Meet Liquid Glass": avoid glass on glass; use fills for elements on glass). The active tab is a white glyph on `selectedContentBackgroundColor` (the macOS emphasized selection, built for white) with the system theme, or on the theme accent darkened only as far as 3:1 against white (4.5:1 with Increase Contrast) with custom themes; inactive tabs are `.secondary`. Icon buttons with tooltip + VoiceOver label, in Xcode's relative order: Files ⌘1 · Source Control ⌘2 · Search ⌘3 · Issues ⌘4 · Tests ⌘5 (View ▸ Navigators); ⌘0 hides/shows the navigator. Any command that needs a navigator (New File, Find in Project, Show Issues, Reveal in Navigator) reveals a hidden sidebar first
- File list selection belongs to the outline (`List(selection:)`): no tap gestures on rows. Selecting a file opens it (mouse, VoiceOver); arrow keys only move the selection (Return / ⌘↓ opens). A click selects a folder; its disclosure triangle, a double-click, Return or → expands it, as in Xcode and Finder
- **Issues navigator (`⌘4`, `IssuesNavigatorView`)**: backed by `DiagnosticsCenter` (`desktop/State/DiagnosticsCenter.swift`) with horizontal scope pills (`All · Errors · Warnings · Safety · TODOs · Bookmarks · Breakpoints`; All and its count cover what GoLens found in the code — errors, warnings, safety findings, test failures, TODOs — while bookmarks and breakpoints, which the person placed, appear and count only in their own scopes; each of TODOs, Bookmarks and Breakpoints shows its own empty state when it has no items, and Reset Filters appears only when the text filter or the Errors, Warnings or Safety scope hides existing items), `PanelFilterBar`, one-click Quick Fix, and `UnifiedEmptyState` (showing `.filteredEmpty` with `Reset Filters` whenever active filters hide items). The Breakpoints scope lists line breakpoints grouped by file (line text, then "Condition: …", "Hit count: …" or "Log message: …") and function breakpoints under "Function Breakpoints". The leading breakpoint glyph enables or disables the breakpoint (accent `arrowshape.right.fill` when enabled, secondary outline `arrowshape.right` and a "Disabled" badge when off; disabled line breakpoints are drawn at reduced opacity in the gutter). A function breakpoint the debugger couldn't set shows the warning status and the reason in plain language. Delete Breakpoint is the trailing row button and a context menu item; the Delete key removes the selected breakpoint or bookmark. The filter bar accessory and the empty state offer Add Function Breakpoint…, a compact `StandardSheetShell` sheet with one Function field (empty, spaced or duplicate names are explained under the field). Line and function breakpoints, with their conditions and enabled state, are saved per project and restored when it opens. Line breakpoints move with their line while you edit an open file, through the same line-shift step that moves code lenses, test marks and coverage; a breakpoint on a deleted line stays at the line where the deletion collapsed (as Xcode does when text is removed under it). The moved line is used at once for the gutter, the Breakpoints scope and, during a debug session, Delve; Undo moves it back. Stored breakpoints stay in on-disk coordinates: a file's breakpoints are written when the file has no unsaved changes (adding, editing, enabling or disabling one) and when it is saved, while edits in an unsaved buffer never write preferences. Closing a document without saving, or replacing it with the disk version, reloads that file's breakpoints from what was stored. Bookmarks follow edits the same way, through the same line-shift step and the same storage rule; on save their line previews are refreshed
- Width: `210–320pt`, ideal `256pt` (`WindowLayout.sidebarMinWidth` / `sidebarIdealWidth` / `sidebarMaxWidth`)
- File tree is a native outline: `List(selection:)` with `.sidebar` style and recursive `DisclosureGroup`s (see §6). Small sidebar rows (`sidebarRowSize = .small`, Xcode navigator density) at the 12 pt text size; system selection (accent with focus, unemphasized gray without) and disclosure; External Libraries is a collapsible sidebar `Section`.
- Lazy-load children only for expanded folders
- Selection follows the active file
- Names use the label color (white on an active selection); git status is a trailing `GitStatusBadge` (see §2.1)
- Test navigator: native outline (`List(selection:)`, `.sidebar` style, `DisclosureGroup`s) of packages → test functions and `BenchmarkXxx` functions → table rows (`t.Run` / `b.Run`), `testify/suite` methods (`suite.Run(t, ...)`), and reported subtests, from `go test -json`. Status symbol before each name: passed = green `checkmark.circle.fill`, failed = red `xmark.circle.fill`, skipped = `minus.circle`, not run = `circle` (both `.secondary`), running = mini `ProgressView`. Names in the label color; when code coverage has been run, package rows display their statement-weighted coverage percentage (`78%` in SF Mono 10pt `.secondary`); when benchmarks have been run, benchmark and sub-benchmark rows display their metric summary (`1042 ns/op · 256 B/op · 3 allocs/op` in SF Mono 10pt `.secondary`). A borderless icon bar above the list: Run All Tests (`play.fill`), Run Tests with Coverage (`shield.lefthalf.filled`, `⌃⇧⌘U`), Profile All Tests (`gauge.with.dots.needle.67percent`, `⌃⌥⌘P`), Rerun Failed Tests (`arrow.counterclockwise`), Stop Testing (`stop.fill`), Clear Coverage (`xmark.shield`, shown when coverage data is active), Refresh (`arrow.clockwise`), each with a tooltip and accessibility label. Hovered rows show monochrome Run / Debug buttons; the same commands (plus Run Tests with Coverage, Profile Tests, and Run Benchmarks on package/test rows) are in the row context menu. Selecting a row opens its source line (even when a `testify/suite` method lives in a sibling `_test.go` file). A footer summarises the last run ("6 passed · 2 failed · 1 skipped"). Empty state: `ContentUnavailableView("No Tests")`. Results, coverage, benchmarks, and profiles are kept for the session only
- Search navigator: results stream in while the scan runs (Go core, parallel, `.gitignore`/`vendor` aware); a new query cancels the running one
- Rename and create inline (text field in the row; Return commits, Esc cancels)
- Context menu: folder — New File, New Folder, Rename, Move to Trash…, Reveal in Finder; file — New File, New Folder (in the file's folder), Rename, Move to Trash…, Reveal in Finder; empty area — New File, New Folder; external (read-only) items — Reveal in Finder only
- New File (`⌘N`) and New Folder (`⌥⌘N`) create in the folder of the clicked row, else of the selected navigator item, else of the active editor file, else the project root (read-only locations fall back to the root). The name is typed in an inline row inside that folder, whose parents expand; the field accepts a relative path such as `handlers/user.go` and creates the missing folders, rejecting `/`-prefixed paths, `..` and empty parts with an alert. A new file opens with the caret after its inferred `package` clause; a new folder is selected. A failed creation shows an alert naming the item
- Move to Trash asks once and really moves the item to the Trash (restorable in Finder)

### 3.3 Tab Bar
- No custom background (window background shows through)
- Horizontal scroll for many open files
- Active tab: `primary` 15% opacity background, medium weight
- Inactive tab: no background
- Duplicate filename disambiguation: when two or more open tabs share the same filename (e.g., `cmd/server/main.go` and `cmd/cli/main.go`), each colliding tab appends its parent folder name in `.secondary` 10pt (`main.go — server`)
- Close button (xmark) on hover
- Click tab to switch, double-click to close
- Markdown files show preview toggle button

### 3.4 Editor
- `NSTextView` with `isRichText = false` (plain code)
- Line numbers via `NSRulerView` subclass
- Syntax highlighting via Tree-sitter + Go FFI semantic tokens, plus allocation-light sub-token highlighting inside Go string literal arguments of `time.Format` / `time.AppendFormat` / `time.Parse` / `time.ParseInLocation` (reference time tokens `2006`, `01`–`06`, `15`, `PM`, `MST`, `Z07:00`, fractional seconds) and `regexp.Compile*` / `regexp.MustCompile*` / `regexp.Match*` (escapes, groups/anchors, character classes, quantifiers)
- Symbol occurrence highlighting (`textDocument/documentHighlight`): placing the caret on an identifier in a Go file (debounced 150ms, ≤ 200 ranges) highlights read/text occurrences in `selectedTextBackgroundColor` (28% alpha) and write occurrences in `controlAccentColor` (22% alpha); cleared immediately on edit or selection change
- Multiple cursors (`GoLensTextView+MultiCursor.swift`): several insertion points and selections edited together.
  - Adding: Edit ▸ Add Cursor Above / Below (`⌥⌘↑` / `⌥⌘↓`, same column, a shorter line takes its end); `⌥`-click or `⌃⇧`-click (Xcode) adds a cursor and removes one that is already there; `⌥`-drag selects a column, one cursor per line (`⌥⇧`-drag adds to the existing cursors); Find ▸ Select Next Occurrence adds the next match as a selection.
  - Editing: typing, Delete, Forward Delete, word and line deletes, Return (keeps the line's indent, adds one level after an opening bracket), Tab and Shift-Tab (indent and outdent the selected lines), arrow, word and line movement with or without Shift, Copy, Cut and Paste act on every cursor. Paste gives each cursor its own line when the clipboard has as many lines as there are cursors. Brackets pair at empty cursors and wrap selections. Text composed with an input method is committed at every cursor.
  - Display: the primary cursor is the text view's own insertion point; every other cursor is an `NSTextInsertionIndicator` (system blink and accent behavior) and its selection is drawn in `selectedTextBackgroundColor`. The status bar shows "Ln, Col (N cursors)".
  - Undo: one step per action; a run of typing is one step named "Typing". Undo and Redo restore the cursors.
  - Ending: Esc, a plain click, or any edit made by something else (Format on Save, a refactor) returns to one cursor. Completion and inline AI suggestions stay off while there are several cursors.
- Move Symbol (`MoveSymbolSheetView`, Editor ▸ Move Symbol…): one Destination field. A file name moves the declaration to that file of the same package (text move). A path with a slash is taken from the project root and moves it to that package (`core/movedecl`, on the type-checked workspace of `usageindex.CheckWorkspace`): a type takes its methods along; every use in the project gets the new qualifier; imports are added and removed per file; identifiers of the old package that the moved code still uses are qualified. The move is refused with a plain reason, and nothing is changed, when it would not compile: an unexported name on either side, a name already declared in the destination, an import cycle, a constant inside a group, a method declared in a test file, or a package that has errors. Only files built for the current build target are rewritten; in the Linux VM mode the project is loaded with the host Go toolchain.
- Diagnostics underlines (error/warning squiggles)
- Code folding markers (optional)
- **Optical Lens Margin (`OpticalLensMarginView` in `desktop/Views/Editor/OpticalLensMarginView.swift`)**: display-adaptive via `OpticalLensDisplayMode` (`Automatic` default, plus `Always Column`, `Always Inline`, `Off` in `View ▸ Code Lenses` and `Settings ▸ Editing`). On wide external displays (`screenWidth >= 1600pt` and editor width `>= 920pt`), Go code lenses and line metadata — usage count, git blame (when `View ▸ Inline Git Blame` is on), implementation markers (`arrow.down.right.circle` "N implementations" / `arrow.up.right.circle` "implements N interfaces", click jumps or lists), gopls code lenses (`go.mod` tidy, vendor, upgrades, govulncheck; `Run Test` / `Benchmark`), inline `Run go generate` on `//go:generate` directives, `.http` `Send Request` lenses, `go.mod` deprecated/retracted notes, inline debug values, and rename-usages offers — render in a dedicated **`208pt` right-edge columnar rail** (`CodeSurfaceTheme.lensMarginBackground` separated by hairline `CodeSurfaceTheme.lensDivider`, `TechnicalTypography.lensRail`, with per-item `OpticalLensAccessibilityElement` VoiceOver targets). On 13-inch/14-inch MacBooks (`screenWidth < 1600pt`) or split/narrow panes (`editorWidth < 920pt`), the reserved column and divider collapse cleanly to **`0pt`** (reclaiming 100% horizontal code width) and high-signal lenses/diagnostics float as borderless end-of-line trailing annotations `20pt` after the code while suppressing auxiliary author/blame labels; moving a window across displays updates live via `NSWindow.didChangeScreenNotification`. Markers stay in the lens layer, never the gutter (owner decision)
- Gutter (left to right): fold column (16pt), optional 3pt code-coverage stripe (solid green for covered statements, two-dash red with a 2pt gap for uncovered statements so covered vs. uncovered is distinguishable in grayscale), breakpoint shape, line number, git change stripe. Width = max(48pt, fold column + 10pt + digits × digit width) rounded up to the 8-pt grid, so 1,000+ line files get 56pt, 10,000+ get 64pt; the fold chevron never overlaps a number. Clicking the fold column on a foldable line folds; anywhere else in the gutter toggles a breakpoint. A test function, table-row, or `testify/suite` method line shows its run triangle / last result in place of the line number, as Xcode does with test diamonds; a breakpoint on that line takes precedence. Click the mark to run, right-click for Run / Debug and the breakpoint commands
- Code actions (Editor ▸ Show Code Actions, ⌥↩, and the context menu): an `NSMenu` at the insertion point with "Quick Fix", "Refactor" and "Source" section headers; disabled actions show their reason as a tooltip; "No Code Actions Available" when empty. GoLens and gopls fixes share the "Quick Fix" section; each fix is titled by the action it performs (for example "Add defer cancel()"), never by the warning text, and a finding that has no real fix offers none. Applying a fix replaces only the changed text, keeps the view on the line being edited, scrolls to the change only when it is off screen, and marks the changed lines with the system find indicator (skipped under Reduce Motion)
- Interactive gopls actions (e.g. implement interface) ask for input in a standard sheet: one form row per field (text field, toggle, number field, pop-up for enums, searchable list for lazy enums), Cancel / default button
- Breakpoint editor: transient `NSPopover` from the gutter context menu ("Add Conditional Breakpoint…", "Edit Breakpoint…"): Condition, Hit Count, Log Message fields in a columns form, footnote, Cancel / Done
- Panic banner: when the debugger stops on a panic or fatal error, the exception text is shown above the debug panes and in the console
- Inlay hints: gopls variable types, range variable types and parameter names (all on by default, each can be turned off in Settings ▸ Editing ▸ Inlay Hints; View ▸ Inlay Hints turns all of them on or off). They never change the document text, undo or edited state
- Inline values while stopped: `name: value` (tertiary, SF Mono 11pt, values clipped at 60 characters) on the line where each local was last declared or assigned before the stopped line, mapped with the Go AST; nothing on lines the variable never touched
- Inline rename: Rename Symbol… (`F2`; GoLand keymap `⇧F6`; Editor ▸ Refactor, editor context menu, Command Palette) asks gopls `prepareRename`, selects the name in the editor and marks every usage in the file with `OccurrenceHighlight.read`; the name being edited gets `OccurrenceHighlight.write` and a `Stroke.standard` outline in `OccurrenceHighlight.edited`. Typing changes every usage in the file as you type; only letters, digits and `_` are accepted inside the name, and the hint says why anything else was refused. A non-key `FloatingPopup` hint (`InlineRenameHintView`, `floatingPanelBackground(cornerRadius: CornerRadius.compactPanel)`, at most `PopupWidth.compact`) under the line shows "Rename ‘name’", the usage count or the reason it can't rename, and "Press Return to rename everywhere, or Esc to cancel." Return renames through gopls across the workspace: one undo step named "Rename" per file, open buffers edited in place. Esc or ⌘Z cancels and restores the name and the selection. Moving the caret out of the name, clicking elsewhere, switching files or opening a popup finishes the rename; an invalid name there cancels it with a notice. If gopls refuses, the typed name stays in place with the reason in the hint so it can be fixed or cancelled. VoiceOver announces the start and the result
- Rename-usages offer: after editing a declaration's name in place, the lens area shows "Rename Usages of ‘old’ to ‘new’ ⌥↩" in `linkColor`; it is also the first Refactor item of the code-action menu. Never applied automatically; accepting renames through gopls and is one undo step. Editing elsewhere dismisses it
- Merge conflicts: on each `<<<<<<<` line, lens-style actions "Choose Left | Choose Right | Left Then Right | Right Then Left | Compare" (Xcode's vocabulary: Left is the local HEAD version, Right the incoming one; each item has a tooltip naming its side; each one undo step named "Choose Left", "Choose Right", "Choose Left Then Right" or "Choose Right Then Left"; Compare opens a side-by-side popover); the same actions plus Next / Previous Conflict in the context menu and as VoiceOver custom actions. A banner above the primary pane, styled like the excluded-build-tag banner, shows "N Conflicts" with Previous / Next, and "Mark “x.go” as Resolved" (saves, then `git add`) once no markers remain. When a merge has no conflicts left, Continue in the Source Control merge header opens the commit editor with git's MERGE_MSG prefilled and a "Merging — committing completes the merge" note; rebase, cherry-pick and revert still run `--continue`
- Merge editor: Open in Merge Editor (conflict banner button, the conflict row's context menu and VoiceOver action, Source Control menu) replaces the editor area with `MergeEditorView`, like History. Header: `arrow.triangle.merge`, "Merge “file”", the count left with `StatusTone` (warning while any is left, success "All conflicts resolved"), Previous / Next Conflict, an Accept All menu (Left, Right), Cancel and Apply Changes (prominent, disabled until a conflict is resolved). Three equal columns titled Left (Yours, or Upstream while rebasing) with a `MergeConflictStyle.left` (teal) dot, Result, and Right (Incoming, or Your Commit) with a `MergeConflictStyle.right` (indigo) dot. Unchanged text shows in all three in secondary color; more than 8 lines collapse to 3 above and below with "Show N Unchanged Lines". Each conflict has a control row (Accept Left `arrow.right.circle`, the status "Conflict n of N: Left / Right / Left Then Right / Right Then Left / Edited / Unresolved", a Both menu and Reset, Accept Right `arrow.left.circle`), tinted side columns, a leading 2pt bar (warning or success) and an accent outline on the current conflict. An unresolved Result shows the diff3 base (or "Choose a side, or type the result here.") in tertiary on the warning fill; typing there resolves the conflict as Edited. Apply Changes writes every resolved conflict into the open document as one undo step ("Resolve Conflicts"), leaves unresolved ones with their markers, and marks the file as resolved (save and stage) when none is left. Cancel with choices asks "Discard your merge choices?" (Discard Choices, destructive / Keep Editing)
- Diagnostics from golangci-lint merge with gopls diagnostics and name their source as secondary text, e.g. "errcheck (golangci-lint)", in the Issues navigator row, hover and annotation popup
- Auto-indentation, bracket matching, smart closing pairs
- Min height: `240pt`
- Opaque text background (content layer), no material wrapper; the breadcrumb bar shares the editor background

### 3.5 Completion Popup
- Borderless, non-activating child `NSPanel` of the editor window on Liquid Glass (§2.2); never clipped by SwiftUI layout, never takes focus
- Anchored so the name column starts at the word being completed, 2pt under the line; opens above the line when there is no room below; kept on screen
- Single-line rows: Go kind glyph (func, method, var, const, field, type, interface, struct, package, keyword, snippet; color = kind) · name with typed matches semibold · parameters in `.secondary` · right-aligned type in `.secondary` · package path in `.secondary` for unimported items; deprecated items struck through and sorted last
- Height fits up to 10 rows (scrolls beyond); width fits content between 320pt and 640pt
- Selected row: `selectedContentBackgroundColor` with `alternateSelectedControlTextColor` for every text in the row (80 % white measured 4.0:1 in light)
- Text contrast over glass, measured with `pixel-check.swift` on 2× captures (2026-10-31), worst editor backgrounds:

  | Background | Secondary text (type, params, signature) | Selected-row text | Primary text |
  |---|---|---|---|
  | White page, light | 4.97:1 | 5.37:1 | > 12:1 |
  | Dark page, dark | 6.19:1 | 6.21:1 | > 12:1 |
  | Dense colored code, light | 5.30–5.54:1 | 5.37:1 | > 12:1 |
  | Dense colored code, dark | 5.91–6.22:1 | 6.21:1 | > 12:1 |

  All pass 4.5:1 on `.regular` glass, so the rows sit directly on the glass (no extra opaque layer)
- Doc footer under the list (signature + first paragraph of the selected item), hidden when the item has no documentation; no section header
- No animation; VoiceOver announces "name, kind, type, row x of n" on selection change
- Surround With (`SurroundWithPopupView`, a member of the floating finders & popups family: `Popup.surroundWith`, `floatingPanelBackground`, `popupRow`, `PopupFieldAutoFocus`, ↑↓ / Return / Esc, Esc returns focus to the editor): a filter field "Surround With" over built-in wrappers — `if`, `for`, `func() { }()`, `go func() { }()`, `defer func() { }()` for statements and `( )` for an expression — then every enabled live template that uses `$TM_SELECTED_TEXT`, each row naming the wrapper in monospace with a one-line description. Statement wrappers (and templates whose selection variable stands alone on a line) take the whole selected lines, re-indent them one level inside the wrapper and keep the first line's indentation; `( )` and inline templates wrap the selection as is. Without a selection the current line is wrapped. The caret lands on the first tab stop (`condition` for `if` and `for`), the change is one undo step ("Undo Surround With"), and the built-ins are gofmt-clean. Outside Go files the command explains that it works in Go files
- Live templates (Settings ▸ Editing ▸ Live Templates; global, stored in the app's own preferences under `GoLensLiveTemplates`, corrupted storage falls back to the built-ins): an enabled template whose abbreviation starts with the typed word appears as a `snippet`-kind row with its description as the type and "Template" in the package column, its body in the doc footer. An exact abbreviation match is listed first; partial matches follow gopls's prefix matches. The lookup is a prefix check over the enabled templates per keystroke. Accepting expands the body with the same parser and tab-stop session as gopls snippets (`$1`, `${2:default}`, `$0`; `$TM_SELECTED_TEXT` is the selection), indents every line after the first like the caret line, and is one undo step ("Undo Insert Template"). Built-ins (`forr` range loop, `errw` wrapped error return, `tfn` table-driven test, `prl` log a value; none is a gopls keyword snippet) can be edited or disabled; Restore Defaults… resets them after a confirmation and keeps your own templates

### 3.6 Status Bar
- No material background; 0.5pt top divider
- Height: `24pt`
- Left: Show/Hide Console button (⌘⇧Y), git branch (hidden outside a Git repository), then the **workspace health item** — shown only when something needs attention, one at a time by priority: Go not found › gopls not installed › gopls stopped / restarting › offline module download › no go.mod › starting gopls / indexing. It is a borderless button (spinner while in progress, orange `exclamationmark.triangle.fill` for warnings, `wifi.exclamationmark` / `info.circle` in `.secondary` otherwise) with a short label; clicking opens a popover that says what happened and what to do, with one default action (Download Go…, Copy Command + Try Again, Restart Now, Try Again, Create go.mod with an editable module path)
- Right (only with a file open): Ln/Col, indentation, encoding, line endings
- Indentation is the only control: a compact `Menu` (`.borderlessButton`) mirroring Editor ▸ Indentation; Go files show read-only "Tabs" (gofmt). Encoding ("UTF-8", what GoLens reads and writes) and line endings (detected LF/CRLF) are read-only text. No theme picker — theme lives in Settings (HIG Windows: avoid critical actions in a bottom bar)
- `.secondary` text color at 10pt SF Pro

### 3.7 Console Area (`Console · Terminal · Profiler · Trace · Safety · HTTP · Database · Services`)
- `EditorConsoleSplitView`: an `NSSplitView` (thin divider) with editor (top) and console (bottom). Editor first: the console opens at 30 % of the height the first time, then at the height the person last dragged it to (`GoLensConsoleHeight`); window resizes go to the editor. Hiding the console collapses its pane without rebuilding the editor
- Closed by default; opens on Run/Test/Debug or on request (⌘⇧Y, View ▸ Show Console); state restored on relaunch
- Min heights: editor `240pt`, console `120pt`
- Run failure banner (top of the Console tab, inline, dismissible): "Build Failed" (red `xmark.circle.fill`, error count, Show First Error), "Program Exited with an Error" (orange triangle, exit status) or "Go Isn’t Installed" (Download Go…). Replaces the old auto-dismissing failure HUD; the success HUD stays. A remote destination problem uses the same banner with its own title and plain-language reason and one recovery button: Start Service, Install Delve, Connect in Terminal / Set Up Key in Terminal (opens a Terminal tab that runs the ssh command so the person checks the fingerprint or enters a password there; GoLens never accepts a host key on its own), Edit Destination…, or Try Again
- Terminal: when the shell exits, a bar under the terminal says so ("The shell exited (with code N).") with Restart Shell (default) and Close
- Opaque content background (no material)
- Header (`ConsoleHeaderView`): segmented control across the bottom panel tabs — **`Console · Terminal · Profiler · Trace · Safety · HTTP · Database · Services`** (plus **Debugger** while a debug session exists, with step controls: Continue (`play.fill`, replaced by Pause `pause.fill` while the program runs), Step Over, Step Into, Step Out, Stop; each with `.help` and an accessibility label, same commands and shortcuts in the Debug menu). Core tabs (`Console · Terminal`) are always present, while contextual tabs appear and activate when their workflow is used. No pane title, no run-state badge (the toolbar Run/Stop shows run state):
  - **Profiler tab** (`ProfilerView`): contextual tab shown when CPU, Memory, Block, or Mutex profile data is captured from `Profile Tests` (`⌃⌥⌘P`) or `pprof`. Includes a top control bar with a segmented mode picker (`CPU · Memory · Block · Mutex · Trace`), a **Workspace Only** filter toggle (automatically falling back to runtime/stdlib frames with a secondary notice if 0 workspace samples were recorded), table vs. flame-graph display mode, function count summary, and **Clear** button. Below it, a column header (`Function`, `Flat`, `Cum`, `Location`) and list of top functions (≤ 200 entries) sorted by Flat: function name in SF Mono 11pt `.primary`, Flat metric + percentage with a subtle accent proportion bar (`Color.accentColor.opacity(0.16)`), Cumulative metric + percentage in SF Mono 11pt `.secondary`, and `file:line` in `.secondary` 11pt; clicking a row jumps to the source line in the editor
  - **Trace tab** (`TraceTimelineView`): contextual tab used when Go execution trace data (`runtime/trace` / `go test -trace`) is captured or inspected in the Profiler/Trace workflow. Renders interactive timeline lanes for goroutine states, GC/STW phases, syscalls, and `GOMAXPROCS` processors (`P0`…`Pn`) with horizontal zoom (`1x`–`20x`), search filter, and a selected-span inspector footer (`file:line` jump support)
  - **Safety tab** (`SafetyView`): contextual tab used when running workspace vulnerability and safety scans (`Product ▸ Scan for Vulnerabilities` via `govulncheck`, or `Open in Safety (Vulnerabilities)` from the console context menu). Displays a header bar with vulnerability count and `Scan Now` (`shield.lefthalf.filled`), followed by expandable vulnerability cards showing OSV ID, fixed module version badge, summary, affected symbol call stack (clickable `file:line` links), and a one-click `Upgrade to vX.Y.Z` button
  - **HTTP tab** (`HTTPResponsesView`, labeled `Requests` / `HTTP` in the segmented header when HTTP responses exist): contextual tab used when executing requests from `.http` / `.rest` files via the editor's inline `Send Request` code lens. Shows a split view of recent HTTP requests on the left and the selected response on the right (status code badge `200 OK`, latency in `ms`, response headers, and monospaced response body with Copy and Clear History actions)
  - **Database tab** (`DatabasePanelView`, labeled `Database`): contextual tab shown while the project has data sources and a `.sql` file is active, a statement runs or results exist. `PanelListDetail` like Requests: the schema outline on the left (`PanelFilterBar` "Filter" and Refresh, then data source › schema › Tables / Views › table › columns, keys and indexes, lazily loaded; Open Table on double-click or Return, Copy Name, Disconnect; ⌘-click a table name in the attached console does the same), results on the right: a header with one segmented `Line N` item per statement when a run has several, a status summary ("500 rows loaded · 12 ms", "Updated 3 rows · 4 ms", "Failed · 1 ms") and Go to Statement (a run from a `Run SQL` lens in Go code is titled by its Go file and line, "store.go:42", and Go to Statement opens that line); a table tab's grid context menu adds Show Referenced Row on a foreign key cell and a Show Referencing Rows submenu, each opening the related table filtered by the key; `InlineBanner` for run errors (Couldn’t Connect, Password Needed, Read-Only Data Source with Edit Data Source…), statement errors and truncated multi-statement results; the `DataGridView` result grid; and a status line ("1,000 rows loaded", "Sorted loaded rows only", Fetch All, or a spinner with Stop while fetching). The console header adds Stop Statement and Close Result. The grid always keeps its header and at least one whole row: when the panel is too short, the notice, truncation and Read-Only Table banners first drop their message (it moves to the tooltip), then hide, then the status line hides, then the WHERE / ORDER BY bar; error banners and the transaction controls stay, and everything returns as the panel grows. Controls in the header and the table bar never wrap or truncate: the result summary truncates first, Transaction Active shrinks to its status symbol (the text moves to the tooltip), and the "N rows changed" count drops before Revert All and Submit Changes. Space or double-click opens the cell viewer, the debugger's value inspector popover (Formatted JSON, UTF-8 Text, Hex Dump, Copy) with a banner when the value is longer than 64 KB
  - **Services tab** (`ServicesPanelView`, `servicesTab = 7`): contextual tab shown when the project root has a Dockerfile or compose file, or after View ▸ Show Services (⌘8 in the GoLand keymap) / Tools ▸ Containers & Compose ▸ Show Services / the Docker status popover's Show in Services; it stays while selected. `PanelListDetail`: a list column (`PanelFilterBar`, native `.sidebar` `List` with one `Section` per provider headed by `ServiceSectionHeader` "Docker · <provider> · Running"; This Project (the Compose project of the workspace, stopped services always shown, a "Not Running" row with Compose Up when nothing runs), Containers (other Compose projects as disclosure rows, plain containers flat, stopped ones only with Show Stopped Containers), Images, Volumes and Networks (collapsed, loaded on expand; networks show driver or the containers that use them, built-in `bridge`, `host`, `none` have no Remove, Remove Network… is offered only for a user-created network no container uses); rows are `ServiceResourceRow` with Start or Stop and Open Shell on hover, a context menu (Show Logs, Show Details, Open Shell, Open in Browser (one item, or a submenu of `localhost:<port>` items, for published TCP ports bound to `0.0.0.0`, `::` or `127.0.0.1`; disabled while the container is stopped or the engine is not on this Mac), Restart, Stop or Start, then for This Project services Rebuild and Restart and Stop Service or Start Service (console sessions running `docker compose up -d --build`, `stop` or `start` for that service), Copy Container ID, Remove Container…) and Delete = Remove…) and a detail column (Logs: `ConsoleLogView` with its caps and a log filter, last 500 lines then live, This Project merges services with a "service | " prefix, an `InlineBanner` above a stopped container's log with Start; Details: `ServiceDetailsView` with Overview (a running container adds a Usage row "CPU 3% · Memory 42 MB of 7.7 GB", streamed at most once a second only while that container is selected, Details shows and the tab is visible), Ports (an Open in Browser link button beside each published TCP port of a running container), Environment (values masked), Mounts, Networks, Labels). The section header holds a Docker context selection menu (an icon-only `cable.connector` pull-down, current context checked and named in `.help`, the status bar's Docker item names it too; the header status then reads "Running" so the narrow column does not truncate; shown when there is more than one context; the same choices are in Tools ▸ Containers & Compose ▸ Docker Context); above the connecting and failure states the menu shows the context name next to the icon that switches the context GoLens uses without changing the Docker CLI's own, so a broken remote context can be left. Docker CLI sessions GoLens starts follow that context through the core: console sessions (Compose actions, service actions) get `DOCKER_CONTEXT` in their environment, Open Shell gets `--context <name>`. The header menu adds Clean Up…, which opens the Clean Up sheet (`StandardSheetShell` compact: stopped containers, dangling images, unused volumes, unused networks and build cache with count and size, volumes unchecked with a data-loss warning and a confirmation naming the volume count, primary "Clean Up (1.4 GB)", progress and Cancel between kinds). An engine issue from a remote context (unknown host key, sign-in, no Docker on the host) shows its title and message with the issue's own recovery, such as Connect in Terminal (a Terminal tab that runs the `ssh` command), and Retry. The header's trailing slot holds a Logs | Details segmented picker and the selected object's actions (Start or Stop, Restart, Open Shell, an `ellipsis.circle` menu). Removing asks first (`.alert` naming the object); Compose Down… asks with an `NSAlert` sheet. Nothing connects to the engine until the tab is visible in a window; the connection closes 30 s after it is hidden everywhere; at most one log stream per window. States: connecting (`.loading`), engine down (`.failed` with Open <provider> and Retry), no engine (`.empty` "No Container Engine" with Refresh), no selection (`.empty` "Select a container to see its logs.")
  - **Kubernetes section** (`KubernetesServiceProvider`, shown when a kubeconfig exists): `ServiceSectionHeader` "Kubernetes" whose status reads the namespace while live ("api", "api · Read-Only"), "Not Connected" while collapsed, "Connecting…", or the issue title with the failure tone (in the 248 pt column a status that does not fit whole yields to its symbol alone, the text staying in `.help` and VoiceOver, like the Database transaction state); its selection slot holds two `ServiceSelectionMenu`s, the context (`cable.connector`, the kubectl default marked) and the namespace (`square.dashed`, loaded when opened, "Other Namespace…" asks for a name when listing is forbidden); the actions menu holds Refresh, Read-Only for This Context, Use as kubectl Default… (an `.alert` first, because it writes `current-context`) and Apply to Cluster…. Groups Pods (expanded), Deployments and Services (collapsed) are `DisclosureGroup`s of `ServiceResourceRow`s: pods "<status> · 2/2 ready · 0 restarts · 3h" with the tone from the core (CrashLoopBackOff as "5 restarts" with the failure tone), hover Open Shell and Port Forward…; deployments "3/3 ready" with Show Pods; services "ClusterIP · 80→8080" with Port Forward…. Running port forwards are child rows "localhost:8080 → 80" with Stop and Open in Browser (ended ones read "Ended" with Close). A `ServiceListNote` says "Showing 500 of N. Filter to narrow." when a kind is capped, "No pods in “api”." when empty, and "Pods of “api”" with Show All Pods after Show Pods. A context-wide issue (Can’t Reach Cluster with the server, Credential Helper Not Found naming the helper, Sign-In Expired with Open Terminal running the sign-in command, Credentials Not Accepted) is a failure row with Retry and appears as `UnifiedEmptyState.failed` in the detail column while nothing is selected (the same holds for Docker: when the engine is down but the Kubernetes section is listed, the Docker failure or connecting state fills the detail column while nothing is selected and no expanded Kubernetes group has an issue, instead of the whole panel); a forbidden or missing namespace is a row in its group ("Can’t List Pods", "Your account can’t list pods in “api”.") with Choose Namespace…. Relisting dims a group with `.staleWhileScanning`. The detail column is the Docker grammar: pods default to Logs (`ServiceLogsView`; a crash looping pod adds an `InlineBanner` "“x” Is Failing" with Show Previous Logs; the previous container's log carries a "Previous Container" banner with Show Current Logs) and a container picker in the trailing slot when the pod has more than one; Details (`ServiceDetailsView`): Overview with Name, Namespace and Context first, one group per container (image, state, ready, restarts, last termination with the failure tone on a non-zero exit, requests, limits, ports), Conditions, Events newest first (warnings carry the warning tone), Labels collapsed. Delete Pod… and Rollout Restart… confirm with an `.alert` naming the context and namespace; Port Forward… is a system popover from the header (Contextual popovers family: what, where, Local Port with a sentence when GoLens picked another port, Cancel and Forward) that starts a console session "Forward localhost:<local> → svc/<name>:<remote>"; Open Shell opens a Terminal tab "<pod> (pod)" running `kubectl exec`. A read-only context disables Delete Pod… and Rollout Restart… and the Apply sheet says why with Turn Off Read-Only. Nothing connects until the section is expanded and the tab is visible; one watch per expanded group; collapsing a group, switching context or namespace, or hiding the tab for 30 s closes them
  - **Apply to Cluster…** (`KubernetesApplySheet`, `StandardSheetShell` wide): scope badge with the file name, subtitle "Context “x” · Namespace “y”. Review what kubectl apply changes, then apply it.", the result of `kubectl diff` on the editor buffer per object (an object menu when there are several, "Deployment “web” (New)") in `UnifiedDiffTextView`, a progress footer while it runs, an `InlineBanner` with Retry when it fails, "No Changes" when the cluster matches; Apply (disabled while comparing, after a failure and on a read-only context) runs `kubectl apply -f` as a console session
- Debug start selects Console; the first pause of a session switches to Debugger once, and later pauses never switch tabs, so a person reading Console or Terminal stays there. When the session ends, Delve is stopped and its temporary directory removed, Debugger disappears and Console is selected if Debugger was showing
- **Debugger tab**: Frames | Variables side by side in an `NSSplitView` (thin divider, each column ≥ 200pt, Frames width restored from `GoLensDebuggerFramesWidth`, 40 % the first time). Sentence-case labels, no ALL CAPS section headers
  - Goroutine filter (top of the Frames column, directly above the goroutine pop-up it filters, while paused): `PanelFilterBar` "Filter" (short enough for the 200pt column; help: function, file, goroutine ID `12` or `#12`, pprof label), then "N of M" (`.subheadline` monospaced digits, secondary; its help and VoiceOver label add how many system goroutines are hidden), then an `ellipsis.circle` More Goroutine Actions menu with a checkable Show System Goroutines and Copy Goroutine Dump / Save Goroutine Dump… (all three also in the Debug menu). It fits the column's 200pt minimum. When a filter leaves only the current goroutine, a caption under the field says so ("Only the current goroutine matches.", or "No goroutine matches “…”. The current one stays listed."). System goroutines run only runtime code and are hidden by default; the current goroutine is always listed. pprof labels come from Delve (`showPprofLabels: ["*"]` in launch and attach) and appear in the pop-up as "Goroutine #18 [worker:alpha]: …". The dump is plain text: a header with the goroutine and distinct-stack counts, then one block per identical stack ("10 goroutines: 34 [worker:alpha], 35 [worker:beta], …", system stacks last and marked "(system)"), each frame on its own line with its file:line below, frames in this project prefixed with "> ". Taking a dump while the program runs explains that it must be paused first
  - Frames column: goroutine pop-up button at the top (goroutines grouped by identical stack: "Goroutine 35: calc.TestMul.func1 — calc_test.go:26" or "4 goroutines: worker.run — pool.go:40"; the current goroutine first), then that goroutine's frames in a plain `NSTableView` (function in SF Mono 11pt, `file:line` right-aligned in `.secondary` SF Pro 11pt, full path as tooltip). Selecting a frame (click or ↑/↓) highlights its line in the editor and reloads Variables for it; Return or double-click also moves keyboard focus to the editor. VoiceOver reads "frame 2, testing.tRunner, testing.go line 2193"
  - Variables column: an expression field at the top ("Evaluate or add watch", Debug ▸ Evaluate Expression… ⌥F8 focuses it); Return adds the expression as a watch row (eye symbol) pinned above the locals and re-evaluated in the selected frame on every pause (≤ 50 watches, oldest dropped). Locals in a native `NSOutlineView` with Name · Value · Type columns (name and value SF Mono 11pt, type `.secondary` SF Pro 11pt); children load lazily on expand and expanded rows stay expanded across steps. Anonymous struct types show as `struct {…}` with the full type as tooltip. Context menu: Set Value… (edits in place, Return commits, Esc cancels), Add Watch, Copy Value; on a watch: Remove Watch (also Delete), Copy Value. Evaluation errors show in `.secondary`
  - Keyboard: Tab goes Frames → expression field → Variables → (sidebar, editor) → Frames; arrows move within a list; the goroutine pop-up joins the loop with Full Keyboard Access
  - The panic banner sits above both columns
- **One console** for program and debugger output: program stdout/stderr (Delve `outputMode: remote`, so debuggee output arrives as DAP output events), logpoint output, and short status lines ("Running cmd/server…", "Testing TestMul…", "Debugging TestMul/small…", "Debugger finished with the exit code 0"). Normal program `stderr` output (such as Go's `log.Println` and `http.Server` logs) uses the primary label color; red is reserved for compiler diagnostics (`file.go:line:col:`), `panic:` / `fatal error:` traces, and explicit build/test/exit failures. GoLens internals (`[GoLens Core] …`, gopls state, LSP errors, Delve's own console lines such as "Type 'dlv help'…", raw `go run` / `go test` command lines) go to the unified log (subsystem = bundle id, category `core`) and appear in the console only with Settings ▸ General ▸ Show Diagnostic Messages in Console
- **Concurrent program runs & session strip**: running a second target (e.g., `cmd/cli` while `cmd/server` is running) keeps the first target alive when their target keys differ. When two or more `RunSession`s exist, a 26pt session strip appears at the top of the Console log pane with one pill per session (status dot: green while running, `.secondary` when exited; target title in 11pt SF Pro; `stop.fill` button while running, `xmark` button to dismiss when exited)
- **Standard input (`stdin`) bar**: while a program is running in the selected session, a 26pt input bar sits at the bottom of the Console log pane (`›` prompt in SF Mono 11pt, borderless SF Mono 12pt text field with `"Standard input…"` placeholder that writes the line + `\n` to the process's stdin pipe on Return, and an `"EOF"` button that closes the stdin pipe). Prompts that do not end with `\n` flush to the console after 40ms so interactive CLI programs display their prompt before waiting for input
- Diagnostics live in the Issues navigator (sidebar), not in the console
- Log output with ANSI color stripping
- The log is one read-only `NSTextView` (`ConsoleLogView`), like Xcode's console: SF Mono at the caption size, 12pt inset, opaque content background. New output is appended and trimmed lines are deleted, never re-rendered, and each line's color and links are worked out once off the main thread, so a program printing thousands of lines keeps typing smooth. Output arrives in batches about ten times a second. Text selects across lines (⌘A, ⌘C); `file:line` links are underlined with the pointing-hand cursor. The view follows new output only while it is scrolled to the bottom; scrolling up to read stops following. Right-click a line: Copy (with a selection), Copy Line, Format JSON / Show Original JSON (lines with a JSON payload), Open in Safety (Vulnerabilities) (govulncheck lines), Select All. VoiceOver reads it as "Console Output"
- Terminal: `SwiftTerm` with Go PTY backend
- Multiple terminal sessions, tabbed with close support

### 3.8 Breadcrumb Bar
- Shows the folders between the workspace root and the file as clickable breadcrumbs (no root segment: the window subtitle already names the workspace), each with its file-type icon
- Shows current Go symbol/declaration
- SF Mono 11pt
- Compact, between tab bar and editor
- Diff mode puts its controls here, before Code | Diff: Side by Side | Inline, Stage/Unstage, Discard (destructive role, confirms). No second toolbar in the diff view and no Close Diff — Code | Diff is the way back; the diff keeps only its Original (HEAD) / Local Changes column headers
- Partial staging: a partly staged file shows an Unstaged | Staged segmented control in the jump bar and appears under both Staged Changes and Changes. Each change header has Stage Hunk (unstaged side) or Unstage Hunk (staged side); Revert Change only on the unstaged side. Clicking red/green lines selects them (⌘-click toggles, ⇧-click extends; VoiceOver action Select Line), which adds Stage/Unstage Selected Lines to that change and Stage Line to the line's context menu. Editor ▸ Stage Change at Cursor and the gutter context menu's Stage Change save first; if saving rewrites the lines, nothing is staged and an alert asks to review. The gutter compares against the staged version, so a staged change loses its gutter mark
- Source control follows Xcode 26's names and places. Menu bar **Source Control** (after Debug): Commit… ⌥⌘C, Commit Changes ⌥⇧⌘C (enabled while the commit editor can commit), Push…, Pull… ⌥⌘X, Fetch Changes, Refresh File Status; Stage All Changes, Unstage All Changes, Stage Selected Files, Unstage Selected Files, Mark as Resolved, Open in Merge Editor; Stash Changes…, Interactive Rebase…; Discard All Changes…, Discard Changes in Selected Files…; New Branch…, Switch Branch ▸; New Git Repository…, Clone…. "Selected Files" is the editor's file. Navigate ▸ Jump to Next Change ⌃\ / Jump to Previous Change ⌃⇧\ (wrap with a beep); View ▸ Show Code Review ⌥⇧⌘↩ toggles Code | Diff; Editor ▸ Comparison ▸ Inline / Side By Side (remembered)
- Change bar: clicking the gutter stripe opens a popover "Change at Line N" with bordered Show Change (`eye`), Stage Change (`plus.circle`), Discard Change (`trash`, destructive role, undoable with ⌘Z so no confirmation) and the diff sized to its lines (220pt at most). The gutter context menu says Show Change…, Stage Change, Discard Change; the editor context menu adds Stage Change and Discard Change on a changed line and Show Last Change for Line (file history at that line). The Files navigator context menu has a Source Control submenu (Stage, Unstage, Mark as Resolved, Discard Changes…)
- Pull…, Push…, Stash Changes…, New Branch… and Clone… are one set of sheets presented from the main window, whatever opened them: title, optional one-line explanation, controls, Cancel and a default action. Pull: "Pull remote changes from:" with the upstream preselected and "Rebase local changes onto upstream changes" (from `pull.rebase`). Push: "Push local changes to:" with the remote and "Include tags"; a branch without an upstream is created and tracked. Fetch, Pull and Push run one at a time; the status bar shows "Pushing…" with a Stop button and the navigator's button shows a spinner
- Committing happens in the editor area, as in Xcode 26; the navigator has no composer. The Changes tab starts with an "Uncommitted Changes" row (changed-file count) that opens the commit editor, as do Source Control ▸ Commit… and the command palette. The surface replaces the editor like History and closes with its Close button (`xmark`, Esc), opening a file, or switching workspace. Top to bottom: one header row (author `Name <email>` from git config, or an orange `exclamationmark.triangle.fill` with Copy Command when either is missing; the `Amend "<hash>"` checkbox; a Commit split button whose menu holds Commit and Push; Close), a 3 to 8 line message with "Subject: N characters" (orange past 50), a scope bar (All Changes | Unstaged | Staged centered, Unstage All and Stage All trailing), then one diff card per file in a lazy scroll view. A card header has the disclosure chevron, file icon, name and directory, a status badge per side and a File Actions menu (Stage or Unstage File, Open File, Show in Diff, Discard Changes…); its body shows each hunk with a monospaced 12pt old/new line-number gutter, a `+`/`-` marker, red and green row tints, and a trailing row with Stage Change or Unstage Change and, on the unstaged side, a destructive Discard Change without confirmation (Local History keeps a copy). Untracked and binary files get no change actions; a card shows 300 lines until Show All. A commit with nothing staged asks "No Staged Changes" first, staged files outside the workspace folder ask before committing, and success shows a green banner for 4 seconds with Show in History. Commit stays disabled while a merge conflict remains
- File discards confirm with an alert that names the file, says new files go to the Trash and that Local History keeps a copy; Delete Stash confirms. Git failures are alerts titled by the action ("Couldn’t Push", "Couldn’t Stage “x.go”") with git's message, never a generic "Source Control" alert
- History draws a commit graph in a leading column (`GitGraphCell`, layout in `desktop/Utilities/GitGraphLayout.swift`, `git log --date-order`). Lanes are 12pt wide (`GitGraphStyle.laneWidth`), nodes 8pt, lines 1.5pt, at most 12 lanes visible; every row uses the widest row's lane count so subjects stay aligned. Lane colors cycle `GitGraphStyle.laneColor` (blue, purple, teal, pink, indigo, brown, cyan, mint), never green, orange, red or yellow, which mean status. A merge commit is a hollow node. The graph is decorative for VoiceOver (hidden); the row text carries the meaning. The header has an **All Branches** checkbox (`--branches --remotes --tags HEAD`, title becomes "All Branches"). A text filter hides the graph because filtered commits are not connected
- Interactive rebase: Source Control ▸ Interactive Rebase… (commits not yet on the upstream, else the last 10) and the History commit menu's Interactively Rebase from Here… (that commit and everything after it) open one sheet (`InteractiveRebaseSheet`, `StandardSheetShell`, `.generator` size, scope badge = branch). The subtitle says how many commits are replayed onto which base, top to bottom. Each row: an action pop-up (Pick `checkmark.circle`, Reword `pencil`, Stop to Edit `pause.circle`, Squash `arrow.up.and.down.and.arrow.left.and.right`, Fixup `arrow.up.to.line`, Drop `trash`), short hash, subject (struck through for Drop, secondary with `arrow.turn.left.up` when folded into the commit above), author. Rows reorder by dragging or the footer's Move Up / Move Down (`arrow.up` / `arrow.down`). Below the list the selected commit's message; choosing Reword selects the row and makes it an editable well. Warnings use `InlineBanner`: commits already on a remote (force push needed); uncommitted changes are stashed and restored (`--autostash`). Start Rebasing is disabled with the reason in the footer while nothing changed, a Squash or Fixup has nothing above it, a Reword message is empty, or the range has a merge commit. GoLens writes git's todo itself (`sequence.editor`, `core.editor=true`; a reword is a pick plus `git commit --amend --only`), so no editor ever opens. Stop to Edit leaves the navigator's "Rebase in Progress" header saying "Stopped so you can change a commit…" with Abort Rebase… and Continue
- Docker: Product ▸ Docker ▸ Generate Dockerfile for Go Project… opens a sheet (Main package, Go version from go.mod, Runtime image with the cgo reason, Exposed port prefilled from code with where it was found, warnings, live SF Mono preview; Cancel / Create). Create never replaces an existing Dockerfile without the alert "Replace the existing Dockerfile?" (Replace is destructive) and writes .dockerignore only when missing. Run configurations have Kind: Go | Docker; Docker runs build then `docker run --rm --name golens-<project>` as console sessions, Stop stops the container, and an engine that is down blocks Run with the engine banner

### 3.9 Search Panel & `PanelFilterBar`
- **`PanelFilterBar` (`desktop/Views/Main/PanelFilterBar.swift`)**: canonical `26pt` filter bar (`.subheadline` input, leading `magnifyingglass`, clear button, trailing accessory slot, and **2-step `Esc`** where first `Esc` clears a non-empty query and second `Esc` returns focus to the list or editor) shared across all 5 sidebar navigators (`Files`, `Source Control`, `Search`, `Issues`, `Tests`) and bottom panels (`Console`, `Profiler` trace)
- Sidebar-integrated project search (case-insensitive; one result per matching line; ≤ 2,000 matches, ≤ 100 per file, files ≤ 1 MB, binary files skipped)
- Results grouped by file with highlighted match spans and optional Replace bar
- Click or Return navigates to result location; `Open in Multi-Buffer` (`⌥⌘Return`) edits matches across files in place

### 3.9a Find Bar
- Floats at the top-right of the editor (10pt from the top, 20pt from the right), 360pt wide, on Liquid Glass (§2.2)
- Row 1: magnifier · "Find" field (SF Mono 12pt) · match count "3/12" · Previous / Next Match (⇧↩ / ↩) · Close Find Bar (Esc); row 2: pencil · "Replace With" field · Replace · Replace All. Icon-only buttons carry accessibility labels and tooltips
- Contrast over glass (`pixel-check.swift`, 2026-10-31): query text 14.7:1 light / 12.6:1 dark over dense colored code; match count 5.2:1 / 6.4:1; enabled button titles > 15:1. The system placeholder ("Find", "Replace With") measures 3.9–4.3:1 in light and 5.2–5.8:1 in dark; disabled Replace titles 4.1:1 (disabled controls are exempt)

### 3.10 Modal Sheets (`WindowPresentationRouter` & `StandardSheetShell`)
- Standard macOS sheet presentation (`.sheet`); no custom background on the sheet root or on header/footer bands — the system sheet material shows through
- **Unified `WindowPresentationRouter` (strict architectural rule)**: Every workspace modal sheet is routed through **`WindowPresentationRouter`** (`desktop/State/WindowPresentationRouter.swift`, `enum PresentedWorkspaceSheet: Identifiable`), which attaches a single `.sheet(item: $router.activeSheet)` presenter per `WorkspaceSession` (`WindowPresentationRouterModifier` on `MainLayoutView`). Boolean and item presentation properties on `WorkspaceState` bridge onto `router.activeSheet` so two sheets can never attempt to present simultaneously on the same window, and presentation state stays isolated per open project window
- **`StandardSheetShell` (`desktop/Views/Main/StandardSheetShell.swift`)**: shared modal shell providing header title (`.headline`), optional monospaced scope badge, `.subheadline` subtitle, trailing header context slot, body content, divider, and standardized footer bar (`Cancel` / `Close` + optional `.borderedProminent` `.defaultAction` primary button) sized via **`SheetSize`** (`compact` 440pt, `standard` 520pt, `medium` 560pt, `wide` 620–860×400–700pt, `inspector` 660–960×440–760pt, `splitInspector` 760+×480+pt, `generator` 680–920×440–720pt)
- **Bottom-right footer bar action placement (strict HIG rule)**: `Cancel` / `Close` (`.cancelAction`) and the primary action button (`.defaultAction`) **MUST** sit in the bottom-right footer bar (`HStack { Spacer(); Button("Cancel") ...; Button("Primary") ... }`). Action or dismiss buttons (`Done`, `Cancel`, `Close`, `Insert`, `Apply`) **MUST NEVER** be placed in the top title header bar; the top header bar is strictly reserved for the sheet title, subtitle, and read-only status/count badges or scope controls. A sheet whose edits apply live still has `Cancel` in the bottom-right footer, which restores the state from when it opened
- Size: `minWidth/idealWidth/maxWidth` (and heights) via `.sheetFrame(SheetSize.*)` whenever content can wrap or grow, so nothing clips and the sheet can be resized (`sheet_size_literals` tracked downward by `scripts/design/token-ratchet.py`)
- Forms: `Form` with `.formStyle(.grouped)`; `Section("Title")` headers (never hand-styled `.headline` text); explanations in the section footer (11pt, secondary, wrapping), never in a narrow column; short labels with examples in the placeholder; fields in the grouped-form style (no `.roundedBorder`)
- **`ListDetailSheet` (`desktop/Views/Main/ListDetailSheet.swift`)**: shared shell for sheets that edit a list of named objects (Run Configurations, Data Sources): optional top `InlineBanner` slot, `List(.sidebar)` 232pt wide with one titled section, bottom bar of `ListDetailBarButton`s (+ add, − remove, disabled without a selection, trailing accessory), detail slot or empty-detail slot (`ContentUnavailableView`), footer with a leading accessory and `Cancel` (`.cancelAction`) / `Done` (`.defaultAction`) at the bottom right, `.controlSize(.large)`; `SheetSize.splitInspector` unless the consumer passes another size. Consumers never redraw its sidebar, bar or footer
- `RunConfigurationsModal` (composes `ListDetailSheet`): sidebar `List(.sidebar)` 232pt wide with a "Configurations" section (row: destination symbol, name, secondary destination, accent `checkmark.circle.fill` on the active one; context menu Set as Active, Duplicate, Delete) and a bottom bar with + / − and "Add a Configuration for Each Main Package" (`wand.and.stars`). Detail `Form(.grouped)`: General (Name, Kind segmented, Package + main-package menu); Destination (Run On; Compose File / Service + reload, or Host "user@host or alias" / Port "22 or from ~/.ssh/config" / Working Directory; Debugger Port; the footer says what Run, Test and Debug do there and that Host accepts an ~/.ssh/config alias); Connection (status on the left — "Not checked yet", spinner + "Checking <host>…", Connected + probe summary, or the issue title + message, all wrapping — bordered Check Connection on the right, the fix button below); Execution or Docker (command preview in the footer); Environment (Env File, placeholder ".env or .env.local"); Environment Variables (monospaced editor; footer "One KEY=VALUE per line…"). 760×560 minimum, 840×680 ideal, resizable
- `GoToLineSheetView`: compact line/column jump sheet (`StandardSheetShell`, `Go` / `Cancel`)
- `ChangeSignatureSheetView`: `SheetSize.standard` (`520pt`), function name input, reorderable Parameters (Name, Type, and Default call-site value for new parameters) and Return Values (Name, Type) sections, live monospaced Go signature preview (`func (recv) Name(...) ...`), Cancel / Refactor buttons
- `SourceControlSheets` (`Pull`, `Push`, `Stash`, `New Branch`, `Clone`): unified source control modal family routed via `PresentedWorkspaceSheet.sourceControl`
- `NewProjectSheetView`: Template picker, module path, location picker
- Generator sheets (`Editor ▸ Generate`, `GeneratorSheet` on `SheetSize.generator`): title and one-line subtitle, options (`GeneratorOptionToggle` stacked in a column), live `GeneratorCodePreview` (SF Mono 13pt on `CodeSurfaceTheme.background`), and `Cancel` / primary button in the bottom-right footer bar
- Focused analysis sheets (`Tools ▸ Code Analysis`, `StandardSheetShell` on `SheetSize.inspector` or `SheetSize.splitInspector`): Struct Memory Layout, Function Complexity, Compiler Optimization & Live Disassembly, Package Dependencies, and Compare Benchmarks with Baseline — while routine static safety checks run continuously in the background via `DiagnosticsCenter` and surface inline in the editor and `Issues` navigator (`⌘4`)

### 3.11 Popovers & Tooltips
- Hover tooltips: System popover appearance
- Show diagnostics message on hover over squiggly underline
- Show LSP hover info (type signature + doc) on Cmd+Opt hover
- Signature help (`SignatureHelpPopupView`): opens on `(` and `,`, or anywhere inside a call with View ▸ Parameter Info (`view.parameterInfo`: `⇧⌘Space`, `⌘P` in the GoLand keymap); while it is open, moving the caret refreshes the highlighted parameter (on the same line the popup stays in place, on another line it moves to the caret), and it closes when the caret leaves the call, on `)` or on Esc. Borderless `FloatingPopup` using `floatingPanelBackground(cornerRadius: CornerRadius.compactPanel)`, capped at `360pt` width (`maxWidth: 380pt`) with reflowed Go doc-comment paragraphs and right-edge window clamping (`8pt` margin)
- References popup (`ReferencesPopupView`): shows `file:line:col` plus a single-line trimmed source preview in SF Mono 11pt `.secondary`, with dynamic height (`44pt…320pt`) sized to the result count
- Hierarchy popup (`HierarchyPopupView`): floating panel (`Popup.hierarchy`, `560pt` wide) supporting **Call Hierarchy** (`⌃⌥H`, segmented `Callers | Callees`) and **Type Hierarchy** (`⌃H`, segmented `Supertypes | Subtypes`). Each row shows symbol kind icon (`f.cursive` / `t.square`), symbol name, `LineIndex` source preview in SF Mono 11pt `.secondary`, `file:line`, and a drill-down button (`arrow.turn.down.right` / `→`) that pivots the hierarchy root to that item; `↩` or click jumps to the location
- Quick Documentation (`QuickDocumentationPopoverView`): View ▸ Quick Documentation (`⌃⌘?`, Xcode's Quick Help key; `F1` and `⌃⇧⌘/` also work in the editor; GoLand keymap: `F1`), the editor context menu (the symbol under the pointer) and the Command Palette (the editor and caret from before the palette opened). Same content as the hover popover, `400pt` wide, plus Open Source, which goes to the declaration through Go to Definition (Navigate ▸ Back returns). The panel takes key focus so text can be selected and copied; Esc closes it and returns focus, selection and scroll position to the editor, leaving the unsaved buffer and undo untouched. States: “Loading documentation…” (Esc cancels); a symbol without a doc comment shows its signature and “No documentation comment is available for this symbol.”; “GoLens couldn’t resolve this symbol in the current project.” with Retry; no symbol at the caret: “Place the cursor on a Go symbol to view its documentation.” (the editor keeps focus)
- Quick Definition (same `QuickDocumentationPopoverView`, `PopupWidth.medium`): View ▸ Quick Definition (`⌥Space`, as in GoLand; VS Code keymap `⌥F12`, Peek Definition), the editor context menu Navigate submenu and the Command Palette. Shows the definition’s file name and line, then its source with Go highlighting: the doc comment directly above and the whole declaration up to its closing brace, common indentation removed, at most 40 lines (“Showing the first 40 lines. Open Source shows the rest.”). Reads the unsaved buffer when the file is open in a tab. Return or Open Source (the shared `PopoverLinkButton`, also used by the hover footer) opens the definition; Esc behaves as in Quick Documentation. States: “Loading definition…”; “GoLens couldn’t find the definition of this symbol in the current project.” with Retry; no symbol: “Place the cursor on a Go symbol to view its definition.” When another text field has focus, `⌥Space` is passed to it.
- No custom popover styling (use system default)

### 3.11a Settings
Xcode 26 / System Settings layout (HIG Settings, Sidebars), in the SwiftUI `Settings` scene (`desktop/Views/Settings/`).
- **Window**: `NavigationSplitView`; fixed `720pt` width, vertically resizable (minimum content height `400pt`, `720pt` tall on first open, then the saved frame); minimize and zoom dimmed; unified toolbar. Glass only on the system sidebar and toolbar; content is a standard `Form(.grouped)`. Follows the theme's light/dark appearance and accent tint, otherwise system materials and semantic colors for every theme. Switching panes changes only the detail column: no pane adds toolbar items, `.searchable` or its own width, padding or background.
- **Building blocks**: every pane and sub-page is composed from the shared blocks in `desktop/Views/Settings/SettingsComponents.swift` (`SettingsForm`, `SettingsTablePane`, `SettingsSection`, `SettingsFooter`, `SettingsNote`, `SettingsFieldRow`, `SettingsStatus`, `SettingsItemRow`, `SettingsDrillDownRow`, `SettingsActionRow`, `SettingsSearchField` and the rest); their contract is in [docs/design/component-contracts.md](docs/design/component-contracts.md#settings-pane-building-blocks). Text hierarchy: row labels and values in the body style, notes inside a group `.callout` `.secondary`, field help `.caption` `.secondary`, footers `.footnote` `.secondary`.
- **Sidebar**: `List(selection:)` of panes, each a monochrome SF Symbol + name, `200pt` column (`.toolbar(removing: .sidebarToggle)` must come before `.navigationSplitViewColumnWidth`, or the width is ignored and names truncate). Arrow keys move between panes; the last pane is restored (`GoLensSettingsPane`). Adding a pane is one entry in `SettingsPane.all`.
- **Toolbar**: Back / Forward pair (`⌘[` / `⌘]`, history across sub-pages, as in System Settings), always shown and dimmed when there is no history so the title never moves, and the title of the visible pane or sub-page.
- **Rows**: label left, control right; section headers above groups; footers one sentence in `.footnote` `.secondary`. A group with its own settings is a drill-down row: `20pt` rounded-square tile in a fixed system color with a white symbol, title, trailing secondary value, chevron; it opens a sub-page titled in the toolbar.
- **Panes**:
  - **General** (`gearshape`): Appearance — Theme, Gopher Mascot, Colored File Icons; Console — Show Diagnostic Messages in Console.
  - **Editing** (`character.cursor.ibeam`): Text — Font Size, Indent Width; Completion — Accept Completions With, AI Suggestions and Live Templates (drill-downs; Live Templates shows "n of m On" and lists each template as a `SettingsItemRow` with a Built-in badge, an enabled switch and an `ellipsis.circle` menu with Edit…, Duplicate and Delete… for your own templates, then Restore Defaults… and Add…; editing opens a `StandardSheetShell` sheet with Abbreviation, Description and a monospaced Body, explaining an empty, spaced or duplicate abbreviation under the body; curly quotes typed in the body are saved straight); Display — Inlay Hints (drill-down, value "n of 3" or "Off"), Show Minimap; Tabs — Preview Tab on Single-Click; Saving — Format on Save, Organize Imports on Save, Auto-Save When Switching Apps.
  - **Inlay Hints** sub-page: Show Inlay Hints, then Kinds — Variable Types, Range Variable Types, Parameter Names (dimmed while hints are off).
  - **Code Checks** (`checklist`): Correctness — Dropped Errors, Values Never Read, Invalid Regular Expressions (on), Shadowed Variables (off); Style — Error String Style (on), Identifier Naming, Receiver Names (off); Performance — Struct Padding, Escape Analysis (off), footer: checks run in gopls and appear as warnings in the editor and the Issues navigator; Linter — Run golangci-lint on Save. Changes apply immediately
  - **Source Control** (`arrow.triangle.branch`, after Code Checks): Git — Author Name, Author Email (written to the global git config on Return or focus loss), a `.secondary` note "This repository uses …" when the open repository overrides either, Prefer to Rebase When Pulling (`pull.rebase`); footer "Saved in ~/.gitconfig and used by every repository."; Editor — Show Source Control Changes (change bars, their popover and the gutter Stage/Discard items; Inline Git Blame is unaffected), Comparison View (Local Revision on Left Side / Right Side, swaps the columns and headers of the side-by-side diff); Status — Refresh Local Status Automatically (file-system events), Fetch and Refresh Server Status Automatically (every 15 minutes, off by default, never during a running remote operation, failures are silent); Ignored Files — a bordered list of the global excludes file (`core.excludesFile`, default `~/.config/git/ignore`) with `+` / `-` icon buttons, double-click to edit a row, saved on every change. Every control applies at once.
  - **Key Bindings** (`keyboard`): Keymap picker (GoLens, VS Code, GoLand) and Accept Completions With (the same setting as Editing ▸ Completion; it is part of the keymap), a one-line footer about the chosen keymap (one grouped section, like every other pane), then a "Search Key Bindings" field and a bordered table — Command (title, menu path in `.caption` `.secondary`), Shortcut, Source (Preset / Custom / System) — that fits the detail width without a horizontal scroll bar (`SettingsTablePane`). Clicking a shortcut records the next key press ("Type Shortcut" in the accent color): Esc cancels, Delete removes the shortcut; a letter, digit or symbol needs ⌘, ⌥ or ⌃. A shortcut used by another command asks "⌘R is used by “Run”" with Replace / Cancel; a standard macOS shortcut is refused with an alert naming it. System rows are secondary text and not editable; a shortcut that two commands share (outside the deliberate pairs in §4.2, e.g. after importing a hand-edited export) shows an orange `exclamationmark.triangle.fill` naming the other. Custom rows have a Reset to Preset button (`arrow.uturn.backward`); the row context menu has Record Shortcut, Clear Shortcut and Reset to Preset. Bottom bar: Import… (VS Code `keybindings.json`, GoLand keymap `.xml`, or a GoLens export; a review sheet lists Mapped, Removed, Not Imported and Notes before replacing the keymap), Export… (JSON), Reset All to Preset. Menus update at once.

  - **Execution** (`cpu`): first section **Linux Sandbox** (`LinuxSandboxSettingsSection`), an optional download. Status row with one trailing action: Not Installed (`StatusTone.inactive`, Download, plus a Size row "<download> download · <on disk> on disk"), Downloading… (progress bar with "x of y", Cancel), Verifying…, Installing…, Removing… (busy status, no action), Installed with "Version <v>" (`StatusTone.success`, Remove…; Update Available in `.info` adds Update), Needs an Update (`.warning`) when the installed runtime no longer fits this app. Failures sit under the status as a `SettingsNote` with the reason and Retry (a lost connection continues where it stopped; a wrong checksum or an unsigned runtime description is refused and named). Remove… asks first with the space it frees. On Intel Macs the only row is "Requires a Mac with Apple Silicon". Once installed, a toggle "Run “<project>” in the Linux Sandbox" opts the open project in, remembered per project path, never asked on open; while any open project is opted in, GoLens runs in the sandbox, and "Running On" shows macOS or Linux Sandbox. The runtime is fetched from a signed manifest (Ed25519 over the manifest bytes, which pin the archive's SHA-256) and installed atomically into Application Support/GoLens/VMRuntime.
### 3.12 Empty States, `UnifiedEmptyState` & `CommandFeedbackPresenter`
- **`UnifiedEmptyState` (`desktop/Views/Main/UnifiedEmptyState.swift`)**: canonical 4-state container across all 5 sidebar navigators and bottom panels (`Console`, `Profiler`, `Trace`, `Safety`, `HTTP`), guaranteeing distinct visual and accessible semantics for:
  1. `.empty(...)` — genuinely empty scope with explanation and optional primary action
  2. `.filteredEmpty(itemNoun:onReset:)` — active search/scope filter hides existing items, offering one-click **Reset Filters**
  3. `.loading(message:)` — asynchronous scan or discovery in progress (`ProgressView`)
  4. `.failed(title:message:recoveryTitle:recovery:onRetry:)` — actionable failure explanation with **Retry**, and optionally a prominent recovery action before it (for example **Open OrbStack**) when the cause is fixed elsewhere
- **`CommandFeedbackPresenter` (`desktop/Views/Main/CommandFeedbackPresenter.swift`)**: structured inline `InlineBanner` notice (`presentCommandFeedback(_:title:tone:)`) attached above the active workspace pane, auto-dismissing after 4 seconds or immediately on `Esc`. Replaces silent `NSSound.beep()` failures (`silent_beeps` ratcheted downward in `scripts/design/token-ratchet.py`) whenever a menu or shortcut command cannot run in the current file/cursor context
- No workspace: the Welcome window with recent projects + actions
- No run configurations: `ContentUnavailableView` explaining that Run uses “go run .” in the project folder
- Workspace open, no file selected: Keyboard icon + "Select a file to begin editing" (secondary text, 12pt)
- Each state says what happened and what to do:

| State | Where | Form |
|---|---|---|
| gopls starting / indexing / stopped / restarting / not installed; Go not found; no go.mod; offline module download | Status bar health item + popover (§3.6) | Inline |
| Build failed; program exited with an error | Top of the Console tab (§3.7) | Inline banner |
| Test failures | Test navigator summary: counts, "The console shows each failure’s output.", Rerun Failed (also Product ▸ Rerun Failed Tests ⌥⌘U) | Inline |
| Shell exited | Under the terminal (§3.7) | Inline bar |
| No terminal sessions | Terminal pane | `ContentUnavailableView` + New Terminal |
| Not a Git repository | Source Control navigator | `ContentUnavailableView` + Create Git Repository |
| Large file (> 10 MB) | Above the editor: "Large File — Read-Only", why, Open with Default App | Inline banner |
| File too large (> 50 MB) or not UTF-8 text | Editor area: "Can’t Open <name>", size and limit, Open with Default App / Show in Finder | `ContentUnavailableView` |

Every "Inline banner" above, and every banner in the editor, console and commit editor, is `InlineBanner` (`Views/Main/InlineBanner.swift`): a leading SF Symbol chosen by `InlineBannerIcon` — `.status(StatusTone)` takes both symbol and color from the app-wide `StatusTone` (`Views/Main/DesignTokens.swift`, also behind `SettingsStatus`: success `checkmark.circle.fill` green, warning `exclamationmark.triangle.fill` orange, failure `xmark.circle.fill` red), `.symbol(name)` is a monochrome secondary subject glyph (outline), `.symbol(name, tone:)` keeps an established object glyph in its status color (merge conflict `exclamationmark.circle.fill`, as in the Source Control navigator), `.accent(name)` marks something the person must do now — a `.callout` semibold title, an optional `.subheadline` secondary explanation and a selectable middle-truncated detail, trailing small actions, and an optional Dismiss (`xmark`) button. Icon, title and actions share the first text baseline. The surface is the theme's panel color (`controlBackgroundColor` for system themes) with a bottom separator; banners never tint their background. Feature views (`MergeConflictBanner`, `DockerEngineBanner`, `RunFailureBanner`, `OOMKilledBannerView`) only map state to its parameters.

---

## 4. Interaction

### 4.1 Menu Bar & 2-Tier Information Architecture
Every command is reachable from the menu bar (HIG The menu bar); no hidden shortcut-only buttons. Menus: **GoLens (Settings… ⌘,) · File · Edit · View · Find · Navigate · Editor · Product · Debug · Source Control · Tools · Window · Help**. Primary inner-loop commands (`File` through `Source Control`) stay focused on *navigate -> edit -> fix -> run/test/debug*, while secondary Go workflow utilities live under **`Tools`**. Exactly one View menu: custom items join the system View menu via `CommandGroup` placements next to `SidebarCommands`. Items that need more input end with "…"; show/hide items name the current state.
- **File**: New Window (`⌃⇧⌘N`, `macwindow.badge.plus` — opens an additional workspace picker window alongside open workspaces), New Project… (`⇧⌘N`), New File (`⌘N`), New Folder (`⌥⌘N`), Open… (`⌘O`), Open Recent (opens in a dedicated `WindowGroup` window when another workspace is already open, or focuses the existing window), Open Quickly… (`⇧⌘O`), Save (`⌘S`), Revert to Saved, Show Local History…, Close Tab (`⌘W`), Close Window (`⇧⌘W`).
- **Edit**: Duplicate, Expand Selection (`⌃⇧↑`), Shrink Selection (`⌃⇧↓`), Add Cursor Above (`⌥⌘↑`), Add Cursor Below (`⌥⌘↓`), Join Lines (`⌃⇧J`; VS Code `⌃J`), Move Line Up / Down (`⌥↑` / `⌥↓`; GoLand `⌥⇧↑` / `⌥⇧↓`), Move Statement Up / Down (Go files, `⌥⌘[` / `⌥⌘]`; GoLand `⇧⌘↑` / `⇧⌘↓`; VS Code none, because `⌥⌘[` folds there: moves the whole statement, an `if` header with its block, an if/else chain from its `} else {` line, a function with its doc comment, and stops at the enclosing block's braces with an explanation). Each is one undo step named after the command. When focus is in another text field, these keys go to that field. Paste JSON as Go Struct (`⇧⌘V`, the HIG "Paste as" slot) — enabled only when the clipboard holds a JSON object and a Go file is being edited; inserts through the text view so it is undoable ("Undo Paste JSON as Go Struct"). Plain Paste never prompts.
- **View**: Command Palette… (`⇧⌘P`, opens `OmniFinderView` in `.commands` scope), Quick Documentation (`⌃⌘?`), Quick Definition (`⌥Space`), Show/Hide Code Review (`⌥⇧⌘↩`), Split Editor (`⌃⌘T`), Show/Hide Console (`⇧⌘Y`), Show/Hide Gopilot, Inlay Hints, Minimap, Code Folding, Zoom In/Out/Actual Size (`⌃⌘0`), Navigator (`⌘0`), Navigators ▸ Files…Tests (`⌘1`–`⌘5`).
- **Unified `OmniFinderView` (`desktop/Views/Main/OmniFinderView.swift`)**: a single `Popup.omniFinder(OmniFinderScope)` floating panel (`PopupWidth.omniFinder(in:)`, `CornerRadius.panel`, `floatingPanelBackground`) unifying 4 scopes with prefix switching and scope pills:
  - **All / Open Quickly (`⇧⌘O` or double-`⇧`)**: fuzzy project files + workspace symbols (`file:42` jumps to line, `⌥↩` opens in split editor, empty query shows recent files)
  - **Commands (`>` prefix or `⇧⌘P`)**: every menu command with live `KeymapStore.shared` shortcut badges and disabled-reason explanations
  - **File Symbols (`@` prefix or `⌃6`)**: current file declarations with `SymbolIconView`
  - **Workspace Symbols (`Navigate ▸ Go to Workspace Symbol…`)**: `gopls` `workspace/symbol` search across modules
- **Find**: Find… (`⌘F`), Find Next (`⌘G`), Find Previous (`⇧⌘G`), Find in Project… (`⇧⌘F`), Use Selection for Find (`⌘E`), Select Next Occurrence (`⌥⌘E`).
- **Navigate**: Back, Forward, Recent Files… (`⇧⌘E`), Go to Symbol in File… (`⌃6`), Go to Workspace Symbol…, Go to Line… (`⌘L`), Go to Definition (`⌃⌘J`), Go to Implementation (`⌃⌘I`), Go to Type Definition (`⌃⇧⌘T`), Find References (`⌥⇧⌘F`), Jump to Test / Jump to Tested Symbol (`⇧⌘T`), Call Hierarchy (`⌃⌥H`), Type Hierarchy (`⌃H`), Bookmarks, Show Project TODOs & FIXMEs, Jump to Next/Previous Change (`⌃\` / `⌃⇧\`), Next/Previous Issue (`⌘'` / `⇧⌘'`; GoLand `F2` / `⇧F2`, VS Code `F8` / `⇧F8`): moves the caret to the next or previous line with an inline issue in the active file (errors, warnings, safety findings, test failures, in file order), wraps at the ends and opens that line's issue popup; with none, command feedback says "No issues in this file."
- **Editor**: Comment/Uncomment Selection (`⌘/`), Format Document (`⌃⌘I`), Organize Imports (`⌃⌥O`), Surround With… (no GoLens or VS Code shortcut; GoLand `⌥⌘T`, which there replaces Extract Type Definition's fallback; also first in the editor context menu of a Go file with a selection), JSON/YAML conversion (contextual), Complete Current Statement (`⌥⌘↩`; GoLand `⇧⌘↩`: closes open strings and brackets on the caret line, adds ` { }` with the caret inside after `if`, `for`, `switch`, `select`, `else`, `func`, `struct` and `interface` headers (`go func()` and `defer func()` also get the trailing `()`), adds `:` after `case` and `default`, otherwise opens a new line below with the line's indentation; one undo step, "Undo Complete Current Statement"; on a blank line, with several cursors or outside Go files it explains why nothing changed), Show Code Actions (`⌥↩`), inline AI suggestion controls, **`Refactor`** submenu (`Rename Symbol…`, `Change Signature…` `⌘F6`, `Move Symbol…`, `Extract Function…`, `Extract Variable`, `Extract Type Definition…`, `Inline Variable`, `Extract Interface`, `Implement Interface…`, `Propagate Method to Implementations…`, Go error/assignment/string intentions), **`Generate`** submenu (10 Go AST generators: Constructor & Options, Constructor, Fill Struct Fields, Modify Struct Tags, Enum / Stringer, Table-Driven Test, Test, Fuzz Test, Benchmark, Interface Mock), Stage/Discard Change at Cursor, Show File History…, Comparison (`Inline` / `Side By Side`), Indentation.
- **Product**: Run (`⌘R`), Debug (`⇧⌘R`), Attach to Process…, Build (`⌘B`), Stop (`⌘.`), Test (`⌘U`), Rerun Failed Tests (`⌥⌘U`), Run Tests with Coverage (`⌃⇧⌘U`), Clear Coverage, Auto-Test Package on Save, Profile Application, Profile Tests (`⌃⌥⌘P`), Open Profile (`.pprof`)…, Run Benchmarks (`⌃⌘U`), Run Safety Audit, Run `go generate`, Add Go Module…, Run `go mod tidy`, Run Configuration & Run Destination menus.
- **Debug**: Continue (`⌃⌘Y`), Pause (`⌃⌘Y` while running, as in Xcode; VS Code `F6`, GoLand toolbar only), Run to Cursor (`⌃⌘C`, Xcode's Continue to Current Line; GoLand `⌥F9`), Step Over (`F6`), Step Into (`F7`), Step Out (`F8`), Evaluate Expression… (`⌥F8`), Copy Goroutine Dump, Save Goroutine Dump… (no default shortcuts; while paused), Add Function Breakpoint… (no default shortcut; the debugger stops when the named function, such as `main.handler` or `(*Server).Serve`, starts; sent at session start and whenever the list changes, only when the debugger supports function breakpoints). Run to Cursor also appears at the top of the editor context menu of a Go file while debugging (it runs to the clicked line); it sets a temporary breakpoint on the line, continues, and removes it at the next stop or exit without touching the person's breakpoints. When the program is running, the file is not Go, or the line has no statement, command feedback says why.
- **Source Control**: Commit… (`⌥⌘C`), Commit Changes (`⌥⇧⌘C`), Push…, Pull… (`⌥⌘X`), Fetch Changes, Refresh File Status, Stage/Unstage All or Selected Files, Mark as Resolved, Stash Changes…, Discard Changes…, New Branch…, Switch Branch ▸, New Git Repository, Clone… (see §3.8).
- **Tools** (secondary workflow utilities, tiered outside core inner-loop menus):
  1. **`HTTP Client`**: New HTTP Request File, Run HTTP Request, Run All HTTP Requests in File, Stop HTTP Requests, HTTP Environment ▸, Show HTTP Responses.
  2. **`Containers & Compose`**: Generate Dockerfile for Go Project…, Show Services, Validate Compose File, Build Image, Compose Up, Compose Down…, Compose Logs, Show Logs, Show Details, Open Shell, Restart. Compose Up, Compose Down… and Compose Logs are enabled whenever the project has a compose file at its root; Compose Logs is a stream-backed console session. The Docker status item's popover keeps Retry.
  3. **`Code Analysis`**: Inspect Struct Memory Layout…, Inspect Function Complexity…, Compiler Optimization & Live Disassembly…, Inspect Package Dependencies…, Compare Benchmarks with Baseline… (routine static checks run continuously in `DiagnosticsCenter` and appear inline in `Issues`).
  4. **`Scratchpad & Data`**: New Go Scratch File, Convert JSON to Go Struct….
  5. **`Database`** (owner decision 2026-11-15): Data Sources…, Detect Data Sources in Project…, New Query Console, Run Statement (`⌘↩`), Run All Statements in File, Stop Statement (no default shortcut; `⌘.` belongs to Product ▸ Stop), Explain Plan, Explain Analyze, Query History…, Submit Changes (`⇧⌘↩`), Commit, Roll Back, Transaction Mode ▸ (Auto-Commit, Manual), Export Result…, Attach Console To ▸, Disconnect, Show Database Panel. Definitions live in `.golens/data-sources.json`, passwords in the Keychain; nothing connects until a statement runs or the schema is opened.
- Toolbar run configuration control (left half of the activity pill, §3.1): a borderless menu showing the active configuration's name, or "Default" (which runs `go run .`), with the same picker and Edit Run Configurations…
- Toolbar run destination control (after the configuration and a chevron in the activity pill, as Xcode's scheme › destination): a borderless menu showing where the active Go configuration runs, with its symbol — My Mac (`desktopcomputer`), a Docker Compose service (`square.stack.3d.up`, the service name) or an SSH host (`server.rack`, `user@host`). The menu lists My Mac, every service in the project's compose file and the SSH hosts already used by configurations as one inline picker (checkmark on the current one), then Add SSH Host…, Refresh Compose Services, Edit Destination…. Choosing one changes the active configuration (or creates "Default" when none exists). Product ▸ Run Destination mirrors it. Dimmed for Docker-kind configurations, which always run their image
- Run configuration editor, Go kind: a Destination section — Run On pop-up (My Mac, Docker Compose Service, SSH Host); for Compose: Compose File and Service pop-ups (Reload Services button), Working Directory ("Service default"); for SSH: Host ("user@host or alias"), Port ("22 or from ~/.ssh/config", empty by default so an ~/.ssh/config alias port wins), Working Directory ("Home folder"); both: Debugger Port ("2345"), a Connection section with a bordered Check Connection (spinner, then a green `checkmark.circle.fill` "Connected · linux/arm64 · Go 1.24 · Delve", or an orange triangle with what happened, why, and the one-click fix); the Destination footer says what Run, Test and Debug do there. Layout rules in §3.10

### 4.2 Keyboard Shortcuts

Menu shortcuts come from the active keymap (Settings ▸ Key Bindings), never from literals in the menus: every menu command has a stable ID in `desktop/Utilities/KeymapCommands.swift`, and its menu item uses `.keyboardShortcut(key("id"))`; `OmniFinderView` (`>` Commands) shows the same keymap. A keymap is a preset plus the person's overrides, stored as JSON in `GoLensKeymap`.
- **GoLens** (default): Xcode-style shortcuts verified collision-free by `scripts/keymap-check.swift` (`0` collisions across all 235 commands). Quick Documentation uses Xcode's `⌃⌘?` (`F1` also works in the editor while unbound).
- **VS Code** and **GoLand**: those IDEs' macOS defaults for the commands GoLens has (`desktop/Utilities/KeymapPresets.swift`, with sources); a command they don't bind keeps its GoLens shortcut unless the preset uses that key. Completions accept with Return in both, Tab in GoLens.
- Standard macOS shortcuts (HIG Keyboards: ⌘N, ⌘O, ⌘S, ⌘W, ⇧⌘W, ⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘,, ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A, ⌃⌘F) are the same in every keymap and can't be reassigned.
- Single-chord shortcuts only; imported chords (⌘K ⌘C) and VS Code `when` clauses are reported, not applied.
- **One command, one identity.** A command that appears in more than one place (menu, toolbar, context menu, command palette, banner or row button) is one `KeymapCommand` ID with one title and one symbol (§2.5 Symbol registry). Every surface reads its shortcut from `KeymapStore.shared.shortcut(id)`, and every displayed shortcut (palette, tooltip via `KeymapStore.shared.labeled(...)`, help text, empty state) from `KeymapStore.shared.display(id)`, so a rebinding updates all of them. `scripts/design/token-ratchet.py` tracks both literal `.keyboardShortcut("...")` and hardcoded modifier glyphs in `.help(...)` (`hardcoded_help_shortcuts`).
- **Help ▸ Keyboard Shortcuts** (`KeyboardShortcutsView`): reference window sized by `SheetSize.inspector`, opened from the Help menu (`help.keyboardShortcuts`). A native `List` with one `Section` per menu in menu-bar order, filtered live by command name, menu or shortcut through `PanelFilterBar` (`UnifiedEmptyState.filteredEmpty(itemNoun: "Shortcuts")` when nothing matches), with Customize… opening Settings ▸ Key Bindings. It reflects `KeymapStore.shared` preset switches, custom overrides (a "Custom" label) and conflicts (`StatusTone.warning`) immediately.
- Literal `.keyboardShortcut("x")` is only for window-local standard keys that are not keymap commands (⌘[ / ⌘] in Settings navigation, ⌘C in About) and `.defaultAction` / `.cancelAction` in sheets and alerts.

| Shortcut | Action |
|----------|--------|
| `⌘,` | Settings |
| `⌃⇧⌘N` | New Window |
| `⌘N` | New File |
| `⌥⌘N` | New Folder |
| `⌘⇧N` | New Project |
| `⌘O` | Open Project |
| `⌘S` | Save File |
| `⌘Q` | Quit |
| `⌘W` | Close Tab |
| `⌘R` | Run Project |
| `⌘⇧R` | Debug Project |
| `⌘.` | Stop Project |
| `⌘U` | Test (all packages) |
| `⌃⇧⌘U` | Run Tests with Coverage |
| `⌃⌥⌘P` | Profile Tests (CPU & Memory) |
| `⌃⌘U` | Run Benchmarks |
| `⌥⌘U` | Rerun Failed Tests |
| `⌘F6` | Change Signature… |
| `⌃⌥H` | Call Hierarchy |
| `⌃H` | Type Hierarchy |
| `⌃⌘Y` | Continue/Pause Debug |
| `⌃⌘C` | Run to Cursor |
| `F6` | Step Over |
| `F7` | Step Into |
| `F8` | Step Out |
| `⌥F8` | Evaluate Expression (focuses the Debugger tab's expression field) |
| `⌘L` | Go to Line |
| `⌘'` / `⇧⌘'` | Next / Previous Issue in the file |
| `⌘⇧E` | Recent Files |
| `⌘⇧O` | Open Quickly |
| `⌃6` | Go to Symbol in File |
| `⌥⌘↑` / `⌥⌘↓` | Add Cursor Above / Below |
| `⌃⇧J` | Join Lines |
| `⌥↑` / `⌥↓` | Move Line Up / Down |
| `⌥⌘[` / `⌥⌘]` | Move Statement Up / Down (Go files) |
| `⌃⌘J` | Go to Definition |
| `⌃⌘?` | Quick Documentation (`F1` and `⌃⇧⌘/` also work in the editor) |
| `⌥Space` | Quick Definition |
| `⌃⌘I` | Go to Implementation |
| `⌃⇧⌘T` | Go to Type Definition |
| `⌥⇧⌘F` | Find References |
| `⇧⌘T` | Jump to Test / Jump to Tested Symbol |
| `⌘⇧P` | Command Palette |
| `⌘⇧V` | Paste JSON as Go Struct |
| `⌘⇧Y` | Show/Hide Console |
| `⌘↩` | Run Statement (attached `.sql` console: the selection, else the statement at the caret) |
| `⇧⌘↩` | Submit Changes (the selected table tab's pending edits; opens the SQL preview). In the GoLand keymap `⇧⌘↩` is Complete Current Statement and Submit Changes moves to `⌥⌘↩` |
| `⌥⌘↩` | Complete Current Statement (Go files) |
| `⌘/` | Toggle Comment |
| `⌘F` | Find in File |
| `⌘⇧F` | Find in Project |
| `⌘E` | Use Selection for Find |
| `⌃Space` | Trigger Completions |
| `⌃N` / `⌃P` | Next/Previous Completion |
| `↩` / `⇥` | Commit Completion |
| `⇥` / `⇧⇥` | Next/Previous placeholder after committing a function |
| `⎋` | Cancel Completions |
| `⌘click` | Go to Definition; in an attached `.sql` console a table or view name of the data source opens it like Open Table (⌘-hover underlines it with the console link style: single underline, pointing hand) |
| `⌃⇥` / `⌃⇧⇥` | Move focus between editor and file tree |
| `↑` `↓` / `←` `→` / type | File tree: move, collapse/expand, type-to-select |
| `↩` / `⌘↓` / double-click | File tree: open file or toggle folder |

### 4.3 Mouse & Trackpad
- Click: Set cursor position; in the file tree a click opens a file or toggles a folder
- Drag: Select multiple lines, rearrange tabs (future)
- Double-click: Select word, close tab
- Right-click: Context menu (rename file, delete file, new file/folder)
- Scroll: Scroll editor, scroll file tree (synced)
- Hover: Show close button on tabs, highlight clickable items

### 4.4 Animation
Minimal, purposeful animations:

| Context | Animation | Duration |
|---------|-----------|----------|
| Completion scroll-to-selection | Immediate (no animation) | 0 |
| Tab selection change | Immediate (no animation) | 0 |
| File tree expand/collapse | System default (DisclosureGroup) | — |
| Popover show/hide | System default | — |
| Sheet present/dismiss | System default | — |
| Run/Stop state change | `Motion.emphasized` | 300ms |

Custom animations use `Motion` (`desktop/Views/Main/DesignTokens.swift`), never a literal curve. Each token returns `nil` (no animation) when Reduce Motion is on, so `withAnimation(Motion.quick)` and `.animation(Motion.standard, value:)` need no extra check.

| Token | Curve | Use |
|---|---|---|
| `Motion.quick` | `.smooth(duration: 0.15)` | Hover, highlight, small state changes inside one control |
| `Motion.standard` | `.snappy(duration: 0.22, extraBounce: 0)` | Showing or hiding a panel, row or inline content |
| `Motion.emphasized` | `.smooth(duration: 0.3)` (critically damped) | A state change people should notice (run and stop) |

Prefer system transitions (sheets, popovers, disclosure) over custom ones. `scripts/design/token-ratchet.py` locks literal animation curves (`animation_literals`) at `0`.

### 4.5 Selection
- Editor: Standard NSTextView selection (click-drag, shift-click, triple-click for line)
- File tree: single selection; keyboard moves the selection without opening, Return/⌘↓ opens
- Tab bar: Single active tab, no multi-select
- Console: Text selection enabled in log view
- Colored symbols in selectable rows (lists, outlines, sidebars, sheets): on the emphasized (accent) selection every symbol and its text turn `alternateSelectedControlTextColor` (white), the way AppKit draws template images; a fixed tint never sits on the accent highlight. Use `.rowTint(color)` instead of `.foregroundStyle(color)` for any tinted symbol inside a row. Only multicolor artwork keeps its colors, and only off the emphasized selection. Shape, not color, must carry the meaning (pass checkmark / fail cross), so state survives the white.

---

## 5. Editor-Specific Conventions

### 5.1 Code Styling
- Font: SF Mono 13pt Regular (`NSFont.monospacedSystemFont`)
- Tab size: Configurable (2, 4, 8 spaces), defaults to 4; the default is set in Settings ▸ Editing, the current document's in Editor ▸ Indentation or the status bar
- Indentation: Spaces (configurable), hard tabs for Go files
- Line height: NSTextView default
- Text inset: `(5, 5)` — 5pt padding on all sides
- Line length guide: Optional (not yet implemented)

### 5.2 Syntax Highlighting
- Permanent attributes on textStorage (set on text change)
- Temporary attributes on layoutManager (set by highlighting)
- Highlighting deferred by 150ms (immediate on file switch)
- Re-highlighting skipped if path and text unchanged
- Go tokenization via GetGoSyntaxTokens FFI (Go scanner)
- JSON highlighting via regex (strings = red, keys = blue, numbers = purple, booleans = teal)
- go.mod / go.work / go.sum highlighting (regex path): directives (`module`, `go`, `require`, …) in the keyword color, each version token (`v1.6.0`, `v0.0.0-2022…-33da011f77ad`, `go1.22.1`, `1.22`) as one token in the number color, comments in the comment color

### 5.3 Line Numbers
- Drawn by `GoLensTextView.drawBackground` in a gutter sized from the digit count (§3.4; 48pt minimum): fold chevrons centered in their own 16pt column at the left, numbers right-aligned 8pt from the gutter edge; breakpoints draw as a tag behind the number starting right after the fold column (§2.1 Gutter)
- Font: SF Mono 11pt (`NSFont.monospacedDigitSystemFont`)
- Color: `NSColor.secondaryLabelColor` (always dim)
- Background: `NSColor.textBackgroundColor` (matches editor)
- Right border: 1pt `NSColor.gridColor` at 20% alpha
- Drawn at text content y-position + textContainerInset.height
- Visibility-gated: only draw line numbers in the visible rect

### 5.4 Diagnostics
- Dotted underline style on error/warning ranges
- Background highlight at 15% alpha of the severity color
- Tooltip attribute on range shows diagnostic message
- Hover tooltip via LSPClient (Cmd+Opt hover for LSP info)
- Pane in console shows full diagnostic list

### 5.5 Completion
- A session starts on an identifier character after a word boundary, on `.`, or on ⌃Space; the request is sent immediately (no debounce) and a superseded request is cancelled
- Every keystroke inside the session re-filters and re-ranks the session's list locally in the same run-loop turn (prefix > word start / camel humps > subsequence; ties by gopls `sortText`)
- A new request only when the context changes (new `.`, caret leaves the word) or the list was incomplete; the popup hides until fresh results arrive; empty results and errors hide it
- Return or Tab commits with the item's `textEdit`, applies `additionalTextEdits` (auto-import) and expands parameter placeholders (Tab / ⇧Tab move between them); one undo step
- Esc dismisses; ↑/↓ and ⌃N/⌃P move with wrap-around; a click commits

### 5.6 Bracket Handling
- Auto-close: `{`, `[`, `(`, `"`, `'` insert matching pair and place cursor between
- Auto-step-over: typing `}`, `]`, `)`, `"`, `'` when cursor is before the matching char moves past it
- Delete pair: Backspace on empty pair `{}`, `[]`, `()`, `""`, `''` deletes both

### 5.7 Auto-Indentation
- On newline (Enter), match leading whitespace of current line
- Extra indent after `{`, `(`, `[`, `:` (matching tab/spaces config)
- Go files always use hard tabs for extra indent
- Between braces `{}` : insert newline + indent + closing brace + cursor at indent level

### 5.8 Markdown Preview
- Uses `AttributedString(markdown:)` with full interpreted syntax
- Falls back to plain text on parsing failure
- Rendering offloaded to background Task
- Toggle via Tab bar button: "View Mode" (preview) / "Dev Mode" (raw)
- Content padding: `24pt`

---

## 6. File Tree Conventions

### 6.1 FileItem
- `id` = `fullPath` (computed, stable for List identity)
- `children` lazy-loaded only for expanded folders
- Sorted: directories first, then files alphabetically
- Excluded binary extensions: png, jpg, jpeg, gif, tiff, bmp, pdf, zip, tar, gz, exe, dylib, so, a, o, bin, db, sqlite

### 6.2 Expansion
- Expanded state stored in `Set<String>` (full paths), persisted to UserDefaults and restored on launch
- Each `DisclosureGroup(isExpanded:)` binding routes through `toggleFolder(at:)`, which loads children on expand (lazy) — the same path for chevron clicks, ←/→ and Return
- External Libraries expansion uses the key `external_deps_root`

### 6.3 Selection and activation
- Single selection via `List(selection:)` with `.tag(fullPath)`; the selection follows `activeFilePath`
- Selecting with the keyboard never opens; activation is explicit: click (a `simultaneousGesture` tap that does not block list selection), Return or double-click (`contextMenu(forSelectionType:primaryAction:)`; folders toggle on Return only), ⌘↓
- Files outside the workspace (External Libraries) open read-only

---

## 7. Resources

- SF Symbols app (for browsing available symbols)
- [Apple HIG: macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple HIG: Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [Apple HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Apple HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple HIG: Icons](https://developer.apple.com/design/human-interface-guidelines/icons)
- [Apple HIG: Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
