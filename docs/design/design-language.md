# GoLens — Native, Focused, Explicit

Owner-approved direction: 2026-11-08 (synchronized 2026-11-12). Normative product rules for all UI work, including Gopilot. These are GoLens rules, not verbatim Apple HIG. Current official HIG remains the design authority; verify exact Apple claims at their source. This document reflects the shipped macOS 26+ architecture enforced by `scripts/design/token-ratchet.py`, `hig-lint.py`, and `scripts/smoke/gate5-audit.py`.

## Authority and scope

Read this document, component-contracts.md and ui-review-checklist.md before changing UI. This direction supersedes conflicting historical prescriptions in DESIGN_SYSTEM.md; retain its compatible implementation tokens and approved file-icon palette. Record conflicts rather than silently combining incompatible rules. Explicit owner instructions take precedence.

GoLens requires macOS 26 or later (owner decision 2026-11-15), Liquid Glass first. Reduce Transparency, Increase Contrast and Reduce Motion remain required.

## Product identity

GoLens helps people understand, edit and run Go with minimal interruption. Code and task content take visual priority. Prefer standard macOS structures and controls; custom UI needs a concrete unmet IDE need. Clarity takes priority over removing essential explanation. Users control changes, execution and recovery. Visual quality comes from hierarchy, alignment and spacing rather than ornamental containers.

## Interface grammar

| Layer | Purpose | Treatment |
| --- | --- | --- |
| Navigation | Locate and move between projects, files and sections | Native `NavigationSplitView` leading sidebar (`Files`, `Source Control`, `Search`, `Issues`, `Tests`), document tabs, breadcrumb bar, and optional trailing `GopilotPanelSurface` (`CornerRadius.sidebarPanel`) |
| Floating Control | Act on the current task, command, or selection | Unified macOS 26 toolbar (`ProjectTitleButton`, `CenterActivityCluster`, `Run/Debug`) and transient overlays (`OmniFinderView` `⇧⌘O` / `>` / `@`, `LocalSearchView`, `CompletionPanel`, `ReferencesPopupView`, `HierarchyPopupView`) built on `.floatingPanelBackground(cornerRadius:)` and `.glassControlCapsule(interactive:)` |
| Content Canvas | Read/edit code, diffs, logs, profiler lanes, and forms | Opaque `CodeSurfaceTheme` canvases (including the display-adaptive `208pt` right-edge `OpticalLensMarginView` on wide external displays `>= 1600pt` with editor width `>= 920pt`, collapsing automatically to `0pt` borderless end-of-line inline annotations on 13-inch MacBooks and split panes; user-overridable via `View ▸ Code Lenses` and `Settings ▸ Editing`) and `ThemeColor.contentSurface`; never wrapped in custom glass |
| Contextual Feedback | Explain progress, outcomes, unavailable commands, and recovery | `InlineBanner`, `CommandFeedbackPresenter` (replacing silent `NSSound.beep()`), `UnifiedEmptyState` (`.empty`, `.filteredEmpty`, `.loading`, `.failed`), and status-bar workspace health popovers anchored at the affected object |

Do not wrap every section in a card. Continuous transcripts, logs and lists use spacing or separators. Cards represent discrete actionable objects such as approvals or change proposals. Nested cards require a semantic parent-child relationship. Sheets hold finite tasks routed through one per-window `WindowPresentationRouter` (`PresentedWorkspaceSheet`); popovers hold brief contextual choices; inspectors hold information needed alongside content.

## Information ownership & Multi-window state

Every datum has a primary home. App-wide services (`ThemeManager`, `KeymapStore`, `SandboxVMManager`, `GitAccountStore`, recent projects, global theme selection) live in `AppEnvironment.shared` (`desktop/State/AppEnvironment.swift`), while each open `WindowGroup("GoLens", id: "workspace", for: URL.self)` window owns an isolated `WorkspaceSession` (`desktop/State/WorkspaceSession.swift`) wrapping its own `WorkspaceState` and `WindowPresentationRouter`. `WorkspaceState.shared` synchronizes dynamically with the active key window's `WorkspaceSession` (`WorkspaceSessionRegistry.shared`), and C FFI callbacks route by workspace/file path or terminal ID so two or more Go projects operate concurrently without cross-talk.

Additional appearances require a useful independent context. Map project identity to the project area, active file to its tab, symbol to the jump bar, run configuration/destination to run controls, activity outcome to activity with details in results, cursor/encoding to the status bar, and conversation mode/model to its composer. Primary inner-loop commands stay in `File` through `Source Control`, while secondary Go workflow utilities (`HTTP Client`, `Containers & Compose`, `Code Analysis`, `Scratchpad & Data`) live under `Tools`.

Avoid repeated location labels in adjacent chrome bands. Do not remove useful context across independent panes or windows. Repeated data must agree in scope, source and freshness. Historical snapshots are visibly distinguished from current data. Deduplicate citations by source identity and range, not basename alone; disambiguate different files with the same name.

## Visual foundations

Use system typography and semantic colors. Retain the existing shared typography/token implementation where compatible; do not invent per-view font sizes, opacity, radii or control heights. Code uses SF Mono, default 13 pt and user-adjustable. UI follows the project's system scale; long reading content must not be squeezed into metadata sizing. Essential information cannot depend on faint secondary text.

Use an 8-point spacing rhythm with 4-point compact grouping where needed. Native control metrics take precedence over forcing every dimension onto the grid. Use controlSize for control density. A new token must have a semantic role and be centrally defined before repeated use.

Accent identifies interaction/selection; red identifies error/destruction, orange warning, green success. Pair status color with text or symbols. Preserve the approved file-icon identity palette only inside its glyphs. Do not use decorative icon or surface tint to compete with state.

## Liquid Glass

Glass belongs to navigation and control layers. Prefer system materials for sidebars, toolbars and presentations. Do not obscure native material with arbitrary fills or scrims. Keep code, diff, log and transcript reading surfaces stable; do not apply custom glass to them. Group neighboring custom glass appropriately, avoid glass-on-glass and preserve identity in transitions. Validate actual rendering, including accessibility modes. Rounded corners and translucency alone do not establish native behavior.

Owner decision 2026-11-08: the Gopilot panel is treated as a trailing sidebar, not a content card. It is one Liquid Glass container that matches the navigator sidebar (inset, corner radius, header row); its transcript sits on that glass the way sidebar lists do, while code blocks and actionable cards keep their own fills. This is a scoped exception to keeping transcripts off custom glass; it does not extend to the console, logs, diffs or the editor.

## Interaction and state

Every relevant component defines initial, focused, selected, disabled, loading, empty, success, partial, error, cancelled and stale states, marking inapplicable states explicitly. Empty is not loading; offline is not zero results; old output is not a current result.

Explain essential disabled conditions at the decision point, not solely in a tooltip. Errors name the failed task, preserved data and next action. Preserve input across validation failures. Provide cancellation for operations that support it. Reversible changes expose appropriate undo. Consequential actions disclose the exact target, scope and consequences.

Keyboard and pointer actions follow native conventions. Overlays acquire the intended focus before typing and restore focus on dismissal. Escape must not silently reject a proposal or discard edits. State and asynchronous output remain bound to the right project, file, target and conversation during navigation.

## Patterns

These answer the questions agents otherwise decide differently each time. Tokens named here live in `desktop/Views/Main/DesignTokens.swift`.

**Color follows the surface (`ChromeColor` vs. `CodeSurfaceTheme`).** Window chrome (toolbars, sidebars, tab bars, `PanelFilterBar`, `InlineBanner`, sheets, popovers, Settings, alerts) always uses native macOS system materials and semantic colors (`ChromeColor` / `ThemeColor`), independent of the selected syntax theme (`usesSystemMaterials == 0` in views, enforced by `scripts/design/token-ratchet.py`). Syntax themes apply strictly to code, diff, Optical Lens Margin, console log, and terminal canvases via `CodeSurfaceTheme`. Quantitative profiler heatmaps and execution trace lanes use `DataVizTone` (never `StatusTone.failure` red), and monospaced code, lens rail, and telemetry metrics use `TechnicalTypography` (`fixed_fonts_small` 8–9 pt literals locked at `0`). Wells (`.wellBackground`, `ThemeColor.wellFill` / `wellStroke`) and status (`StatusTone`) work across both chrome and content.

**Button hierarchy.**

| Style | Use | Limit |
|---|---|---|
| `.borderedProminent` + `.keyboardShortcut(.defaultAction)` | The one primary action of a sheet, alert or form | One per view; never destructive |
| `.bordered` (default push button) | Secondary actions, Cancel (`.cancelAction`), banner and row recovery actions | |
| `.borderless` | Toolbar and bar icons, inline icon buttons, Dismiss `xmark` | Needs `.help` and an accessibility label when icon-only |
| `.link` | Inline navigation inside text ("Learn More", "Open Settings") | Not for actions that change data |
| `.plain` | Only for rows built on a shared row component (`popupRow`, list rows) that draw their own selection | Never for a standalone action |

Destructive actions use `role: .destructive`, are never the default, and say what they destroy ("Discard Changes", not "OK").

**Alerts and confirmations.** Ask only for what needs a decision now; prefer undo for reversible actions. A decision owned by a view uses SwiftUI `.alert` (two or three buttons) or `.confirmationDialog` (choices about one object); a flow started from the state layer or a menu command with no owning view uses `NSAlert`. Either way the copy follows Writing rules: the title names the exact object as a question, the message states the consequence, buttons name the action, Cancel is always present.

**Formatting values.** Never hand-roll formatting (`hand_formatting` locked at `0` in `token-ratchet.py`). Bytes: `UserMessage.byteCount(_:style:)` or `.formatted(.byteCount(style: .file))`. Integers and identifiers: `UserMessage.integer(_:)` (US-English grouping) and `UserMessage.rawIdentifier(_:)` (ungrouped PIDs/ports/hashes). Dates in the UI: relative for the last week (`RelativeDateTimeFormatter` or `.formatted(.relative(presentation: .named))`) with the absolute date and time in `.help`; older dates `.formatted(date: .abbreviated, time: .shortened)`. Durations: `TestDurationFormatter` / `Duration.formatted(.units(...))`. Counts: numerals with the correct plural via `UserMessage.count(_:_:_:)`, `.monospacedDigit()` where they update live. Machine strings (logs, file names, Git) may use `ISO8601DateFormatter`.

**Sheet routing, sizes, and shells.** Every workspace modal sheet routes through the per-window `WindowPresentationRouter` (`desktop/State/WindowPresentationRouter.swift`, single `.sheet(item: $router.activeSheet)` presenter per `WorkspaceSession`) and composes `StandardSheetShell` or `GeneratorSheet` with `SheetSize` tokens (`compact` 440, `standard` 520, `medium` 560, `wide` 620–860×400–700, `inspector` 660–960×440–760, `splitInspector` 760+×480+, `generator` 680–920×440–720). Raw `.frame(width: >= 400)` sheet literals (`sheet_size_literals`) are ratcheted downward by `token-ratchet.py`.

**Command feedback and dynamic shortcut tooltips.** Commands that cannot run in the current file or cursor context explain why via `CommandFeedbackPresenter` (`presentCommandFeedback(_:title:tone:)`) rather than failing with silent `NSSound.beep()` calls (`silent_beeps` ratcheted downward). Tooltips that advertise a keyboard shortcut read dynamically from `KeymapStore.shared.labeled(_:_:)` rather than hardcoding `⌘|⇧|⌥|⌃` glyphs inside `.help(...)` (`hardcoded_help_shortcuts` ratcheted downward).

**Sheet titles and actions** (owner decision 2026-11-10). Sheet titles are nouns taken from the command that opens them: "Inspect <Topic>…" opens the "<Topic> Inspector", with the same <Topic> words, so the menu and the sheet always name the same thing. Sheet-level actions (the primary action such as Fix All or Apply All, and Done or Close) sit in the footer at the bottom trailing edge; the header holds only context controls (scope, refresh, filters). Option groups inside a sheet always have a title; an otherwise untitled group of toggles is titled "Options".

**Strokes.** `Stroke.hairline` (0.5 pt) for separators, wells and card borders; `Stroke.standard` (1 pt) for focus and emphasis outlines. Other widths are not added.

**Glass and materials.** Only the shared surfaces apply them: `floatingPanelBackground`, `GopilotPanelSurface`, the toolbar activity cluster, and system sidebar and toolbar. A view never calls `.glassEffect` or a `Material` directly.

## Vocabulary

| Label | Meaning |
| --- | --- |
| Save | Write content to disk |
| Apply Changes | Apply proposed changes; state whether they remain unsaved |
| Cancel | Abandon a pending operation, or cancel execution where supported |
| Stop | Stop an executing process |
| Close | Dismiss what is being viewed |
| Reject | Decline a proposal |
| Retry | Attempt the failed operation again |
| Reset | Restore a specified default |
| Project Notes | Notes explicitly saved by the user for a project |
| Show in Finder | Reveal a file or folder in Finder (Xcode's term; not "Reveal in Finder") |
| Dismiss | Hide a banner or notice without acting on it |
| Refresh | Run a scan or reload again (never "Rescan" or "Reload") |
| Jump to Line | Move the editor to a finding's line (accessibility label "Jump to Line N") |
| Fix Issue / Fix All (N) | Apply the automatic fix for one finding / for every fixable finding; the full fix description goes in `.help` |
| Submit Changes | Preview the exact SQL for pending table edits and run it in one transaction (never Save; ⌘S is not used) |
| Revert Selected / Revert All | Drop pending table edits for the selected rows / for the whole table; nothing was written yet |
| Commit / Roll Back | End a database transaction, keeping or undoing its changes |
| Auto-Commit / Manual | A console's transaction mode: each statement is kept at once, or kept only on Commit |
| Transaction Active | Status text while statements have run since the last Commit or Roll Back |
| Set NULL, Add Row, Duplicate Row, Delete Rows | Table editor row and cell actions; Delete Rows only marks rows until Submit Changes |
| Count Rows | Count the rows of a table (with its filter) on request; never automatic |

Retry and Try Again are the same action: use Retry on compact controls (banners, rows, status popovers) and Try Again only as an alert or sheet button that ends a sentence-like flow. Do not mix them on one surface.

### Writing rules

Language (owner decision 2026-11-10): the UI is English only and is not localized; do not add `String(localized:)`, string catalogs or translated strings. Write for an international audience: plain words, short sentences, no idioms, slang or culture-specific references. Spelling follows Apple's US English (color, behavior, canceled) so app strings match the system-provided menus, alerts and controls around them.


| Element | Rule | Do | Don't |
|---|---|---|---|
| Buttons, menu items, toolbar labels, tab and window titles, banner and alert titles | Title Case, verb first for actions, no trailing period | "Reset Build Target", "Open with Default App" | "Reset build target", "“x” changed on disk." |
| Messages, banner explanations, footers, help, tooltips, placeholders | Sentence case, complete sentences with a period; tooltips may omit it | "Another app changed this file. Choose which version to keep." | "File modified externally" |
| Commands that need more input | End with an ellipsis character (…), never three periods | "Generate Dockerfile…" | "Generate Dockerfile..." |
| Errors | Name what failed in plain words, then what to do; no codes as the main text; never blame | "Couldn’t generate the preview. Check that the file builds, then try again." | "Failed to generate preview.", "Error: exit 2" |
| Confirmations | Title asks about the exact object; message states the consequence; buttons name the action | "Discard Changes to main.go?" / "This can’t be undone." / Discard Changes, Cancel | "Are you sure…?", Yes / No, OK |
| Status and progress | Specific and present tense | "Indexing 1,240 files…", "Build Failed" | "Please wait…", "Something went wrong" |
| Counts | Numerals, correct plural via `UserMessage.count`, monospaced digits where they update | "1 Conflict", "3 Conflicts" | "1 Conflicts", "issue(s)" |
| Tone | No exclamation marks, "please", "sorry", "oops", humor or "we" in system text | | |
| Typography in strings | Curly quotes around names (“main.go”), ’ for apostrophes, … for ellipsis, × for dimensions | | |

Text that repeats a shape comes from `UserMessage` (`desktop/Utilities/UserMessage.swift`): `previewFailed` and `readFailed` for errors, `count(_:_:_:)` for every count with a noun ("1 issue", "3 issues"; never "issue(s)"), and `humanized(_:)` for identifiers shown as labels (snake_case categories become "Returning internal slice …"). Add a function there instead of writing the sentence again. Copy changes are user-visible behavior: check smoke strings and update them in the same change.

Define Project and Workspace against the actual domain model before normalizing their labels. Do not treat different concepts as synonyms. Use concise action labels, consistent capitalization within each role and sentence case for explanatory prose. Menu, toolbar, palette, help and shortcut settings must agree on command identity and shortcuts. Icons convey a stable meaning; icon-only controls require accessible labels and help.

## Gopilot

Use the same language as the IDE, not a separate chat design system. Structure: conversation header, continuous transcript, contextual actionable state, composer with attachments, compact mode/model controls. Avoid borders around every message.

Citations preserve prose and inline code, appear consistently near the supported claim, and do not duplicate equivalent chips. Display source paths when necessary to distinguish files. Saved conversations visibly indicate read-only status; continuing activates the composer with appropriate focus.

Mode and execution permission are separate decisions. Describe permission scope concretely, not as unexplained 'safe' behavior. Model display name is primary; technical ID is secondary. Reasoning uses one discrete selection control, only exposes supported options and distinguishes Model Default from explicit effort levels.

Context controls reveal what project and sources are in scope. Preview truncation is disclosed. Change review provides a way to inspect the complete diff before deciding to apply; shortened output must not masquerade as complete review. Apply/save/undo semantics match the editor.

## Settings

Use group title, related fields, essential explanation, then status/action. Align labels and fields consistently; left-align editable URL/path/model strings inside their fields. Advanced contains optional specialized configuration, not required setup steps. Clearly identify app-wide versus project-specific settings. Model discovery belongs in the setup flow. Not loaded, loading, failed and loaded-empty are distinct. Reuse the same field, validation and recovery patterns across panes.

## Consistency policy

Compare semantic meaning, behavior, appearance and native conventions across related screens. Internal consistency does not justify a shared nonnative mistake. Intentional differences need a user-facing reason: Apply and Save must remain distinct when their consequences differ. Shared components are the default; exceptions document purpose, affected surfaces and verification. Existing implementation is evidence to inspect, not automatic authority.
