@echo off
:: jj takes priority in colocated repos; fall back to git branches.
jj root >nul 2>&1 && (jj bookmark list) || (git branch)
