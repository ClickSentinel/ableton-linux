# Base bump: d2d1-dcomp-11.13 to d2d1-dcomp-11.14

2026-07-28. Bumped from `5c23dd1c` to `c7502574`. 218 files changed between the two bases, 11956 insertions and 3570 deletions.

## Why

Upstream's DComp tree-timer work, recommended by giang17 on issue 57:

- **Skip-unchanged composite hash** — the tree-timer composite keeps a walk hash of the composed content and skips the blit entirely when nothing changed. A parked pane's content never changes, so it goes quiet by itself, with no liveness heuristic.
- **Vacated-area host restore** — restores the host's own pixels where the composition retreats, so a closed pane leaves no fossil.
- **Move suppression** — the vacated-area restore is suppressed while the whole toplevel is moving, or the restore's erase fights live composition at ~10 Hz during window drags.

These cover the two neighbour cases patch 0054's `IsWindowVisible` gate does not: the fossil frame, and the "tab bleed" case where the pane chain stays visible while the app swaps which content window is parked behind it. Both default on, with `WINE_DCOMP_SKIP_UNCHANGED=0` and `WINE_DCOMP_HOST_RESTORE=0` as opt-outs.

Verified by content, not by commit message — a squashed snapshot branch carries neither the original SHAs nor their messages, so grepping for `324a7babe01` and friends returns nothing whether or not the change is present.

## Series outcome

52 patches, all applying to the new base with plain `git apply` and no fuzz.

| patch | outcome |
| --- | --- |
| 0045 | **dropped** — the `RevokeDragDrop` cross-process guard is already in `dlls/ole32/ole2.c` upstream |
| 0016 | **rewritten**, five hunks to one |
| 0025, 0030, 0041 | `WM_PAINT` block **superseded by upstream** |
| 0001 | conflict resolved in our favour (the `else if` chain) |
| everything else | replayed clean |

### 0016

The five-hunk version maintained a parallel `__wine_dcomp_origproc` property. That is redundant on this base: a second `CreateTargetForHwnd` never re-subclasses, the new target inherits `orig_wndproc` from its predecessor, and `__wine_dcomp_real_wndproc` already provides a window-lifetime fallback (set once in `CreateTargetForHwnd`, never removed — checked, or the forward would be a no-op).

What remains is the part that was genuinely missing: the orphaned subclass returned `DefWindowProcW` when its target property was gone, swallowing all input while the window kept painting. giang17 confirmed the same hole existed upstream and adopted the fix as `ba291fb4f20` on `d2d1-dcomp-11.0`, crediting this repo and issue 57. **That commit is not in this 11.14 snapshot** — the orphan branch there still returns `DefWindowProcW` — so the patch is still required. Drop it once a snapshot carrying `ba291fb4f20` is taken.

### The WM_PAINT supersession

Three of our patches rewrote the same block in `dcomp_target_wndproc`, and upstream has since replaced it wholesale. Upstream's version forwards `WM_PAINT` to the app's original wndproc **first**, then re-blits through `dcomp_reblit_comp_buffer()` and calls `ValidateRect`.

That resolves a tension our series never did. 0041 refused to forward at all, because forwarding "would erase the surface and let the sibling software frame show through (Learn View revert ~3s after the last present)". Upstream forwards *and* restores the composed content afterwards, so paint-driven plugins get their invalidation callback without losing the composition.

0030's contribution survives in better shape: `dcomp_comp_buffer_current()` now sits inside `dcomp_reblit_comp_buffer()` rather than at the `WM_PAINT` call site, so the stale-size guard protects every re-blit caller. That is also the function 0054 gates on `IsWindowVisible`, so the three compose in one place.

**Retest on this base:** Learn View reverting a few seconds after the last present. That was 0041's stated reason for not forwarding, and we are now forwarding.

## ResizeBuffers silently clears the present-path flags

The bump built, audited clean and ran — and 0055 did nothing. Measured on the new base: **516 MB/s and 62% of a core**, against 0.12-0.20 MB/s and ~21% on 11.13. The patch's own `FIXME` confirmed it was flagging the right window (`0x1009C`, `Ableton Live Window Class`, and nothing else), so the flag was being set and then lost.

`wined3d_swapchain_resize_buffers()` gained a `flags` parameter on this base:

```c
if (flags)
{
    if ((desc->flags ^ flags) & WINED3D_SWAPCHAIN_GDI_COMPATIBLE)
        recreate = true;
    desc->flags = flags;          /* wholesale assignment */
}
```

and `dxgi`'s `ResizeBuffers` passes `wined3d_swapchain_flags_from_dxgi(flags)` — a value derived purely from the DXGI flag set. The present-path bits are not in that set: `PREFER_GL_PRESENT`, `FORCE_GDI_PRESENT` and `PREMULTIPLIED_ALPHA` are all set by dxgi itself, outside DXGI's flags. So every `ResizeBuffers` clears them.

**This is not only our problem.** The same assignment drops `FORCE_GDI_PRESENT`, which the DComp child path in `factory.c` (`WM_WINE_DCOMP_SET_CHILD_MODE`) sets so a child visual renders into a comp buffer instead of GL-swapping to a hidden window. A resize therefore breaks upstream's own child compositing, not just our optimisation. Worth reporting.

0055 now carries the internal bits across the call. All three are preserved, not just the one we set.

### How this was found, and why the earlier checks missed it

Every static check passed: the build compiled, the audit passed 75 checks, Live launched with zero backtraces, and the patch's instrumentation showed exactly one window on the GL path. The only thing that caught it was **re-running the performance measurement on the new base**. A patch whose entire purpose is a performance characteristic needs that characteristic re-measured after a base bump — "it still applies and still logs the right window" is not evidence that it still works.

The follow-up diagnosis was: hot thread still `wined3d_cs` (so still the present path, not the new DComp tree-timer), then `+d3d` tracing showing `GL popup present` at 0 across 821 presents, then `Failed to set pixel format 81` and `Using backup DC` — which turned out to be a red herring affecting other contexts. The flags diff between the two bases was what actually explained it.

## Trap: never rebase this series with fuzzy patching

The first attempt applied the series with `patch -p1 -F3` where `git apply` failed, then regenerated the patch files from the result. It produced a series that applied perfectly and did not compile.

`patch -F3` had inserted 0001's `else if` block into the middle of an **unterminated comment** in `swapchain_blit_gdi()`:

```c
        if (swapchain->cs_present_dirty_rect_count > 0)
        {
            /* Dirty rects: accumulate only changed regions into comp buffer.
        else if (!GetPropW(swapchain->win_handle, L"__wine_dcomp_is_child")   <-- inserted here
        ...
        }
             * Use alpha-aware copy to preserve existing content ...          <-- comment resumes
```

The file still parsed, because the inserted code was inside a comment. The only symptom was `error: use of undeclared identifier 'src_w'` roughly 150 lines further down, where the brace structure had shifted `use_alpha_merge` out of the scope that declares it.

Two lessons worth keeping:

- **Fuzzy matching finds a plausible anchor, not the right one.** Verify structurally after any fuzzy apply — a brace-depth check that ignores braces inside comments and strings catches this in seconds. A naive brace count does not: it reported the block as correctly nested, because comment braces made the arithmetic come out even.
- **GNU `patch` applies hunks independently.** A patch that "fails" can still have modified the file. An earlier run left 4 of 0016's 5 hunks applied with one `.rej`, and every subsequent patch went on top of that. Always check for `.rej` files and revert the file if any appear.

## How to redo this

Do not re-apply patch files against the new tree. Replay them with real ancestry so git performs 3-way merges and surfaces conflicts:

```bash
git init bumprebase && cd bumprebase
tar -xf .../wine-base-<old>.tar.zst && git add -A && git commit -m "base: old"
OLD=$(git rev-parse HEAD)
git checkout -b newbase
rm -rf <everything but .git> && tar -xf .../wine-base-<new>.tar.zst
git add -A && git commit -m "base: new"
NEW=$(git rev-parse HEAD)
git checkout -b series $OLD
for p in patches/0*.patch; do git apply "$p" && git add -A && git commit -m "$(basename $p .patch)"; done
git rebase --onto $NEW $OLD series
```

Then export each patch as its original message header plus `git show --format= <commit>`. Four conflicts came out of this, all in files both sides were actively changing; a patch that becomes empty (0045) is dropped automatically by the rebase.

Note that `giang17/wine` rewrites its snapshot branches: the 11.13 base commit `5c23dd1c` is no longer reachable on the remote, so the old base has to come from the vendored tarball rather than from the clone.

## Version literals

The install directory name carries the Wine version (`wine-d2d1-nspa-11.13` to `-11.14`), so it appears in 24 files across `scripts/`, `bin/`, `beta/`, `build.sh`, `BUILDING.md`, `README.md`, `.gitignore` and the release workflow, plus four separate references to the base commit in `container-build.sh` alone. The previous bump renamed all of them the same way, so this one follows suit — but this is copy-pasted identity, and collapsing it to a single definition would remove a whole class of bump churn.
