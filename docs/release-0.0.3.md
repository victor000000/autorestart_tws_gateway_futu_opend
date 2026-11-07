# Release 0.0.3: preserve sessions and verify recording

## Baseline and scope

Reviewed 2026-11-07. Local HEAD was `2b76686`; there was no project version file,
local version tag, or next-release plan. Version 0.0.3 establishes the requested
initial version. This is a local candidate, not a published release.

The checkout already contained substantial uncommitted login, documentation,
credential, OBS, and isolated paper-Gateway work. That work was retained. The
active-chat inventory showed no other active implementation chat for this
checkout. No reset, cleanup, credential read, live launch, restart, order, or
remote publication was performed for this release.

## Design and critical review

1. **Preserve existing IBKR clients.** TWS previously called a Desktop shutdown
   helper, and Desktop called a TWS/Gateway shutdown helper before launching.
   This contradicted the start-only instruction. Replace those calls with a
   read-only conflict guard that throws before credentials or launch. Already
   running target clients retain their reuse behavior. Do not add an automatic
   force-stop fallback or grant shutdown permission through a workspace start.
2. **Include recording in maintenance.** Documentation and agent instructions
   promised recording, but the maintenance group dispatched only two API
   services. Add the existing OBS starter as its third worker. Aggregate wait
   now includes recording failure. API workers may succeed even if OBS fails;
   failure does not roll back or terminate services.
3. **Reject unverified OBS recording.** Missing logs previously returned success;
   an old start marker could remain marked recording after a failure, and an
   existing-process path accepted a start without an output file. Throw on an
   unavailable log, clear recording on failure, and require both a recording
   marker and output path with no recorded failure. A later start resets the
   failure state. Match the recording wait range to the public 1–3600-second
   timeout contract.
4. **Keep validation headless and reproducible.** The inherited PATHEXT can be
   `.CPL`, preventing native child-host invocation in wrapper fixtures. Add
   `.EXE` only within those fixtures and restore the inherited value afterward.
   Child PowerShell windows are explicitly hidden.

Rejected alternatives: closing clients to resolve conflicts; restarting OBS to
force recording; weakening readiness checks; using real broker accounts or UI
input to test the change; rewriting the existing dirty checkout.

## Implemented evidence and final review

- `VERSION` establishes 0.0.3; README and operations describe the new behavior.
- Conflict tests exercise empty and occupied session sets, assert preservation,
  and check that the guard precedes launch in each affected entry point.
- Group tests verify all three maintenance workers and aggregate waiting.
- Synthetic OBS tests cover missing logs, missing output, failure after start,
  recovery on a later start, and successful existing-session verification.
- Compatibility wrappers regenerated with `tools/Sync-EntryPoints.ps1`.
- Full `tools/Test-Project.ps1` passed under Windows PowerShell 5.1 and Windows
  PowerShell 7: 256 passed, zero failed/skipped on each host; both exited 0.
- Both hosts passed strict UTF-8 BOM/parser checks for 98 first-party files,
  compatibility-wrapper synchronization, and PSScriptAnalyzer.
- Synthetic reports: `test-results/pester-Desktop-5.xml` and
  `test-results/pester-Core-7.xml`. `git diff --check` passed.
- Final review confirmed the guard runs before either affected launch path and
  that failures do not invoke shutdown helpers. No live acceptance was attempted.

## Remaining limitations

- Offline tests do not establish current vendor authentication or UI compatibility.
- OBS evidence comes from logs, not an OBS WebSocket status query. Existing-process
  verification still selects the newest log; process-to-log identity and a
  recording that dies without a stop/failure marker remain limitations.
- IBKR conflict detection is a local snapshot, not a global launch mutex. A
  concurrent external launcher can race it. TWS and Gateway are still permitted
  to coexist; shared credentials can conflict upstream. The full group retains
  this existing behavior.
- Port readiness is not authentication, account entitlement, or trading clearance.
- No deployment or live operational acceptance is claimed.

## Commit boundary

The release commit isolates this task from earlier work. Its required supporting
code includes the existing OBS implementation/tests, application argument and
launch/reuse reporting, and read-only IBKR process discovery. Unrelated login,
credential, paper-Gateway, application selection, and documentation rewrites
remain uncommitted in the original checkout. In particular the committed US/full
group still uses Desktop; the reviewed working checkout uses TWS. Both can have
conflicting IBKR credentials, and conflict guards preserve existing clients.

The 256-test results above describe the combined working checkout. The isolated
staged snapshot passed `tools/Test-Project.ps1` on Windows PowerShell 5.1 and
PowerShell 7: **216 passed, zero failed/skipped on each host**, exit 0. Both
passed BOM/parser checks for 95 files, wrapper checks, and PSScriptAnalyzer.
The snapshot was exported from the Git index to an isolated Windows temporary
directory and used the pinned test modules from this checkout. No runtime or
credential directories were exported. The documentation was then updated with
these results; executable snapshot contents were unchanged.

## Publication candidate and full unit coverage

The verified owning repository is
`victor000000/autorestart_tws_gateway_futu_opend`, remote main baseline
`3b697f523df3ac1a87228db5f5dd2f7aa1b9c0b4`. It already contains the OBS,
login, and paper-Gateway prerequisites absent from the original local Git base.
The publication candidate therefore applies release deltas to that baseline,
retaining its established TWS group selection and other existing source.

Additional mocked starter regressions execute both starter bodies with imports
removed and all credential/process/shutdown boundaries faked. They verify
conflict guards prevent launch and credentials, and existing targets are reused
without inspecting or closing competing sessions. No production script imports
or real application launches are allowed in these fixtures.

The existing pinned Windows CI matrix installs its dependencies on a clean
checkout and runs the full offline suite on PowerShell 5.1 and 7. Added workflow
concurrency cancels superseded runs on the same ref. No credentials, live broker
calls, service restarts, or runtime artifacts are required by this matrix.

Publication candidate validation: full unit suite **260 passed, zero failed or
skipped** under each of Windows PowerShell 5.1 and PowerShell 7 (exit 0), including
the four new starter-preservation cases. Both hosts passed BOM/parser checks,
wrapper synchronization, and PSScriptAnalyzer. The candidate has no private
runtime dependencies; validation used the existing pinned modules explicitly via
`-ModulesPath`. A separate fresh PSGallery installation installed Pester 5.7.1;
the PSScriptAnalyzer download remained pending at validation time.

Publication blocker (2026-11-07): the release coordinator verified GitHub
connector writes fail with HTTP 403 `Resource not accessible by integration`,
noninteractive credential lookup supplies no credentials, and the existing
Windows/WSL SSH keys fail with `Permission denied (publickey)` using the existing
GitHub SSH route. No new keys or account-permission changes were attempted.
Consequently these candidate changes have no new hosted CI run or remote commit;
local unit success does not establish hosted success. The verified remote main
baseline remains `3b697f523df3ac1a87228db5f5dd2f7aa1b9c0b4`.

Final clean dependency check: the separate PSGallery bootstrap completed with
exit 0 and installed both pinned modules. The default `tools/Test-Project.ps1`
(no ModulesPath override) then passed on both Windows PowerShell 5.1 and 7:
260 passed, zero failed/skipped per host, exit 0; BOM/parser checks for 99 files,
wrapper synchronization and analyzer passed. Reports are under `test-results/`
in the persistent publication checkout
`C:/Users/victo/.codex/launcher-publication-0.0.3`. This resolves the earlier
pending download; write authentication remains the only publication blocker.
