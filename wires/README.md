# Wires

The shared runtime infrastructure: the store of Wine builds, the Plugs applications are installed into, and the `wires` command that acts on both. Nothing here belongs to an application — an application's installer calls into it, then installs its own payload.

Developer documentation. The design lives here so the source can stay mechanism-only: a comment states what a line does and what breaks if it changes, everything else is on this page.

## Files

| file | purpose |
| --- | --- |
| `runtime-env.sh` | the shared library. Sourced, never executed |
| `wires` | the dispatcher — the one command a person runs |
| `wires-runtime`, `wires-plug`, `wires-app`, `wires-update` | the verbs. They implement the command; they are not commands themselves |
| `install-wires.sh` | installs the above onto a machine, and arbitrates when two kits disagree |

## Library

- Every answer in it was written several times over first: the tarball selector in `install.sh`, `make-installer.sh` and `build-audit.sh`, with the same defect in all three; the prefix default twice in `install.sh` and again in the launcher; the process scan inline in `install.sh`, where nothing else could reach it.
- Copies of a path do not stay in agreement, and divergence is not cosmetic: the process scan and the directory an installer is about to replace must name the same tree, or a runtime is replaced under running processes.
- The resolvers print an answer and change nothing. A caller uses only the functions it needs, and each is testable without a sandbox.
- Binding the current shell to a runtime is opt-in. Only the launchers need it.

```sh
. "$here/runtime-env.sh"
WINE_ROOT="$(wires_runtime_path)"   # just the path
wires_bind_runtime                  # the full launcher binding
```

## Vocabulary

Four things, and the words are not interchangeable.

- **runtime** — one patched Wine build. Many per machine, in the store at `~/wires/runtimes/<id>/`, selected by a channel. What `wires runtime list` lists.
- **Plug** — a Wine prefix, at `~/wires/plugs/<name>/`. Applications install into the selected one; a Plug can hold several.
- **kit** — the shipment: one `.run` carrying a runtime, the scripts and this library. Its version is `$kit/VERSION`.
- **store** — the directory holding runtimes, plus the channel symlinks pointing into it.

## Versioning

- One package, one version. The runtime, the verbs and the library are built and shipped together, so they share the kit's version. Nothing here carries a number of its own.
- `install-wires.sh` reads `$kit/VERSION`, records it at `~/wires/lib/VERSION` on install, and compares the two next time with `wires_version_newer`.
- Nothing is bumped by hand.
- The recorded version follows the newest kit installed, not the selected runtime. The store keeps many runtimes and a channel can point back at an older one; there is one library and it does not roll back with it.

## ABI range

The compatibility contract, and the one number here not derived from a build.

- `WIRES_ABI` — the library's current interface generation.
- `WIRES_ABI_OLDEST` — the oldest generation still supported.
- `WIRES_ABI_MIN` — declared by each application's launcher, the generation it was written against.

```text
compatible  <=>  WIRES_ABI_OLDEST <= WIRES_ABI_MIN <= WIRES_ABI
```

- Applications are forward compatible, the infrastructure backward: an application built against `MIN` keeps working until `OLDEST` rises past it.
- Raising `OLDEST` is the only way to drop one.
- A single integer cannot express this once release cadences differ — libtool's current/age idea, for the same reason.
- `WIRES_ABI` moves when the surface changes, never for a release. The kit version is a date, and dates would raise every application's floor for nothing.
- **`OLDEST` stays 1.** Stranding an application is a breaking release, taken deliberately or not at all. `install-wires.sh` lists the installed applications that would stop launching before it happens.

## Arbitration between kits

- Every kit carries its own copy of this infrastructure — one self-sufficient installer is the distribution model — so every install is also a write onto a machine other applications may depend on.
- Unguarded, whichever kit ran last would own `~/wires/lib`.

| situation | outcome |
| --- | --- |
| kit newer, nobody stranded | install it, silently |
| kit newer, would strand an application | ask, naming them |
| kit older | keep what is installed; exit 3, the application installs alone |
| kit older and its application below `OLDEST` | refuse; exit 1 |

- "Newer" is two questions. The ABI range answers whether an application can consume the installed interface; the kit version answers which library is more recent.
- The ABI alone leaves equal-ABI installs last-writer-wins, since two kits at ABI 1 carry different libraries.
- Two entry points, because the decision and the write belong at different moments: `check` runs before anything is stopped or moved, so a refusal leaves the machine untouched; `install` runs after the runtime is in place.
- `install` re-derives the answer rather than trusting state passed between the calls.

## Exit codes

Shared across every verb and `install-wires.sh`, because a caller cannot separate a refusal from a cancellation by reading the message.

| code | meaning |
| --- | --- |
| 0 | clean exit, or something optional was declined, which is not a failure |
| 1 | refused, or failed. The machine is not in the state that was asked for |
| 2 | usage: an unknown option or command, two names where one goes. Nothing was attempted |
| 3 | `install-wires.sh` only: the installed infrastructure is newer and was kept |

Declining something the caller cannot proceed without is a refusal, not a cancellation: the ABI-break prompt exits 1 on no, because its caller must stop.

## Moving a Plug between runtimes

`wires_base_move` reports where running a given runtime against a given Plug would take the prefix.

| answer | meaning |
| --- | --- |
| `fresh` | never booted; anything may bootstrap it |
| `same` | the build that booted it; Wine will not re-run wineboot |
| `refresh` | a newer build of the same Wine base — the ordinary update |
| `rollback` | an older build of the same base, which the store exists to allow |
| `forward` | a newer base, or one that cannot be identified: not reversible |
| `backward` | an older base, or unidentifiable: Wine does not support it |

- The stamp alone does not distinguish these. `wine.inf`'s mtime is set at build time, so two builds of the same base carry different stamps.
- By stamp alone, every routine update would read as a base change, and a rollback to yesterday's nightly would read as unsupported and be refused.
- So the stamp gives the **direction**; the **severity** comes from comparing the candidate's `wine:` label against that of the runtime which booted the Plug, recovered by `wires_plug_base_runtime`.
- If that runtime has been pruned, or either label is unreadable, the move stays `forward`/`backward`. An unanswerable question is a refusal, not a skip.

## Traps

- **A tab is IFS whitespace.** `IFS=$'\t' read -r a b` collapses runs of tabs, so an empty field is dropped and every field after it shifts left. Records use `WIRES_FS` (US, `\037`).
- **`local X` with no value is unset under `set -u`**, not empty. A trap that reads one fails inside the rollback it was meant to perform.
- **`install-wires.sh` runs under `set -e`; the verbs do not.** A bare call whose non-zero return is meant to be read from `$?` ends the script before `$?` is read.
- **`.update-timestamp` holds an epoch second as its contents**, not as its own mtime. A `touch -r` fixture sets the wrong thing.
- **`sed 1a` appends nothing to an empty file.** Use `printf`.

## De-Ableton inventory

`wires/` is the future standalone repository. The exit test is `grep -ci ableton` over it reaching zero, counting code rather than this list.

Each entry leaves by a migration or an expiry, never a plain edit.

| what | exit |
| --- | --- |
| `wires_legacy_root` / `wires_legacy_plug` | frozen history; leaves when migration is install-time only |
| `ABLETON-WINE-BUILD-INFO.txt` | artifact format; compat-window rename |
| the fenced rename-compat block | deleted whole, on schedule |
| `wires_manifest_url`'s URLs | per-application `origin`, once the updater takes an application argument |
| `ableton_live_pids` / `"Ableton Live"` | the application declares its process signature, or it derives from the Plug's `RegisteredApplications` name |

New mentions outside this list are regressions.
