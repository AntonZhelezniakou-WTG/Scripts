# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Personal Git/worktree/build helper scripts (PowerShell 7 + `.cmd` shims) for a Windows + Windows Terminal environment, wrapping `git`, `gh`, `fzf`, and MSBuild. Keep changes minimal, focused, and consistent with the conventions below.

A detailed conventions reference already exists at `.github/copilot-instructions.md` — read it; the points below are the load-bearing parts plus things only visible across multiple files.

## Architecture

- **`.cmd` shim + `.ps1` implementation pairs.** Each command (`repo`, `branches`, `commit`, `push`, `pull`, `pump`, `stash`, `build`, `clone`, `create`, `delete`, `drop`, `fetch`, `get`, `purge`, `changes`, `conflicts`) is a `*.cmd` wrapper that forwards to the matching `*.ps1` via `pwsh -NoProfile -ExecutionPolicy Bypass -File`. Shims are minimal; some add a `git rev-parse --is-inside-work-tree` guard and pass `%CD%`/`%~1` as the first args (most `.ps1` take `-WorkDir` first).
- **`Common/common.ps1` is the single dot-source entry point.** It sources `Git.ps1`, `Stash.ps1`, `FzfTree.ps1`, `copy-wt-extras.ps1`. Every `.ps1` begins with `param(...)`, then `$ErrorActionPreference = "Stop"`, then `. (Join-Path $PSScriptRoot "Common\common.ps1")`. Never dot-source files in `Common/` individually — always go through `common.ps1`. `repo.completion.ps1` provides shell argument completion (not auto-sourced).
- **`Configuration/` holds JSON config and generated caches.** `Paths.json` (clone/worktree base dirs, `defaultOwner`, `ownerAliases`, `worktreeAliases`), `Repositories.json`, `Build.json` (per-repo MSBuild targets + recent list). `RecentRepos.json` and `RepoCache.json` are generated (recent picks, cached `gh repo list`) — treat as data, not source; `RepoCache.json` has no auto-expiry (refresh with `-ForceRefresh`).

## Critical patterns (follow these exactly)

- **ErrorActionPreference toggling** is pervasive and load-bearing: with `Stop` as the default, any `git`/`gh` call whose non-zero exit is a *control-flow signal* (probing for a branch, PR, remote ref) must be wrapped `$ErrorActionPreference = "Continue"` … run … check `$LASTEXITCODE` … `$ErrorActionPreference = "Stop"`. Do this for every external command whose failure you expect.
- **Path resolution goes through helpers, never hard-coded.** Use `Get-PathsConfig`, `Get-RepoRoot` (preserves symlinks — do *not* use `git rev-parse --show-toplevel` for the working root), `Get-WtPath`/`Get-ExistingWtPath` (worktree paths), `Get-MainWorktreePath`. Worktrees live under `worktreeBase` as `{base}\{repo}\{branch}`; `worktreeAliases` can override the folder and enable short (≤30-char) names.
- **`main`/`master` are a pair** — always check both: `$branch -in @('main','master')`. Protected from deletion; PR creation and base-branch logic special-case them.
- **Windows Terminal integration** is gated on `$env:WT_SESSION`. When set, results open in a new tab via `wt --window 0 new-tab --title <t> --startingDirectory <d> pwsh -NoLogo [-NoExit -File <tempscript>]`; otherwise the script prints a `cd` hint. Worktree creation writes a temp `pwsh` script to `$env:TEMP` and runs it in the new tab. Preserve both branches in any UX change.
- **Shared interaction helpers** (in `common.ps1`) — reuse, don't reinvent: `Confirm-Action` (Y/n, default Y), `Wait-AnyKey`, `Ensure-Fzf` (offers winget install), `Invoke-Fzf` / the inline fzf style `--style=minimal --no-info --layout=reverse --pointer=">" --gutter=" " --color="pointer:green,fg+:green:bold,bg+:-1"`, `Invoke-PrCreate` (post-push PR offer, skips main/master & existing PRs).
- **Credentials:** `.gituser` files in repo ancestors are applied via `Apply-GitUser`, which routes github.com auth through `!gh auth git-credential` when `[github] user` is set. Don't bypass it in new clone/init flows.

## Style

- **Tabs, not spaces**, for indentation in `.ps1` files. Functions `PascalCase`, script-locals `camelCase`. Prefer returning objects; use `Write-Host` only for colored user-facing status.

## Running / testing

- Commands run by name from any cwd (the repo is on `PATH`); the `.cmd` is the entry point. Most `.ps1` accept a leading `-WorkDir` to target a specific repo.
- **No build, lint, test suite, or CI.** Verify a change by invoking the affected `.cmd` against a real repo (or a scratch clone via `-WorkDir`). `build.ps1` shells out to a hard-coded MSBuild path and reads targets from `Configuration/Build.json`.
- External deps: `git`, `gh`, `fzf`, `pwsh` 7+, Windows Terminal (optional), MSBuild (only for `build`), GitExtensions (optional, for merge-conflict UI).
