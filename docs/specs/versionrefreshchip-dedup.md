# SPEC: Extract shared `VersionRefreshChip` (dedup the version/refresh control)

Status: DRAFTED, not yet ready to run. Do NOT start this until BOTH the v4.58
TopBar chip AND the TrainerBar twin are merged to `main` and device-verified
(DEVICE_CHECKS for each passed). This refactor edits their call sites; running
it while either is an unmerged PR churns code that has not been confirmed on a
real iPad yet.

Version: written against the state where login + TopBar + TrainerBar all carry
the chip. Ships as its own version, AFTER the TrainerBar twin. Do not fold into
either chip's commit.

---

## CONTEXT

The version chip / tap-to-refresh control now exists as three near-duplicate
inline elements:

- Login screen (`Login`, ~line 11565): `APP_VERSION + ' · tap to refresh'`,
  `color: var(--slate-soft)`, onClick does `window.location.replace(pathname +
  '?v=' + Date.now())` with NO confirm (login has no in-progress work).
- Admin TopBar (v4.58, in `topbar-right` near the bell): `APP_VERSION`,
  `color: var(--slate-soft)`, onClick does `window.confirm(...)` then the same
  `?v=` bust.
- TrainerBar twin (the version after v4.58): same as TopBar but
  `color: var(--side-text)` for the navy surface.

Three copies of one behavior differing only by (a) whether there is a confirm
and (b) the color token. This spec collapses them to one component. It is a
behavior-neutral refactor - the rendered output and click behavior of all three
call sites must be identical before and after.

## PHASE 1 - DIAGNOSTIC ONLY. DO NOT EDIT YET.

1. Report all three call sites verbatim: element, full inline style, onClick,
   and label text. Confirm there are exactly three and no fourth copy has
   appeared. Grep for `'?v=' + Date.now()` and `location.replace` to be sure.

2. Report the exact differences across the three: label text (login has the
   `· tap to refresh` suffix, the other two are bare `APP_VERSION`), the color
   token, the presence/absence of the confirm, and any layout style that is
   surface-specific (login uses `textAlign: 'center'` + `marginTop`, the bar
   chips do not).

3. Ripple risk: confirm the control appears NOWHERE else. If a fourth copy
   exists, STOP and report - the prop shape below may not cover it.

4. Existing helpers: confirm there is no existing shared chip/refresh helper
   already (this spec assumes there is not). Report if one exists.

Report findings and stop. Do not edit.

## PHASE 2 - FIXES

Fix A: add one `VersionRefreshChip` component.
Props: `colorToken` (string, e.g. `'var(--slate-soft)'` or
`'var(--side-text)'`), `confirm` (bool - whether to gate the reload behind
`window.confirm`), `label` (string, defaults to `APP_VERSION`), and an optional
`style` override object for surface-specific layout (login's center/marginTop).
Body renders one element whose onClick is:

    onClick: function(){
      if (confirm && !window.confirm('Reload the app? Anything you have typed and not saved will be lost.')) return;
      window.location.replace(window.location.pathname + '?v=' + Date.now());
    }

The confirm wording is the exact string the TopBar/TrainerBar chips already use.

Fix B: replace the three inline elements with `VersionRefreshChip` calls.
- Login: `confirm={false}`, `label={APP_VERSION + ' · tap to refresh'}`,
  `colorToken='var(--slate-soft)'`, style override for center + marginTop.
- TopBar: `confirm={true}`, `colorToken='var(--slate-soft)'`.
- TrainerBar: `confirm={true}`, `colorToken='var(--side-text)'`.

Each call site must render byte-identical output to what it renders today. If
any surface needs a style the prop shape does not cover, STOP and report rather
than widening the component silently.

## LINE BUDGET

Net negative or near-zero. The component adds a few lines; the three call sites
each shrink. Expect roughly `+20 / -30`. If the diff is net positive by more
than a few lines, the abstraction is not paying for itself - STOP and report.

## COMMIT

Single commit. Bump `APP_VERSION` and the trailing `/* vX.Y */` footer together
(pre-push version-match gate). Report diff stats +X/-Y per fix.

## CHECKS

node --check on the embedded JS before push. PASS required. This is
behavior-neutral, so the strongest check is a careful before/after read of each
call site's rendered element - the refactor is wrong if any chip moves, changes
color, or gains/loses the confirm. Still UNVERIFIED on device for the reload
itself; add a DEVICE_CHECKS note that all three chips still reload correctly, or
fold into the existing chip checks.

## ADJACENT SMELLS

Report, do not fix. Goes to BACKLOG.
