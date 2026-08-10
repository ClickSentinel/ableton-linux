# Onboarding a second application: what the probe measured

Notepad++ 8.9.7 (NSIS, ~7 MB, app-only kit) installed beside Ableton Live on a machine running the Works layout, then listed, launched, and uninstalled. Everything the app needed is the mandatory core; everything it skipped without harm is the optional tier; everything it had to hand-roll is a gap in Works. Measurements from a real run, not design intent.

## The mandatory core — five items

| Item | What the probe did |
| --- | --- |
| identity | `~/works/apps/notepad-plus-plus/` with a launcher of the same name; the directory is the census entry |
| compat floor | `WORKS_ABI_MIN=1` in the launcher, sed-readable |
| infrastructure handshake | its installer ran `install-works.sh check --app-min 1`, then `install` after its own payload landed |
| a runtime | required one present and refused without it — an app-only kit ships none; the store deduplicates, so only runtime-bearing kits add builds |
| a Plug | created `npp`, booted it (`wineboot -u` writes the registry and the base stamp), installed into it silently |

## The optional tier — proven by omission

Prefix setup script, desktop entries and MIME, an update channel and `origin`, legacy-path migration, a process signature, tenant registration. The probe shipped none and nothing broke: `works plug setup` correctly reports the app ships no setup; the app is simply invisible where visibility is registration-derived (below).

## Verified live

- Install end-to-end headless over ssh: NSIS `/S` completes with no display; `nodrv_CreateWindow` noise is non-fatal.
- Two applications in the census; the ABI handshake from a second declaring kit.
- Uninstalling the second application leaves `works`, all store builds, the other application, and the app's own Plug intact — the multi-application uninstall census, first exercised outside fixtures here.
- GUI launch requires a display session; process-presence asserts fail over bare ssh. Same constraint as every GUI app; verify launches from the console.

## Gaps in Works, found by having to work around them

1. **Tenant discovery misses unregistered applications — measured, and the indexes are disjoint.** Notepad++ wrote `Uninstall` (`"Notepad++ (64-bit x64)"`) and three `App Paths` entries, and no `RegisteredApplications`. Live is the exact mirror: `RegisteredApplications` only, its `Uninstall` keys holding nothing but VC++ redistributables, WebView2 and Wine Mono. A registration-only census lists the npp Plug empty. The candidate fix is the union of both indexes; the open decision is filtering infrastructure entries (redistributables, Mono) out of `Uninstall` without hardcoding vendor patterns — the smell the registry read was chosen to avoid.
2. **The runtime requirement is hand-rolled.** An app-only kit needs "a runtime is present or refuse", and the probe wrote its own `[ -x bin/wine ]`. Wants a first-class predicate (`works_require_runtime`) with the refusal message owned by Works.
3. **The standard locator assumes depth one.** `dirname/../works` resolves from `scripts/`; app directories sit at `apps/<name>/` and need `../../works`. Either the locator grows the depth or the installed-library path becomes the documented contract for apps.
4. **Per-app default Plug has no seam.** The launcher exports `WORKS_PLUG` itself before binding. Works knows only the global `default` symlink; whether an app may declare "my Plug" (`apps/<name>/plug`?) is an open decision — the export works, but every app will repeat it.
5. **Hygiene census doesn't cover `apps/`.** `all_shell_files` globs `scripts/` and `works/`; probe files are shellchecked by hand. Onboarding must either add each app to the census or the census learns `apps/*/`.
6. Cosmetic: `works plug new` run from an installer prints its interactive hint ("Nothing is installed in it yet…") into install output.

## The shape that held

Bundle `works/`, declare a floor, hand the gate the decision, own your payload, get a Plug. Nothing in the shared layer needed to learn the application's name — the census, the gate, the store and the uninstall logic all worked from structure alone. The gaps above are all at the edges: visibility, convenience seams, and hygiene coverage.
