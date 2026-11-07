# Trading application launcher

Version **0.0.3**. See the [release design and review](docs/release-0.0.3.md).

Windows PowerShell scripts for launching CN and US trading workspaces, Futu OpenD, and IB Gateway. Run commands in an interactive Windows desktop under the user who owns the credentials.

## Quick start

Complete the [setup checklist](docs/setup.md) before the first launch. From the repository root in **64-bit Windows PowerShell 5.1**, choose one workspace:

```powershell
# API services: Futu OpenD on 11111 and IB Gateway on 4001
.\start-data-maintenance.ps1 -Wait

# CN workspace
.\start-cn-market.ps1 -Wait

# US workspace
.\start-us-market.ps1 -Wait
```

Run only the command for the workspace you need. From Git Bash or WSL, invoke the Windows host explicitly:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./start-data-maintenance.ps1 -Wait
```

| Workspace | Applications |
| --- | --- |
| Maintenance | Futu OpenD + IB Gateway 10.51 + OBS (recording) |
| CN | Excel + OBS (recording) + 快期3/Q73N + 咏春大师2/AlgoMaster + wh6; ZSQH login worker |
| US | Excel + OBS (recording) + TWS 10.50 + thinkorswim + Futubull + TradingView; sequential Futubull/thinkorswim login workers |

Group membership is defined in [config/groups.psd1](config/groups.psd1). IBKR Desktop is a separate, manual-login application, launched with `start-ibkr-desktop.ps1`; it is not in the US group and does not expose the TWS API.

## Completion and session behavior

Market and maintenance commands return after dispatch unless `-Wait` is supplied. With `-Wait`, worker failures produce a nonzero exit; `-TimeoutSeconds` bounds the aggregate wait (default 600, range 1–3600). A timeout leaves workers and applications running. `autostart-trading-apps.ps1` launches the full group and **always waits**, even without `-Wait`.

Ordinary starters check for a process, not an authenticated brokerage session. Maintenance starters require the expected process to own its API listener and accept a TCP connection; upstream connectivity and trading permissions still need verification. Existing processes are generally reused. Excel opens the newest non-lock `.xlsx` in `Documents/trading_logs` only when Excel is not already running.

Starting a workspace also starts OBS recording. `start-obs.ps1` launches OBS with OBS's own `--startrecording` switch, then reads the new OBS log to confirm the recording actually began; pass `-NoRecord` to start OBS without recording. An OBS that is already running cannot be told to record from its command line, so when it is not recording the starter fails instead of reporting a start that did not happen — start recording in OBS, or close OBS and rerun the starter.

`start-shinny.ps1`, `start-yongchun.ps1`, `start-schwab.ps1`, and `start-futubull.ps1` log the application in by default after they launch it; pass `-NoLogin` to skip the login worker. An application that was already running is not re-authenticated — run `login-zsqh-clients.ps1`, `login-thinkorswim.ps1`, or `login-futubull.ps1` explicitly for that. Groups that dispatch a login coordinator pass `-NoLogin` to their starters, so only one worker drives the shared desktop input lock. Re-running a group whose clients are already authenticated still exits successfully: 快期3 is recognized by its live main window and 咏春大师2 by its hidden login form, and no input is sent. IBKR credential entry remains IBC-driven.

A new TWS launch refuses to proceed while IBKR Desktop is running. A new IBKR Desktop launch refuses to proceed while TWS or IB Gateway is running. Existing clients are preserved; explicitly stop the conflicting client only when intended. TWS and Gateway can still coexist locally, so shared credentials may cause an upstream session conflict. The full group includes both and does not serialize their IBKR logins.

Passkey, MFA, and Windows Security prompts require manual attention. GUI login workers need an idle desktop; unexpected screens are left for manual review. Worker completion alone does not prove every session authenticated.

## Common operations

| Command | Effect |
| --- | --- |
| `start-<app>.ps1` | Start an individual application; see [command reference](docs/operations.md#command-reference) |
| `stop-trading-apps.ps1 -Target Both` | Stop Futu OpenD and Gateway; also accepts `Futu` or `IBGateway` |
| `stop-extra-apps.ps1` | Stop configured auxiliary targets; preserve Excel/OBS |
| `restart-trading-apps.ps1` | Stop maintenance services, then dispatch the full group |
| `restart-all-apps.ps1` | Stop auxiliary targets and maintenance, then dispatch the full group |
| `show-gateway-window.ps1` | Show Futu OpenD/Gateway windows for manual attention |
| `update-ibkr-credentials.ps1` | Refresh the local IBKR credential copy from 1Password |

Stop/restart can force processes closed after a grace period. Finish unsaved work and review active sessions first. See [operations](docs/operations.md) for exact targets, task setup, logs, and troubleshooting.

## Documentation

- [Setup](docs/setup.md): prerequisites, install paths, credentials, and first launch.
- [Operations](docs/operations.md): commands, readiness, troubleshooting, authentication, and shutdown boundaries.
- [Architecture](docs/architecture.md): source layout, shared helpers, configuration, and contribution workflow.
- [Testing](docs/testing.md): isolated validation, dependency installation, and CI.
- [Credential files](secrets/README.txt): DPAPI storage and plaintext IBC configuration.

Source changes do not register tasks or enable Windows auto-logon. Task registration is an explicit administrative operation and defaults to disabled; existing machine settings must be checked separately. Credentials, logs, screenshots, and customized IBC runtime files are private and Git-ignored.

## Development

Edit implementations under `scripts/` and shared helpers under `src/`; root `.ps1` files are generated compatibility entry points. Keep PowerShell source/data in UTF-8 **with BOM** for Windows PowerShell 5.1.

```powershell
# Explicit download of pinned project-local tools
.\tools\Install-TestDependencies.ps1

# Offline validation; does not launch trading applications
.\tools\Test-Project.ps1

# After changing entry-point parameters
.\tools\Sync-EntryPoints.ps1
```

Production launchers use Windows PowerShell 5.1. CI validates offline behavior on Windows PowerShell 5.1 and PowerShell 7; it does not establish live vendor UI compatibility. See the [testing guide](docs/testing.md) before changing runtime behavior.

## Read the design and operational contracts

Start with [setup](docs/setup.md), then [operations and recovery](docs/operations.md). [Architecture](docs/architecture.md#contracts-and-state-provenance) defines what launch, readiness and recording evidence mean; [testing](docs/testing.md#documentation-validation) explains offline checks and CI limits. This workstation tool has no continuous deployment or order API. Version 0.0.3 is the current source version; later documentation corrections are tracked in the [documentation audit](docs/documentation-audit.md), separately from the dated release record.
