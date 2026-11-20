# ci

The shared CI check for the NuclearNightmare-Community mod repos (Nuclear Nightmare mods: UE4SS Lua, PowerShell tooling). Each mod repo calls one reusable workflow from here, pinned to a commit of this repo; the workflow runs `check.ps1` on the mod.

Version 0.1.0.

## What runs

`check.ps1 -Repo <mod repo> [-Tag v<version>]` runs four steps. Every step runs even when an earlier one fails, and the summary lists every failure.

| Step | What it checks |
|---|---|
| `mod.json` | The release rules (`Test-ModJson` in `modid.ps1`): id through the id normalizer, `name`, `version` semver, `scope` (`client`, `host`, `host-plus`, `both`), `game {version, build}`, `ue4ss` = the pinned UE4SS build, optional `displayName`, `dependsOn` entries that normalize and never name a UE4SS built-in mod (`ue4ss-builtins.json`). On a tag push the tag must be `v<mod.json version>`. |
| `luacheck` | Every `*.lua` with `lint/.luacheckrc` (Lua 5.4, the UE4SS globals, test-file overrides). |
| `PSScriptAnalyzer` | Every `*.ps1`, `*.psm1` and `*.psd1` with `lint/PSScriptAnalyzerSettings.psd1`; any Error or Warning fails. |
| `tests` | The mod's own `test.ps1` (exit 0 passes), with the pinned Lua 5.4 first on `PATH`. |

Both linters skip the folders `build`, `.worktrees`, `unreal`, `native`, `ue4ss-src`, `ci` and `nucleus`. A finding that can't be fixed without changing behaviour gets an inline `-- luacheck: ignore <code>` or `[Diagnostics.CodeAnalysis.SuppressMessage(...)]` with a reason; global rule exclusions live only in `lint/`, each with a one-line reason.

The workflow sets `NN_CI=1`. A mod's unit tests that need the maintainer's workspace (the run-guard tests, custom-difficulty's VM runner test) print `SKIP (CI): <reason>` and pass only then. It also sets `NN_MODID_CASES` (the shared id cases in this repo) and, with `nucleus-ref`, `NN_NUCLEUS` (a Nucleus checkout for mods whose tests load core's Lua; the Mod Manager).

What CI doesn't run: game, VM or two-player runs, Nucleus's C++ build and Blueprint cook, `build.ps1`, `release.ps1`, signing. A tag push only checks tag = version; CI never builds or attaches release zips. The catalog's SHA-256 comes from the zip the maintainer's `release.ps1` builds, and a CI-built zip could differ (deflate output differs between .NET runtimes, and line endings follow `core.autocrlf`), so a second builder would make the verifier reject downloads.

## Files

| File | |
|---|---|
| `.github/workflows/mod.yml` | The reusable workflow (`workflow_call`; inputs `ci-ref`, required, and `nucleus-ref`, default `''`). Job id `check`, so the check is named `ci / check` in a caller whose job is `ci`. |
| `.github/workflows/self-test.yml` | Runs `tests/run-tests.ps1` on every push and pull request here. |
| `check.ps1` | The four steps. |
| `setup.ps1` | Downloads the tools pinned in `tools.json` into `.tools/`, verifies each SHA-256 before use, builds Lua 5.4.7 from source with MSVC (found with vswhere). `-Path` prints the tool folders. |
| `tools.json` | Lua 5.4.7 (lua.org), luacheck 1.2.0 (`luacheck.exe`, lunarmodules/luacheck releases), PSScriptAnalyzer 1.24.0 (PSGallery), actionlint 1.7.7 (rhysd/actionlint releases), each by exact version and SHA-256, with where the hash came from. |
| `lint/` | The shared luacheck and PSScriptAnalyzer settings. |
| `modid.ps1`, `modid-cases.json`, `ue4ss-builtins.json` | Generated copies of the maintainer's canonical id normalizer and `mod.json` rules, its shared id cases, and the UE4SS built-in mod names. Never edit them here: the maintainer's workspace writes them with `tools/ci/sync.ps1`, and its id tests fail when they drift. |
| `tests/run-tests.ps1` | The self-test: `check.ps1` against fixture repos (clean; each broken `mod.json` field; a failing test; Lua and PowerShell lint errors; tag match and mismatch), the workflows' SHA pins, the bad-pin step, actionlint, and lint of this repo's own scripts. |

## Local use

```powershell
./setup.ps1                              # once; needs Visual Studio with the C++ tools for Lua
./tests/run-tests.ps1                    # the self-test
$env:NN_CI = '1'                         # as CI does: workspace-only tests skip
./check.ps1 -Repo ../mods/waypoints
$env:NN_NUCLEUS = (Resolve-Path ../mods/Nucleus); ./check.ps1 -Repo ../mods/mod-manager
```

Without `NN_CI`, a mod's tests behave exactly as on the maintainer's machine.

## Calling it from a mod repo

`.github/workflows/ci.yml` in the mod repo (`tests/fixtures/caller/ci.yml` is the shape):

```yaml
name: ci
on:
  push:
    branches: ['**']
    tags: ['v*']
  pull_request:
permissions: {}
jobs:
  ci:
    permissions:
      contents: read
    uses: NuclearNightmare-Community/ci/.github/workflows/mod.yml@<ci commit> # v0.1.0
    with:
      ci-ref: <the same ci commit>
      # nucleus-ref: v0.15.0   # Mod Manager only: a Nucleus tag its tests pass with
```

Both values are the same full commit SHA; the workflow fails before it checks anything out if `ci-ref` isn't 40 hex digits. The maintainer's `tools/ci/pin.ps1` writes both in every mod repo.

## Setup (the maintainer, once)

Nothing here has been pushed. In this order:

1. Create the public repo `NuclearNightmare-Community/ci` (no template, no README) and push this repo's `main` to it, so the commit the mod repos pin exists on GitHub before anything calls it. Optionally tag that commit `v0.1.0` to match the `# v0.1.0` comments.
2. Create the mod repos that don't exist on GitHub yet (`NuclearNightmare-Community/<repo name>`; at present `imposter-panel-fix` and `random-mode`, the two without an `origin` remote; `nucleus`, `waypoints`, `hud-clock`, `custom-difficulty`, `whistle-mute` and `mod-manager` already exist), then push each mod repo's `main`. Push `nucleus` before `mod-manager`, and push Nucleus's tag named by the Mod Manager's `nucleus-ref`. Every push runs the check; confirm it passes.
3. In each mod repo, add a ruleset on `main` that requires the status check `ci / check` (and blocks force pushes and deletion).
4. In the organization's Actions settings, allow only actions from the organization plus `actions/checkout`, and require full-length commit SHAs for actions if offered.
5. After any change here: merge it to `main`, push, then run `tools/ci/pin.ps1` in the workspace and commit and push each mod repo's `ci.yml`.

## License

MIT (`LICENSE`).
