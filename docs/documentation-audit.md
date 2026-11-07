# Documentation audit — 2026-11-07

## Scope and disposition

Documentation revision for source version 0.0.3, based on published
`ff868fb49587e17f6d73992c3418244a4fdbe9bb`. This is a documentation/validation
change, not a new runtime release. The original native checkout retains unrelated dirty source changes; the publication checkout is the canonical release source. The initial audit left native guides unchanged; the follow-up below reconciles them as well.

The initial inventory is seven Markdown files plus one tracked credential
README. Native and publication counterparts were compared: all seven Markdown
files matched except native `docs/testing.md`, which lacked the publication's
explicit deployment-boundary section. That section is retained. No native-only
runtime implementation or untracked diagnostic document was promoted.

| Owned document | Review and disposition |
| --- | --- |
| [README](../README.md) | Entry workflow, group composition, version and guide navigation reconciled with source. |
| [Setup](setup.md) | Correct paper support, client-preservation rules, credential failure behavior and configuration ownership. |
| [Operations](operations.md) | Remove obsolete implicit stops, distinguish group contention from sequencing, qualify machine-specific supervisor history, add recovery and public utility boundaries. |
| [Architecture](architecture.md) | Document dispatch/wait design, state provenance, credential flow and source-migration contracts. |
| [Testing](testing.md) | Inventory all nine runtime suites plus the new documentation suite, current PATHEXT fixture behavior, offline doc checks, CI/deployment limits and retained incident record. |
| [Release record](release-0.0.3.md) | Dated historical evidence retained unchanged. Later publication supersedes its temporary auth blocker: final main was `ff868fb`, exact tested tree `536858fb4b6670dd89922c0593aae8ea158e926d`, [CI 42367678834](https://github.com/victor000000/autorestart_tws_gateway_futu_opend/actions/runs/42367678834) succeeded on both hosts. |
| [Agent defaults](../AGENTS.md) | Reviewed and retained; operational instructions still apply. |
| `secrets/README.txt` | Retained as the tracked credential-storage note; no private credentials/config/logs were opened or copied. Current credential contracts are reviewed in setup/operations and source, not inferred from private state. |

The audit itself is the eighth Markdown document. Ignored runtime/vendor trees,
logs, screenshots and private scratch scripts are not maintained public guides.
No document in them is claimed audited or suitable for publication.

## Checks and remaining limits

Source review covered app/group/login tables, all public entry-point mappings,
launch/reuse and timeout behavior, IBKR conflict guards, paper config generation,
OBS evidence, explicit stops, task setup, credential handling and CI. Commands
that change registry/tasks, open UI, submit credentials, or start clients were
reviewed as source rather than executed. Install defaults and parameter names
were compared to definitions. Internal helpers and log lines are not a stable
external API. No live account, authentication, entitlement or video integrity
claim follows from documentation or offline validation.

The offline documentation checker scans root Markdown and docs recursively,
checks inline relative links/heading anchors and simple command references,
and parses PowerShell code fences without executing them. It excludes external
URL reachability, reference links, HTML anchors, protected file contents and
runtime behavior. These remain manual review boundaries, not hidden coverage.

Full validation results and publication manifest are supplied with the docs
commit handoff. Hosted acceptance requires the exact final published tree and
terminal CI; the earlier release CI above is historical evidence only.

Self-review correction: the wrappers have generated syntax but no full comment
help. `Get-Help -Parameter *` did not enumerate them under PowerShell 5.1;
the operations guide now uses the verified metadata-only `Get-Command -Syntax`
form. No script body was executed to inspect parameters.

## Local validation outcome

`tools/Test-Project.ps1` passed with exit 0 on Windows PowerShell 5.1 and
PowerShell 7: **267 passed, zero failed/skipped on each host**. BOM/parser,
wrapper synchronization and analyzer checks passed. The doc checker passed
8 Markdown documents and 58 relative links, parsed PowerShell examples without
execution, and its seven synthetic regressions passed. After the metadata-help
correction, standalone documentation checks passed again. No client, credential,
registry, scheduler, trading API or external URL was exercised by these checks.
The required module pins and existing workflow remain unchanged; invoking the
project runner integrates the doc check into both existing CI jobs.

## Native guide reconciliation

Follow-up on 2026-11-07: applied the same reviewed README, setup, operations,
architecture and testing corrections to the original native checkout. Relevant
working source was compared byte-for-text with the publication candidate:
`src/common.ps1`, `src/process-runner.ps1`, `src/paper-gateway.ps1`,
`src/credentials.ps1`, app/group/login configuration and the Gateway starter
matched. No native-specific runtime differences required alternate instructions.
The earlier testing-only deployment-boundary omission was reconciled as well.
The native guide changes and documentation checker/tests are committed separately;
unrelated native code/config/test changes remain unstaged. Native validation is
against that preserved working source, not a claim that its older Git code base
already contains every uncommitted implementation prerequisite. Dated release
records remain unchanged in both checkouts.

Native reconciliation validation: the full default runner passed on Windows
PowerShell 5.1 and 7, exit 0, **267 passed, zero failed/skipped per host**.
BOM/parser checks for 101 first-party files, wrapper, analyzer and doc checks
passed; the same 8 Markdown documents and 58 links were covered. This is local
working-tree evidence; publication CI acceptance remains a separate final-tree
check. Native code/config/runtime prerequisites were not staged with these docs.
