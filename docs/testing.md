# Testing and CI

[Documentation home](../README.md) · [Architecture](architecture.md)

## Run validation

From the repository root in Windows PowerShell 5.1:

```powershell
# Explicit dependency download; project-local, not global
.\tools\Install-TestDependencies.ps1

# Encoding, parser, generated wrappers, analyzer, and isolated tests
.\tools\Test-Project.ps1
```

Repeat validation under PowerShell 7 on Windows when available:

```powershell
pwsh -NoProfile -File .\tools\Test-Project.ps1
```

Success requires all enabled checks to pass and at least one Pester test to run. The command fails on missing tools, stale wrappers, parser/encoding errors, analyzer diagnostics, or failing tests. Synthetic reports are written to ignored `test-results/pester-Desktop-5.xml` and `test-results/pester-Core-7.xml` for the respective hosts.

For a preseeded dependency location, supply `-ModulesPath 'C:\path\to\Modules'` to both scripts. That directory must contain the pinned `<module>/<version>/<module>.psd1` layouts. For local static diagnosis only:

```powershell
.\tools\Test-Project.ps1 -SkipAnalyzer -SkipTests
.\tools\Sync-EntryPoints.ps1 -Check
```

The wrapper fixtures temporarily add `.EXE` to inherited `PATHEXT` and restore it, including WSL environments with `PATHEXT=.CPL`. Older revisions lacked this protection. For diagnosing those older revisions only, restore standard executable extensions within the validation process:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$env:PATHEXT = ".COM;.EXE;.BAT;.CMD;" + $env:PATHEXT; & ./tools/Test-Project.ps1'
```

Skipped checks do not establish full validation. No live trading application needs to be running for these checks.

## Supported validation hosts

- 64-bit Windows PowerShell 5.1 (production child-process host).
- PowerShell 7 on Windows (offline tests/static checks; full native application compatibility is not implied).

Install pinned Pester 5.7.1 and PSScriptAnalyzer 1.24.0 explicitly with `tools/Install-TestDependencies.ps1`. Modules are placed under ignored `.tools/Modules/`, not installed globally. A preseeded module directory can be supplied with `-ModulesPath` to the bootstrap and validation scripts. The validation runner never downloads dependencies and never silently uses Windows' bundled Pester 3.

Run `tools/Test-Project.ps1` from either shell. It checks strict UTF-8 with BOM, parses allowlisted first-party source/data, runs the selected analyzer policy, and runs only `tests/`. The runner never discovers scripts inside `logs/`, `secrets/`, `ibc/`, `ibc-source/`, or `.tools/`. `-SkipAnalyzer` and `-SkipTests` are diagnostic switches, not the CI acceptance command.

All PowerShell source/data files, including wrappers, use UTF-8 BOM. `.editorconfig` documents authoring defaults; `.gitattributes` preserves LF. Encoding checks operate on bytes because Chinese strings can be corrupted under 5.1 without causing a parser error.

## Isolation model

Unit tests use synthetic data, mocked process/CIM/network/credential boundaries, and disposable Pester TestDrive fixtures. A few CLI tests spawn a harmless PowerShell child against **sandbox copies** of wrappers and inert fixture scripts, never against live application implementations. Pure native/UI predicates are compiled or inspected without injecting input or enumerating the desktop.

File-writing fixtures pass explicit TestDrive-derived paths. Do not use production path variables as mutable test overrides: PowerShell scoping and case-insensitive variables can resolve a different binding. Mock credential providers before invoking configuration creation; never use the real DPAPI store, 1Password, broker ports, registry, task scheduler, or vendor-app directories as fixtures.

No `-TestOnly` vendor-login command is used as a substitute for isolated unit tests. UI tests verify conservative decisions and rejected input; they do not establish that the current vendor screens match stored fingerprints.

## Suites

- `Documentation.Tests.ps1`: synthetic Markdown links/anchors, command references and non-executing PowerShell example parsing.
- `Structure.Tests.ps1`: manifest completeness, mapping containment, entry-point layout.
- `Core.Tests.ps1`: credential field selection, serialization, failure propagation, private-file publication, numeric discovery, process ownership, logging destination.
- `Compatibility.Tests.ps1`: group membership, sequential US login dispatch, argument quoting, worker exit aggregation, sandbox wrapper contracts.
- `Readiness.Tests.ps1`: fully faked Gateway controller and explicit temporary launcher-log fixtures.
- `Operations.Tests.ps1`: exact stop targets, captured-instance protection, restart gating, tray cleanup, fake scheduler/registry administration.
- `Obs.Tests.ps1`: recording markers, failures/recovery, output paths, file sharing and launch/reuse.
- `PaperGateway.Tests.ps1`: isolated credentials/config/port ownership, mutex and prepare-only behavior.
- `SessionPreservation.Tests.ps1`: mocked starter bodies reject conflicts before credentials/launch and reuse existing targets.
- `UiSafety.Tests.ps1`: fingerprint arithmetic/classification, target-window and input guards, conservative login contracts.

Counts are reported by the runner; assertions are behavior-oriented and are not a claim of full code coverage. Add a regression test before fixing another reproducible bug. Do not increase a fingerprint threshold merely to make a failing login appear to work.

## CI

`.github/workflows/ci.yml` runs on `windows-2022` in separate `powershell` and `pwsh` jobs. Test-tool versions and action commits are pinned; token permissions are read-only and checkout credentials are not persisted. CI has a time limit and no brokerage credentials. Only synthetic NUnit test reports from `test-results/*.xml` are uploaded, with seven-day retention. Runtime logs, screenshots, binary dependencies, and secret material are never artifacts.

The workflow runs on pushes, pull requests, or manual dispatch after publication to GitHub. A local validation pass is not evidence of a hosted CI pass; check the repository Actions run for the commit being reviewed. Publishing or pushing is a separate action.

## Deployment boundary

Continuous deployment is not configured. This repository launches applications on a user-operated Windows desktop; CI does not deploy files, configure scheduled tasks or auto-logon, start services, or authenticate trading clients. Those remain explicit local operations after validation. A passing CI run establishes offline checks only, not vendor login compatibility, account access, live brokerage connectivity, or trading readiness.

## Validation incident during development

An initial launcher-log fixture relied on a script-scoped path override that did not resolve as intended under Pester. It overwrote the local Gateway `launcher.log` with synthetic lines before the boundary was corrected. The tests now pass an explicit fixture path and guard temporary destinations; the log reader also disposes early-return streams. No order, login, credential, scheduler, or application-stop operation was issued by that test. The original diagnostic-log contents could not be reconstructed; no restoration is claimed. This incident is why path isolation is tested explicitly instead of relying on naming conventions.

## Documentation validation

`tools/Test-Documentation.ps1` runs automatically from `tools/Test-Project.ps1` and can also run alone without downloading modules:

```powershell
.\tools\Test-Documentation.ps1
```

It checks inline relative Markdown links and heading anchors in root Markdown files and `docs/**/*.md`, and checks inline root-command and tool references exist. It never follows external URLs or opens credential/runtime files. Fenced code is excluded from link extraction; PowerShell examples are parser-reviewed or manually compared with parameter ASTs, never executed to prove a launch. Reference-style links, HTML anchors, network URLs and prose truth are outside this small checker; review them explicitly if introduced. Historical release records are checked for link integrity but their dated claims are not rewritten as current facts.

Doc checks cannot establish current brokerage authentication, settings, CI availability, or account access. `-SkipTests` still runs encoding/parser, wrapper and documentation checks, but does not constitute full validation. Full CI acceptance remains the default runner on both Windows hosts at the exact published source tree.
