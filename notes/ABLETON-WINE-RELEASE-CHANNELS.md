# Release channels: stable and a second, riskier channel

Working plan, not a finished design. Two questions below gate the
architecture and neither is answered yet, so the phases after 0 are provisional.
Revise this file in place as they resolve; it is the iteration surface, and a
stale copy is worse than none.

The goal: users can install a stable build or an opt-in riskier one, switch
between them, and update to the newest of whichever they are on. The mechanics
are mostly available already — the launcher is a resolver shim, the runtime
tarball is provably relocatable, and GitHub's `/releases/latest/` excludes
prereleases so two download URLs cannot collide. What is not settled is whether
the two channels can share a Wine prefix.

## Status

| Item | State |
| --- | --- |
| Phase 0, prerequisites | done — PR #3, gate green, 126 tests |
| Q1 second prefix | answered — clone the authorised prefix |
| Q2 recency or risk | open |
| Phase 1, channel plumbing | unblocked |
| Phase 2, publishing | not started |
| Phase 3, switching | not started |
| Container layout | ready to propose, independent of channels |
| Live-detection consolidation | unblocked since PR119 landed; not started |

Phase 0 delivered: the bats suite merged and hermetic, `install.sh` selecting
the dated runtime tarball rather than whatever `sort -V` put last,
`ABLETON_WINE_ROOT` honoured in `install.sh` and `uninstall.sh`, and the
catalogue generator made locale-independent.

## Open questions

Q1 is answered — see *Prefix cloning* below. An earlier draft asserted that a
second prefix was impossible because Ableton limits activations. That was
wrong twice over: it was never tested, and it confused per-machine
authorisation with per-install activation. The answer turned out not to be
"authorise twice" but "do not create a second prefix at all — copy the first".

**Q2. Is the second channel about recency or about risk?**

Eleven releases shipped between 2026-07-14 and 2026-08-01 — one every 1.7
days. Stable already ships more often than most projects' nightlies, so a
channel differentiated by *frequency* buys almost nothing. A channel
differentiated by *risk* — where a new patch reaches testers without entering
the stable stream — is worth having, and implies publish-on-merge rather than a
cron, a name like `unstable` rather than `nightly`, and a link to
`beta/tester-kit/`, which already exists and which this plan has so far ignored.

## Prefix coupling

The constraint that broke the original design. Wine compares the prefix's
`.update-timestamp` against the runtime's `share/wine/wine.inf` mtime and runs
`wineboot --update` when they differ. Measured 2026-08-03:

```text
~/.wine-ableton/.update-timestamp          1785693417
wine-d2d1-nspa-11.13  share/wine/wine.inf  1785693417   match, no update
wine-d2d1-nspa-11.14  share/wine/wine.inf  1785324015   differs
```

Both runtimes exist on the development machine and `base-bump-11.14` is in
flight, so the realistic second channel sits on a different Wine base. Under a
shared prefix, switching to it updates the prefix, and switching back updates
it again — a Wine downgrade, which is unsupported. That invalidates
"switch back instantly and offline" in exactly the case a beta exists for.

Resolved by giving each channel its own prefix. Each then carries its own
`.update-timestamp`, matched to its own runtime, so no cross-version update
happens in either direction and the downgrade never arises. What made that
affordable is cloning rather than creating.

## Prefix cloning

A second prefix is made by copying the authorised one, not by running
`setup-prefix.sh` again. Measured 2026-08-03:

| Evidence | Consequence |
| --- | --- |
| `[Software\\Ableton\\Keys]` in `user.reg` | licence state lives inside the prefix |
| `MachineGuid` in `system.reg` | machine identity is generated per prefix — a fresh one differs, a copy does not |
| `dosdevices/c: -> ../drive_c`, relative | the prefix does not depend on its own path |
| no `wine-ableton` string in either hive | nor does it name it anywhere |
| `Documents -> $HOME/Documents` | projects are shared through the symlink, not duplicated |

So a fresh prefix would demand re-authorisation precisely because `MachineGuid`
is regenerated, and a copy does not. The copy is the same licence on the same
machine, not a second seat, and the documentation should say so.

Cost, on the development machine: an 11G prefix on ext4, which has no reflink,
so this is a real 11G copy against 47G free at 90% used. One clone fits; a
third channel would not. Write it as `cp -a --reflink=auto` regardless — the
flag costs nothing on ext4 and makes the copy near-instant and near-free on
btrfs or XFS.

Three requirements follow. Use `cp -a` and never `-L`: following symlinks would
pull `~/Documents` into the copy and balloon it far past the measured size.
Stage to a temporary path and rename on success, so an interrupted copy cannot
leave something that looks like a valid prefix. And check free space against the
measured source size first, refusing with real numbers rather than failing
halfway through.

Treat the second prefix as disposable: re-cloning from stable is the reset
path, which makes a wrecked channel a minute's work rather than a support
conversation. That argues against keeping the two in sync — let it go stale and
re-clone on demand.

Live preferences and installed packs then diverge per channel, which is VS
Code Insiders' model and is the property that closes the prefix-policy hazard a
shared prefix could never fully close: a channel cannot corrupt the other's
settings.

## Layout

Independent of channels, and proposable on its own merits. `NAME`
(`wine-d2d1-nspa-11.13`) currently serves five roles at once:

| Role | Site | Needs the Wine version |
| --- | --- | --- |
| configure prefix | `container-build.sh:13` | no — the relocation gate proves it |
| tarball internal dir | `container-build.sh:237` | no — install renames on promotion |
| artifact filename | `${NAME}-${VERSION}.tar.zst` | yes — it identifies a build |
| install directory | `~/.local/opt/wine-d2d1-nspa-11.13` | no — it is a location |
| consistency invariant | `repo-hygiene.bats` | guards the string, not the roles |

Split them. The artifact keeps the version. The install path drops it, becoming
`~/.local/opt/ableton-wine/<channel>/`, mirroring the `~/.local/share/ableton-wine/`
state directory that already exists. `install.sh` stops naming a version at all
by taking whatever single top-level directory the tarball holds, asserting there
is exactly one. Nothing is lost: `ABLETON-WINE-BUILD-INFO.txt` and
`ABLETON-WINE-PATCH-STACK.txt` sit at the root of the installed tree and record
`wine: wine-11.13` already.

Two arguments carry this without reference to channels. `uninstall.sh` cleans up
by sibling glob (`"$OPT"-rollback-*`), which a channel suffix silently breaks —
three multi-GB rollback directories on the development machine would be
orphaned. And a base bump currently moves every user's install directory;
after the split it touches the build and the artifact name only, which matters
now that 11.14 is coming.

## Migration

One-time, from flat to container. Every state gets an explicit answer and
ambiguity refuses rather than guesses:

| `ableton-wine/stable` | `wine-d2d1-nspa-11.13` | Action |
| --- | --- | --- |
| absent | absent | fresh install into `stable/`, no symlink |
| absent | real dir | migrate: `mv`, then symlink |
| absent | symlink | foreign or dangling — refuse, name the path |
| real dir | absent | already migrated, link lost — recreate |
| real dir | symlink to `stable` | steady state, nothing |
| real dir | symlink elsewhere | ambiguous — refuse |
| real dir | real dir | cannot tell which is live — refuse loudly |

The still-running check (`pgrep` for Live, Push2, anything under the runtime)
must run *before* the migration: moving the tree under a running Wine is the one
genuinely destructive failure, and that check already exists. `mv` within
`~/.local/opt` is a same-filesystem rename, so it is atomic and needs no extra
disk. Migration is skipped entirely when `ABLETON_WINE_ROOT` is set — the user
pinned a path.

Scope is exactly `$NAME`, `$NAME-rollback-*` and `$NAME.failed-*`. The
`wine-d2d1-nspa-11.11` and `-11.14` trees on the development machine are not the
installer's and are never touched.

## Compatibility

A `LAYOUT` integer beside `VERSION` and `CHANNEL` in
`~/.local/share/ableton-wine/`: `1` flat, `2` container. It makes three things
structural rather than promised.

Fresh installs never get a compatibility symlink — the legacy name simply never
exists for a new user. Only the 1 to 2 migration creates one. Sunsetting it
later is a change gated on `LAYOUT >= 2` rather than archaeology. And the next
migration, which is coming, becomes a numbered step rather than another one-off.

The symlink exists for references outside our control: a user's own scripts, an
old `.run` on a USB stick, a half-updated checkout. It is explicitly not for the
repo's own scripts — eight of them name the path today
(`ableton-live`, `max9`, `setup-prefix.sh`, `uninstall.sh`, `bench-run.sh`,
`check-live-audio.sh`, `check-m4l-fonts.sh`, `check-ntsync.sh`) and all are
updated as part of the change. A repo that depends on its own compatibility
shim has not migrated.

`ableton-vm-tools` is a separate coordination item, not a shim item:
`regression/tests/test_install.py` and `test_prefix_setup.py` assert on the
install path and go red regardless of the symlink.

## Channels

Resolution order, once Q1 settles the prefix question:

```text
1. ABLETON_WINE_ROOT                      explicit override, always wins
2. ~/.local/opt/ableton-wine/<CHANNEL>    from the marker
3. .../ableton-wine/stable                channel tree missing — warn, name it
4. ~/.local/opt/wine-d2d1-nspa-11.13      legacy, pre-migration install
```

Nothing in the new path reads *through* the symlink, so a crash mid-migration
cannot leave the resolver pointing at nothing. The marker's content becomes part
of a filesystem path and must be validated (`[a-z]+`, no slashes, no `..`)
rather than interpolated — the one genuine injection risk here.

This mirrors rustup, which is the closest analogue: toolchains live in a
container directory named per channel, the default is recorded in a settings
file, and `PATH` points at proxy shims rather than into a toolchain. The
launcher at `~/.local/bin/ableton-live` is already that shim.

## Publishing

Neovim's rolling-tag pattern, which needs no new infrastructure: keep a
permanent tag, delete and recreate the release each run with `--prerelease`.
Because `/releases/latest/` excludes prereleases, the existing stable URL is
untouched while the second channel gets its own predictable one.

Two additions the common recipes omit, both justified by a 40-minute build: skip
the run when HEAD already matches what is published, and give it a verify job
mirroring `release.yml`'s so channel users are not themselves the verification.
`nightly-build.yml` already runs `build-audit.sh`, which is what substitutes for
the human that stable gets.

## Rejected approaches

**Channel as a version suffix** (`...-11.13-beta`). Collides with the rollback
and failed-install namespace, which is flat and distinguished only by string
parsing; a channel named `rollback` would be indistinguishable from a rollback
directory. The container removes the class rather than defending against it.

**A shared prefix across channels.** The original design. Broken by the
timestamp coupling above as soon as the channels sit on different Wine bases,
which the in-flight 11.14 bump makes the normal case rather than the exception.

**Re-running `setup-prefix.sh` for the second channel.** Produces a fresh
`MachineGuid` and so demands re-authorisation. Cloning is what makes per-channel
prefixes viable at all.

## Limits

Nothing here is implemented beyond Phase 0. The prefix measurements are from one
machine, one prefix and one filesystem; an 11G prefix on ext4 with 47G free is
not a general case, and a user with a large pack library on a fuller disk is the
case the free-space precheck exists for.

The cloning evidence shows the licence state and machine identity are in the
prefix and that the prefix is path-independent. It does not prove Live tolerates
being run from a copied prefix — that needs one end-to-end test: clone, launch
from the clone, confirm it is still authorised. Everything above is inference
from where the keys live, not observation of Live accepting them.
