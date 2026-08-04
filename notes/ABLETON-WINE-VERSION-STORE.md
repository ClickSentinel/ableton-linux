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

The store grows by roughly 2GB per retained build. Development machines already
hold eight rollbacks; on a disk at 92% that is not academic.

Policy: never remove a version any channel symlink points at. Beyond that keep
the most recent `ABLETON_KEEP_VERSIONS` (default 2) and prune oldest first,
after a successful install rather than before, so a failed install cannot leave
a user with neither the new runtime nor the old one.

## Rejected approaches

**Naming entries by `dist-version` alone.** Collides a nightly with the release
it was built after, and the collision is silent — the wrong runtime under the
right name.

**Keeping timestamped rollbacks alongside the store.** Two mechanisms for the
same thing, and the timestamps are the half nobody can read.

**Pruning by count without regard to channels.** A channel pointing at a pruned
version is a broken install produced by a housekeeping rule.

## Limits

Nothing here is implemented. The interim container layout is, and is migrated
on one machine, so this carries a second migration for that machine
specifically — cheap now, and the reason to decide quickly rather than after
the layout reaches users.

Disk pressure is stated from one machine. The 2GB-per-build figure is the
unpacked runtime; the prune default of 2 is a guess, not a measurement.
