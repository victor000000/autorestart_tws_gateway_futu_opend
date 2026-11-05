# Agent defaults

Repository for launching CN/US trading workspaces on this Windows desktop. Commands, logs, credentials, and safety boundaries are documented in [README.md](README.md) and [docs/operations.md](docs/operations.md); this file records the defaults an agent must apply without being asked again.

## "start <workspace>" means start **and** auto-login

When the user says `start cn`, `start us`, `start maintenance`, `start extra`, or just `start`, treat it as: launch the matching group **with `-Wait`**, let the group's login workers authenticate the clients, let OBS start recording, and then report what is running, what is authenticated, and whether OBS is recording.

```powershell
# CN: Excel, OBS, 快期3/Q73N, 咏春大师2/AlgoMaster, wh6 + ZSQH auto-login
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-cn-market.ps1 -Wait

# US: Excel, OBS, TWS, thinkorswim, Futubull, TradingView + sequential Logins
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-us-market.ps1 -Wait

# Everything else
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-data-maintenance.ps1 -Wait
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\autostart-extra-apps.ps1 -Wait
```

Rules that follow from this default:

1. Do not ask whether to log in — CN and US groups already dispatch their login workers ([config/logins.psd1](config/logins.psd1)). Never inject desktop input yourself; the workers own the shared UI login lock.
2. One start command at a time. Concurrent GUI login workers contend for the same desktop input lock.
3. Report launch, authentication, and OBS recording separately, reading `logs/apps.log` plus the app-specific log (`logs/zsqh-login.log`, `logs/futubull-login.log`, `logs/thinkorswim-login.log`, `logs/tws.log`, `logs/ibgateway.log`, `logs/futu-opend.log`). "Process detected" is not "logged in".
4. A nonzero exit identifies a failing worker. Inspect that app's log and the visible window; fix or report. Do not retry credential submission in a loop and do not weaken GUI checks to make a step pass.
5. Never stop, restart, log out, or close a running trading client unless the user asked for it. Excel and OBS are deliberately protected from stop commands.
6. Keep credentials out of output: never print `secrets/` content or run `show-credentials.ps1`; DPAPI entries are read by the scripts only.
7. 快期3/Q73N runs from the build named by `%APPDATA%\Q73N_cnzsqh_3_standard\dir.xml` `<current>`, not the newest version directory (a newer one can hold an unsigned upgrade stub).
8. OBS recording starts with the workspace through OBS's own `--startrecording`; confirm the `OBS recording started` line in `logs/apps.log`. An OBS that is already running cannot be told to record from a command line — report that and let the user decide; never close OBS yourself to restart it.

## When changing code

- Implementations live in `scripts/` and `src/`; root `.ps1` files are generated compatibility wrappers — edit the implementation, then run `.\tools\Sync-EntryPoints.ps1`.
- PowerShell source and data files must be UTF-8 **with BOM**.
- Run `.\tools\Test-Project.ps1` before reporting a change as done; it must pass offline and must not launch applications.
- Production host is Windows PowerShell 5.1; PowerShell 7 is for offline validation only.
