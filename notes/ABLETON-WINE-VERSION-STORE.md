# Runtimes as a version store

Supersedes the channel-as-directory layout: channels become symlinks into a
store of runtimes named by the ableton-linux version that produced them, not by
the Wine version they contain and not by the timestamp they were replaced at.

```text
~/.local/opt/ableton-wine/
├── versions/
│   ├── 2026.08.04.1+7193ece/
│   ├── 2026.07.29.1+a6e1135/
│   └── 2026.08.05.1+78f195b/
├── stable -> versions/2026.08.04.1+7193ece
└── beta   -> versions/2026.08.05.1+78f195b
```

Two things fall out that were previously separate work. Rollback stops being a
timestamp nobody can interpret — eight `stable-rollback-20260804T130806Z`
directories on the development machine, none of which say what they hold —
and becomes a version you can name. And switching channel becomes retargeting a
symlink: instant, offline, no download, which fetch-on-update could not offer.

## Naming

A store entry is `<dist-version>+<short-source-commit>`, both read from the
runtime's own `ABLETON-WINE-BUILD-INFO.txt`.

The commit is not decoration. `dist-version` is `cat VERSION` at build time, so
a release and every nightly built after it until the next release all carry
`2026.08.04.1`. Naming by version alone would let a nightly silently overwrite
the release's store entry — the same collision already fixed for the published
tarball, one level down. Two builds from the same commit are the same software
and correctly collide.

The store is machine-facing. Users interact with `stable` and `beta`, which is
where the friendly name lives.

## Resolution

`ableton_wine_root` returns `<container>/<channel>` and resolves through it.

That is the opposite of the rule for the legacy compatibility symlink, and the
distinction is deliberate: the channel link is **load-bearing by design** — it
is how a channel is selected, and retargeting it is how switching works. The
legacy link is **vestigial by design**, kept only for references outside our
control, and resolving through it would make it undroppable.

## Migration

The decision table grows one row, because the interim layout shipped to at
least one machine: `<container>/stable` may already exist as a real directory
and must be moved into the store and replaced with a link.

| From | Action |
| --- | --- |
| flat `wine-d2d1-nspa-11.13/` | into `versions/<id>`, link `stable` at it |
| `<container>/stable/` a real directory | into `versions/<id>`, replace with a link |
| `<container>/stable` already a link | steady state |
| both a real `stable/` and a `versions/<id>` | refuse — cannot tell which is live |

Dated rollbacks migrate too, and improve in the process: each carries its own
BUILD-INFO, so `stable-rollback-<stamp>` becomes `versions/<id>` under its real
identity. Duplicates — the same build installed twice — collapse to one entry,
because identical ids mean identical bits.

A rollback whose identity cannot be read does not enter the store either, and
this is not hypothetical: the 1.2G outlier on the development machine turned
out to be a debug tree — `bin/` and `lib/`, an `ABLETON-WINE-DEBUG-INFO.txt`
and no `share/` — left behind when the `sort -V` tarball selection installed
one and the next install rolled it back. It carries no `dist-version` at all,
so there is no name to key it by.

Refusing the whole migration over it would be wrong: it is debris in the
history, not the live runtime, and anyone who ever hit that bug would be
blocked. Unreadable rollbacks move aside exactly as `.failed-*` does. The live
tree is different — if *that* cannot be named the migration must still refuse,
because installing over an unidentifiable runtime is the ambiguous case.

`.failed-*` directories do not enter the store. They are debris from an
interrupted install and their contents are not a trustworthy runtime; they move
to `<container>/failed-<stamp>` so uninstall still finds them and nothing is
deleted behind the user's back.

## Requirements

`ABLETON-WINE-BUILD-INFO.txt` must record the source commit. It does not today:
`patch-head` is the HEAD of the patched Wine tree inside the container and
resolves to no object in this repository, and nothing else names a commit. This
blocks the store, because a store entry cannot be named without it.

`container-build.sh` runs with the checkout mounted, so `git -C "$SRC"
rev-parse HEAD` is the source. `build.sh:35` mounts the whole checkout at
`/src:ro`, so `.git` is reachable, and `rev-parse` does not write. It needs
`safe.directory` for that path, which the script already does for the Wine
tree, and that config goes to the container's own HOME rather than the
read-only mount.

Migration must refuse rather than guess when a tree's BUILD-INFO is missing or
unparseable. An unnamed runtime cannot go into a store keyed by name, and
picking a placeholder would produce exactly the ambiguity the decision table
exists to prevent.

## Pruning

Open. The shape of the policy is settled; the numbers are not, and the numbers
are what decides whether a policy is needed at all.

Measured 2026-08-04 on the development machine: an unpacked runtime is **392M**,
not the ~2GB an earlier draft of this note asserted. Nine entries — one live and
eight rollbacks — came to 4.2G, and one of those rollbacks was 1.2G rather than
392M, so sizes are not uniform and the outlier has not been identified.

At 392M a version is cheap enough that keeping several is unremarkable, which
weakens the case for pruning automatically at all. What survives regardless:
never remove a version a channel symlink points at, and prune after a
successful install rather than before, so a failure cannot leave a user with
neither the new runtime nor the old one.

What is undecided: whether pruning is automatic or a command a user runs, how
many to keep, and whether the count is per channel or across the store. Also
worth knowing what the 1.2G entry is before setting any limit — an outlier that
large suggests the store may hold things other than plain runtimes.

## Rejected approaches

**Naming entries by `dist-version` alone.** Collides a nightly with the release
it was built after, and the collision is silent — the wrong runtime under the
right name.

**Keeping timestamped rollbacks alongside the store.** Two mechanisms for the
same thing, and the timestamps are the half nobody can read.

**Pruning by count without regard to channels.** A channel pointing at a pruned
version is a broken install produced by a housekeeping rule.

## Limits

Not to ship before the release procedure is in order — that sequencing is
deliberate and comes ahead of this work regardless of readiness.

Nothing here is implemented. The interim container layout is, and is migrated
on one machine, so this carries a second migration for that machine
specifically — cheap now, and the reason to decide quickly rather than after
the layout reaches users.

Disk figures are from one machine and one filesystem. The 392M is measured; the
1.2G outlier is not explained.
