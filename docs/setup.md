# Setup and first launch

[Documentation home](../README.md) · [Operations](operations.md) · [Testing](testing.md)

## Prerequisites

Use a Windows desktop with 64-bit Windows PowerShell 5.1 and an interactive session under the intended trading user. Linux PowerShell is not a production host for these scripts. PowerShell 7 on Windows is an additional offline validation host.

1. Keep the checkout at a stable location. Existing ignored `ibc/StartGateway.bat` and `ibc/StartTWS.bat` can contain absolute paths to this checkout, settings, configuration, and logs.
2. Install the vendor applications needed for your chosen group. The project does not install vendor software or the IBC runtime.
3. Open each application manually once and complete required vendor setup. Confirm the intended account and API settings before automating launch.
4. Review install paths below. Run launchers under the same Windows user who created the DPAPI credential store.

## Install paths and configuration

| Application | Default location or discovery | Where to change it |
| --- | --- | --- |
| Futu OpenD | `%APPDATA%\Futu_OpenD\Futu_OpenD.exe` | `src/common.ps1` |
| IB Gateway 10.51 | `C:\Jts\ibgateway\1051` | `src/common.ps1`; review local IBC batch too |
| TWS 10.50 | `C:\Jts\1050` | `scripts/apps/start-tws.ps1`; review local IBC batch too |
| IBKR Desktop | `C:\ntws\ntws.exe` | `start-ibkr-desktop.ps1 -InstallDir 'C:\your-install'` |
| Excel | Office16 default, then registered App Paths fallback; newest non-lock workbook in `%USERPROFILE%\Documents\trading_logs` | `scripts/apps/start-excel.ps1` |
| TradingView | Microsoft Store application identity | `scripts/apps/start-tradingview.ps1` |
| OBS, thinkorswim, wh6, AlgoMaster, Futubull, Double Commander | Fixed executable or numeric version-directory discovery | `config/apps.psd1` |
| 快期3 / Q73N | `%APPDATA%\Q73N_cnzsqh_3_standard`, then the build named by `dir.xml` `<current>` | `config/apps.psd1` (`Manifest`) |

Q73N's installer stages the next release in a new version directory whose `Q73N.exe` is an unsigned upgrade stub, not the trading client. The launcher's `dir.xml` `<current>` entry names the installed, signed build, so that directory is used instead of the numerically newest one.

[App defaults](../config/apps.psd1) expand `%APPDATA%` and `%LOCALAPPDATA%` at runtime. [Group configuration](../config/groups.psd1) controls membership; [entry-point mapping](../config/entrypoints.psd1) maps public command names to implementations. These files contain no passwords. Preserve UTF-8 BOM when editing PowerShell data files.

Maintenance readiness expects local TCP ports **11111 for Futu OpenD** and **4001 for Gateway**. Configure the applications to match these expectations, or deliberately update the checks in `scripts/apps/start-futu-opend.ps1` and `src/process-runner.ps1` together with their tests. An unrelated process listening on a port does not satisfy readiness.

## Credentials and IBC

For automatic IBKR credential entry, provide the locally configured IBC runtime under `ibc/`. Review its batch files and settings privately; runtime binaries and machine-specific files are intentionally not versioned. Gateway and TWS use IBC when their batch file exists and credentials are available; otherwise they attempt direct launch for manual login. `-UseDirectExe` explicitly selects direct launch.

The IBKR credential refresh reads a 1Password item using the `op` CLI. Install and authorize that CLI if using this path. The default item ID is workstation-specific; supply your own when configuring another account:

```powershell
.\update-ibkr-credentials.ps1 -ItemId 'YOUR_1PASSWORD_ITEM_ID'
```

This creates or updates the `ibkr_tws_gateway` entry in `secrets/credentials.sec`, encrypted with Windows CurrentUser DPAPI. Other entries are preserved. Repeat after changing the IBKR password. Startup first uses that saved entry and falls back to 1Password if unavailable; interactive 1Password authorization may then be required.

The updater only manages IBKR. thinkorswim and ZSQH login workers depend on existing application-specific entries in the private credential store; this repository provides no general credential provisioning wizard. Complete those logins manually if their entries are unavailable. Prefer Futubull's own Automatic Login; the worker does not unlock trading.

The generated IBC configuration sets `TradingMode=live` and `SecondFactorDevice=Passkey`; no paper-mode launcher switch is provided. Review `src/credentials.ps1` before adapting this project to a different mode.

IBC receives a generated **plaintext** `secrets/ibc-config.ini` with restricted user/SYSTEM permissions. It persists for supervisor restarts. Do not delete it while a supervisor depends on it or copy it into shared folders. See [credential storage](../secrets/README.txt) and [authentication boundaries](operations.md#credentials).

## Verify the first launch

Start one required application or group at a time. For API services:

```powershell
.\start-data-maintenance.ps1 -Wait
$LASTEXITCODE
```

Complete visible authentication/passkey prompts before the worker timeout. A zero exit confirms worker completion; check the application for upstream connection and account status. For market groups, inspect each brokerage session manually even after a successful wait. The [operations guide](operations.md#troubleshooting) explains where to find failures.

Choose between IBKR Desktop, TWS, and Gateway according to your workflow. Desktop launch closes TWS/Gateway; TWS launch closes Desktop. Gateway/TWS are not mutually stopped by the launchers, so using the same IBKR credentials can still cause a session conflict.

## Optional logon task

Validate manual startup before registering a task. `setup-autostart-task.ps1` creates or replaces `TradingApps-Autostart` for the current user; it starts the **full group**, not just maintenance. It uses an interactive, limited-privilege logon trigger delayed by 20 seconds.

```powershell
# Register or replace the task in a disabled state
.\setup-autostart-task.ps1

# Explicitly register or replace it enabled
.\setup-autostart-task.ps1 -Enable
```

Registration uses `-Force` and can replace an existing task with that name. Inspect its state in Task Scheduler. No Startup-folder fallback is created on failure. Enabling the task does not remove manual authentication requirements or resolve Gateway/TWS session conflicts.

Windows auto-logon is separate from this task. Its helper writes a password to Winlogon registry data; it is not required for manual use and is not part of this checklist.
