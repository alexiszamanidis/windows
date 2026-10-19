# Repository Guidelines

## Work safely and efficiently

-   Keep changes in the repository by default. Do not edit installed files under `%USERPROFILE%\.glzr`, change Windows settings or the registry, install software, start or stop apps, reload GlazeWM/Zebar, or request elevation unless the user explicitly asks for changes on the machine.
-   A request to apply a specific config change to Windows authorizes only that change. Inspect the relevant installer functions first; do not run the general installer or a broader task if it would make unrelated changes, elevate, open windows, or restart other apps.
-   Before editing, check `git status --short` and read only the files related to the request. Preserve staged, unstaged, and untracked user changes; do not reset, check out, or reformat unrelated files.
-   Prefer a narrow search and targeted test over reading or validating the whole repository. Do not install missing tools or dependencies just to run a check; report what could not be run.
-   Before any requested machine change that may close or move user windows, restart Explorer, interrupt an app, or require elevation, explain the specific impact and ask before proceeding.

## Repository map

-   `install.ps1`: entry point; selects installer tasks and handles elevation.
-   `tasks/*.ps1`: Windows configuration and installation operations. Read the specific task and called functions before invoking anything.
-   `config/`: source files deployed to Windows. Make repository changes here, not in deployed copies, unless the user explicitly requests a live-only change.
-   `tests/install.Tests.ps1`: Pester tests for installer behavior and config expectations.
-   `.github/workflows/validate.yml`: CI PowerShell parsing, PSScriptAnalyzer, Pester, and installer behavior checks.
-   `.github/workflows/format.yml`: reusable Prettier formatting workflow.
-   `README.md`: installation, task selection, and project overview.

## Validation

-   When changing a config, installer behavior, or its tests, search for all related assertions in both `tests/` and `.github/workflows/`. Update stale expectations when behavior intentionally changes, but retain separate checks for still-required behavior (for example, deploying a helper file does not require referencing it from the config).
-   For a CI failure, inspect the failing workflow step and assertion, reproduce that exact condition against the checked-in source, and fix the underlying mismatch. Validate the intended new behavior and nearby regression cases before finishing; do not stop after changing the first failing assertion.
-   For PowerShell or installer changes, run the narrowest relevant Pester test when Pester 5+ is already available:
    `Invoke-Pester -Path ./tests/install.Tests.ps1 -Output Detailed`
-   For PowerShell-only syntax changes, the PowerShell parser can check just the edited script. CI additionally runs PSScriptAnalyzer and installer behavior checks.
-   For formatting, run Prettier only on the changed supported files (for example, `npx prettier --check <files>` or `npx prettier --write <files>` when dependencies are already installed), then inspect the diff. Do not use `npm run format` for a targeted change: it writes across the repository. `.prettierignore` excludes YAML, so Prettier does not validate GlazeWM or workflow YAML; check those changes separately.
-   For HTML or JavaScript changes, validate the edited file with an available targeted check.
-   Do not claim tests passed if a tool is missing or a check was skipped; report the limitation concisely. CI may install Pester and PSScriptAnalyzer, but local tasks should not install them without the user's request.

## Windows configuration cautions

-   Treat the checked-in files under `config/` as the source of truth. `tasks/GlazeWm.ps1` contains both narrow deployment/reload functions and a broader `Set-GlazeWm` workflow; understand its side effects before using it.
-   Keep GlazeWM, Zebar, and the native Windows taskbar distinct when diagnosing visibility or click behavior. A GlazeWM setting or Zebar bar setting does not by itself prove the Windows taskbar is visible. Verify the exact surface and behavior the user reported.
-   Do not use elevation or process termination as a shortcut around access errors. Identify the process, owner, and expected effects first; use the normal scoped installer only when its complete behavior matches the request.
-   After an explicitly requested live change, verify the deployed file matches the intended source and check the relevant running behavior. Avoid leaving temporary consoles or other windows open, changing workspace placement, or disturbing the user's focus.
