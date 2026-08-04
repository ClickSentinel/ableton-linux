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

## Phases

Staged so the first ships user-visible value alone and nothing later blocks it.
Phase 1 needs no channel machinery, no layout change and no script
consolidation: installing the other `.run` already switches a user between
builds, because `install.sh` replaces the runtime and keeps a dated rollback.
That is crude, and it is enough.

| Phase | What | State |
| --- | --- | --- |
| 1 | Nightly builds, published | **built and verified end to end** — `mvp/nightly-builds` |
| 2 | Test suite and `ci-checks` | done, unmerged — `ci/test-suite-merge` |
| 3 | Script consolidation | partly done — `refactor/runtime-env` |
| 4 | Channels proper, and the label removed | designed; the migration is built on phase 3's branch |

Phases 2 to 4 improve phase 1, they are not prerequisites for it. Phase 2
tightens the gate. Phase 3 removes the duplication that would make phase 4
unmaintainable. Phase 4 is what lets two channels sit on different Wine bases,
which is the only real limitation phase 1 ships with.

Each phase lives on its own branch rather than one stack. Main moved underneath
this work three times in a single session — once silently rescoping a safety
gate — and a four-deep stack against a moving base is where that stops being
survivable.

## Combining the phases

Audited 2026-08-04 by merging all three branches into one tree and running the
suite: 148 tests, all passing. Two things that merge is worth knowing about.

`.github/workflows/nightly-build.yml` conflicts add/add. Phase 2 carries the
original, which builds and uploads an Actions artifact; phase 1 carries the
rewrite that publishes. Phase 1's supersedes it — take that side.

`packaging.bats` needed a fix for the two to coexist. It asserted the installer
name by grepping `make-installer.sh` for a source literal, so phase 1 renaming
the variable that builds the filename failed it even though a release build
still produces the identical name. It now evaluates the naming lines and
compares the result, which passes whether or not the label exists. That fix
lives on phase 2 and phase 3 has it merged.

Worth recording how it was found, because the first check of the same thing
missed it: an earlier verification merged the phase 1 branch's *committed*
state while the change under test was still uncommitted in a working tree, and
reported a pass on a tree that did not contain it.

## Phase 1 requirements

Everything needed for a user to download and run a nightly. Five items, all in
CI and packaging; no shipped script behaviour changes.

**Carry `nightly-build.yml` across.** It exists only on phase 2's branch. It is
self-contained — checkout, ccache, buildx, `build.sh`, `build-audit.sh`, upload
— and references nothing under `tests/`, so it moves on its own.

**Build the installer, not just the tarball.** The workflow stops at the runtime
tarball and never runs `make-installer.sh`, so there is no `.run` to publish.
Add it with `ENGINE=docker`: the script defaults to podman and CI has docker.
Its other inputs are already there — `dist/ableton-linkd` from `build.sh`,
`cabextract-static` built on demand from the same image, and the vendored
winetricks, fonts and Link source from the checkout.

**Separate the two identifiers in `make-installer.sh`.** This one is
scaffolding, not design — see *Retiring the label* below. It buys a working
nightly without any channel machinery, and phase 4 removes it.

**How it works today.** The tarball it packs
and the installer it names both come from `$(cat VERSION)`. A nightly must not
bump `VERSION`: it is committed, and `repo-hygiene` and `release.bats` assert
its format and its pairing with CHANGELOG and BUILD-INFO. The artifact needs a
label — `<version>+nightly.<sha>` — distinct from the version of the tarball
being packed.

**Publish to a rolling prerelease.** Delete and recreate a permanent `nightly`
tag each run, with `--prerelease`. `/releases/latest/` excludes prereleases, so
the stable installer URL is untouched and the nightly gets its own predictable
one at no cost.

**Skip an unchanged tree.** The rolling tag is the record: created with
`--target`, it points at the commit that was built, so the workflow compares it
with `GITHUB_SHA` and exits before spending forty minutes rebuilding the same
commit. That check runs as its own job with no checkout — deciding whether to
spend forty minutes should not first cost a 100MB clone of `vendor/` — and
reads both the tag and `VERSION` from the API.

`BUILD-INFO`'s `patch-head` looks like the obvious source for this and is not.
`container-build.sh` computes it inside `$WORK/wine-src` after applying the
series, so it is the HEAD of the patched Wine tree and resolves to no object in
this repository. An earlier draft of this note asserted it was
`git rev-parse HEAD`; that was read off the line without checking which
directory it runs in.

Provenance comes from the same tag, so it needs nothing extra either.

The gate is `build-audit.sh`, which already runs and verifies every patch is
present in the shipped binaries by fingerprint. That is the right check for a
runtime artifact — `ci-checks` guards scripts and repo hygiene, which is not
what a nightly tarball gets wrong. Gating on the audit alone is what keeps
phase 1 independent of phase 2.

## Phase 1 verification

Run on 2026-08-04 against `ClickSentinel/ableton-linux`, built from
`7193ece`. What the pipeline produced was installed on a real machine with a
licensed Live, not merely inspected.

The label reaches every place it has to: the installer's own header reports
`ableton-wine-setup-2026.08.04.1+nightly.7193ece`, the extracted kit's
`VERSION` carries the same string, and so does
`~/.local/share/ableton-wine/VERSION` after installing — so a nightly cannot
report itself as the release it was built from.

`/releases/latest/` returns 404 on a repository whose only release is the
nightly prerelease, which is the load-bearing fact behind two download URLs
coexisting: the stable link keeps resolving to the newest real release and
ignores this entirely. The `+` in asset names survives GitHub intact.

The runtime installed over an existing licensed prefix, updated it in place,
and Live launched still authorised. That is the claim the whole shared-prefix
scope rests on, and it is the only part of it that could not be established by
inspection.

Two things remain unexercised: the skip-if-unchanged path has never returned
false against a real published nightly, and nobody has yet installed the
release back over a nightly.

## Phase 1 limitations

Worth stating in the release notes rather than discovered by a tester.

Both channels track the same Wine base. Switching is by installing the other
`.run`, not a flag. There is one prefix, shared, so preferences and installed
packs are common to both. Rollback is the dated directory `install.sh` already
leaves behind, not an offline channel flip.

The base constraint is the one that expires: the moment a nightly is built from
a different Wine base than stable, switching back downgrades the prefix. That is
phase 4's problem, and `base-bump-11.14` is not currently queued — it sits two
commits off main with no open PR — so the constraint holds for now rather than
racing anything.

## Decisions

Three questions shaped the design; all are answered, and the sections below
carry the reasoning.

A second channel gets its own prefix, made by **copying** the authorised one
rather than creating it — a fresh prefix regenerates `MachineGuid` and would
demand re-authorisation. Verified end to end.

The second channel exists **so stable can slow down**. Eleven releases shipped
in the nineteen days to 2026-08-01, one every 1.7 days, because every fix has
to reach stable to reach anyone. An earlier draft read that number as evidence
against a second channel, inverting cause and effect.

A stable release may be either **promoted** from a soaked channel build or
rebuilt by hand, chosen per release and recorded in BUILD-INFO. Promotion ends
the repo's "CI never builds a release" invariant, so which path produced a
given release has to be answerable after the fact.

## Design reference

How the pieces actually work — prefix coupling and cloning, the container
layout, the migration decision table, the compatibility shim, channel
resolution and publishing, plus what was rejected and why — is in
[ABLETON-WINE-CHANNEL-DESIGN.md](ABLETON-WINE-CHANNEL-DESIGN.md). This file is
the plan and its state; that one is the reasoning behind it.
