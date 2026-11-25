# Required UI review checklist

Use with [design-language.md](design-language.md) and [component-contracts.md](component-contracts.md). These checks supplement the developer gates (build, tests, smoke journeys, `hig-lint.py`, `scripts/smoke/gate5-audit.py`, `scripts/design/token-ratchet.py`, `scripts/design/slop_scanner.py`); they do not replace them. Record pass/fail/blocked/not-applicable with evidence. A source inspection is not a rendered or interaction test.

## Before implementation

- State the person's task, observable outcome and primary action.
- Identify the standard macOS pattern and existing shared components to reuse.
- Map information ownership, scope and freshness; justify repeated data.
- Define states, errors, recovery, focus and undo before styling.
- Compare vocabulary, commands, icons and interactions with related surfaces.
- Label guidance as official Apple, owner/project rule or design judgment; verify exact HIG/API claims at their official source.

## Before handoff

- Structure and content hierarchy make location, available actions and next step clear.
- Primary action reflects the task; consequential actions disclose scope.
- No unexplained disabled controls, ambiguous loading/empty/error or stale success.
- No accidental duplicate data/citations or contradictory status across panes.
- Labels, icons, shortcuts, selection behavior and recovery match related screens.
- Shared tokens and controls are reused; deviations have user-facing justification.
- Glass stays in control/navigation layers and does not obscure content.
- Keyboard entry, Tab, Escape and focus restoration work through consecutive actions.
- Accessibility names, roles, values and non-color status signals are verified.
- Read actual Light/Dark screenshots on macOS 26+, including long content and narrow layouts.
- Verify Reduce Transparency, Increase Contrast and Reduce Motion where relevant.
- Run required developer gates and realistic smoke journeys covering implemented changes.
- Report unverified states and blockers explicitly; linter success is not visual sign-off.

## Evidence packet

Include source/build identity, affected component roles/consumers, before/after screenshots, exercised states and journeys, consistency comparison, failures or limitations, and any intentional exceptions. Cognitive walkthroughs are not validation with real users.

For documentation-only changes, verify references and internal consistency; record runtime/visual gates as not run because product behavior was not changed. Do not claim the application complies merely because this checklist was added.
