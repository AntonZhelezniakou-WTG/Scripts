# Copilot Instructions

Personal collection of PowerShell git/build workflow scripts for a Windows + Windows Terminal (`wt`) environment, wrapping `git`, `gh`, `fzf`, and MSBuild. Each top-level command is a pair: a `.cmd` shim that invokes the matching `.ps1` via `pwsh`.

## Layout

- Top-level `*.ps1` / `*.cmd` — user-facing commands (`repo`, `branches`, `commit`, `push`, `pull`, `pump`, `stash`, `build`, `clone`, `create`, `delete`, `drop`, `fetch`, `get`, `purge`, `changes`, `conflicts`).
- `Common/` — dot-sourced libraries. `common.ps1` is the single entry point; it sources `Git.ps1`, `Stash.ps1`, `FzfTree.ps1`, `copy-wt-extras.ps1`. `repo.completion.ps1` provides argument completion.
- `Configuration/` — JSON config: `Paths.json` (base dirs, `ownerAliases`, `worktreeAliases`), `Build.json` (per-repo MSBuild targets + recent list), `RecentRepos.json`, `RepoCache.json` (cached `gh repo list` output).

## Conventions

- **Every `.ps1` starts with**: `param(...)`, then `$ErrorActionPreference = "Stop"`, then `. (Join-Path $PSScriptRoot "Common\common.ps1")`. Do not source individual files in `Common/` — always go through `common.ps1`.
- **`.cmd` wrappers** are one-liners: `pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0<name>.ps1" %*` plus `exit /b %ERRORLEVEL%`. Keep them minimal.
- **Tabs, not spaces**, for indentation in `.ps1` files.
- **Toggling ErrorActionPreference**: when calling `git`/`gh` whose non-zero exit is expected (probing for branches, PRs, repos), wrap with `$ErrorActionPreference = "Continue"` … check `$LASTEXITCODE` … `$ErrorActionPreference = "Stop"`. This pattern is pervasive — follow it for any external command whose failure is a control-flow signal.
- **Interactive prompts**: use `Confirm-Action` (Y/n, default Y) and `Wait-AnyKey` from `common.ps1`. Don't roll new prompt helpers.
- **fzf invocations** share a house style: `--style=minimal --height=50% --no-info --layout=reverse --pointer=">" --gutter=" " --color="pointer:green,fg+:green:bold,bg+:-1"`. Reuse it for any new picker.
- **Windows Terminal integration**: when `$env:WT_SESSION` is set, scripts open results in a new tab via `wt --window 0 new-tab --title <t> --startingDirectory <d> pwsh -NoLogo` (or `pwsh -NoLogo -NoExit -Command/-File ...` to keep the tab open after running). Preserve this branch in any UX changes.
- **Path handling**: paths come from `Get-PathsConfig` (reads `Configuration/Paths.json`); never hard-code `D:\GitHub`-style paths. Use `Get-RepoRoot` (not `git rev-parse --show-toplevel`) so symlinks are preserved. Use `Get-WtPath` / `Get-ExistingWtPath` for worktree resolution.
- **Repo context**: `Get-RepoContext` resolves the current GitHub owner from cwd via `ownerAliases` (longest-prefix match) with `defaultOwner` fallback. New owner-scoped logic should go through it rather than parsing paths inline.
- **Recent lists**: use `Get-RecentRepos` / `Save-RecentRepo` (capped at 10) keyed by context string.
- **Branch helpers**: prefer `Get-LocalBranches`, `Get-WorktreeBranches`, `Get-BaseBranch` from `Common/Git.ps1` over re-parsing `git branch`.
- **Credentials**: `.gituser` files in repo ancestors are applied via `Apply-GitUser`, which ensures `gh auth git-credential` is used for GitHub auth (locally or inherited from global config) when a `[github] user` is set. Don't bypass this when adding clone/init flows.
- **PR creation**: after a successful push, call `Invoke-PrCreate` (skips `main`/`master`, no-ops if a PR exists, otherwise offers `gh pr create --fill`).
- **Master/main branches** are treated as a pair — when special-casing, always check both (`$branch -in @('main','master')`).

## Running

- Invoke commands from any cwd via the `.cmd` shims (e.g. `repo cw`, `branches`, `commit`). Most scripts accept an optional `-WorkDir` to operate on a specific repo path.
- `build.ps1` requires MSBuild at `C:\Program Files\Microsoft Visual Studio\18\Professional\MSBuild\Current\Bin\amd64\MSBuild.exe` and reads target lists from `Configuration/Build.json`. Pass `multiple` for multi-select, `--no-cache` to bypass the recent list.
- No test suite, no linter, no CI. Manual verification is the workflow: run the affected `.cmd` against a real repo (or pass `-WorkDir` to a scratch clone).

## External dependencies

`git`, `gh` (GitHub CLI), `fzf`, `pwsh` (PowerShell 7+), Windows Terminal (optional, gated on `$env:WT_SESSION`), MSBuild/devenv (only for `build.ps1`).
