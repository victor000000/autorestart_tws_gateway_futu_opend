# Operations and security boundaries

[Documentation home](../README.md) · [Setup](setup.md) · [Testing](testing.md)

## Command reference

Run from the repository root in 64-bit Windows PowerShell 5.1, for example `.\start-us-market.ps1 -Wait`. Root entry points preserve existing shortcuts and task paths.

| Command | Scope / options |
| --- | --- |
| `start-data-maintenance.ps1` | Futu OpenD + Gateway + OBS recording |
| `start-cn-market.ps1` | CN apps + ZSQH login worker |
| `start-us-market.ps1` | US apps including TWS + sequential Futubull/thinkorswim login workers |
| `autostart-extra-apps.ps1` | Extra group from `config/groups.psd1`; includes TWS, excludes maintenance and login workers |
| `autostart-trading-apps.ps1` | Full group: maintenance + extra apps; does not include market login workers; always waits |
| `complete-us-login.ps1` | Futubull then thinkorswim login workers; waits for each; does not launch the apps |
| `start-ibgateway.ps1` | `-TimeoutSeconds 300` default; `-UseDirectExe` for manual login |
| `start-futu-opend.ps1` | `-TimeoutSeconds 180` default |
| `start-tws.ps1` | `-TimeoutSeconds 60` default; `-UseDirectExe` for manual login |
| `start-ibkr-desktop.ps1` | Standalone; `-InstallDir 'C:\ntws'`, `-TimeoutSeconds 60` defaults |
| Other individual starters | `start-excel`, `start-obs`, `start-schwab`, `start-futubull`, `start-tradingview`, `start-shinny`, `start-yongchun`, `start-wh6`, `start-doublecmd` (all `.ps1`) |
| `start-obs.ps1` | Starts OBS and begins recording with OBS's `--startrecording` switch; `-NoRecord` starts OBS without recording |
| `stop-trading-apps.ps1` | `-Target Both` default; accepts `Futu` or `IBGateway` |
| `stop-extra-apps.ps1` | Auxiliary targets listed under [stop and restart](#stop-and-restart) |
| `restart-trading-apps.ps1` | Stop maintenance only, then dispatch `autostart-trading-apps.ps1` |
| `restart-all-apps.ps1` | Stop auxiliary targets and maintenance, then dispatch `autostart-trading-apps.ps1` |
| `show-gateway-window.ps1` | Restore Futu OpenD and Gateway windows |
| `gateway-tray.ps1` | Gateway tray helper; also started after Gateway readiness |

Market, maintenance, and extra group commands accept `-Wait` and `-TimeoutSeconds` (default 600, range 1–3600). Without `-Wait`, success means dispatch only. The full-group command accepts these parameters but forces waiting even with `-Wait:$false`. A wait timeout does not terminate workers or applications. Restart commands dispatch that full-group worker asynchronously, so their return does not confirm startup completion.

`start-shinny.ps1`, `start-yongchun.ps1`, `start-schwab.ps1`, and `start-futubull.ps1` run their login worker by default after launching the application; `-NoLogin` skips it. The app is only logged in when this call actually launched it — an already-running application is left alone (run `login-zsqh-clients.ps1`, `login-thinkorswim.ps1`, or `login-futubull.ps1` directly instead). Group dispatch adds `-NoLogin` for starters whose application is already covered by a login worker in that group ([config/logins.psd1](../config/logins.psd1)), so two workers never contend for the shared desktop input lock. Re-running a group whose clients are already authenticated stays successful: the ZSQH worker recognizes 快期3 by its live main window and 咏春大师2 by its login form being hidden to the tray, and sends no input in either case.

Workers launch in separate Windows PowerShell processes with a short stagger. Membership order is not a dependency/readiness barrier. Only the US login coordinator explicitly serializes its two login workers. Do not run competing GUI login workflows at once.

Starting a workspace also starts OBS recording. `start-obs.ps1` verifies the start in the OBS log instead of assuming it, and an OBS that is already running cannot be told to record from its command line: when it is not recording, the starter fails rather than reporting a start that did not happen.

## Logs and readiness

| Location | Use |
| --- | --- |
| `logs/apps.log` | Group dispatch/completion, ordinary launches, auxiliary stops, tray events, OBS recording start |
| `%APPDATA%\obs-studio\logs\*.txt` | OBS's own log; `start-obs.ps1` reads its Recording Start/Stop markers and output path to verify recording |
| `logs/ibgateway.log` | Gateway launch route and API readiness |
| `logs/futu-opend.log` | OpenD readiness and window handling |
| `logs/autostart.log` | Default shared log, maintenance stops and task administration |
| `logs/ibc/` | Locally configured IBC diagnostics |
| `C:\Jts\ibgateway\1051\launcher.log` | Vendor Gateway authentication log at the default install |
| Other files under `logs/` | App-specific login logs and opt-in diagnostic captures |

Read recent project output without printing credential files:

```powershell
Get-Content .\logs\apps.log -Tail 60
Get-Content .\logs\ibgateway.log -Tail 60
```

Process presence is sufficient for ordinary starters. API starters additionally require listener ownership and a successful local TCP connection. Neither confirms upstream brokerage health, correct account, market-data permissions, or every login worker's authentication state. Check those in the vendor application. Logs and screenshots can contain account context; review/redact before sharing.

## Troubleshooting

| Symptom | Check / next action |
| --- | --- |
| Group returns immediately | Add `-Wait` to the original command to observe worker exits. Existing apps are generally reused. |
| 快期3/Q73N does not start | Check `%APPDATA%\Q73N_cnzsqh_3_standard\dir.xml`: `<current>` names the installed build, while a newer directory can hold only an unsigned upgrade stub. See [install paths](setup.md#install-paths-and-configuration). |
| Wait times out | Inspect visible login/passkey/MFA prompts and app logs. Workers remain running; a retry is not cancellation. |
| Gateway/OpenD process exists but readiness fails | Verify login and configured API port, then check listener ownership. Another process using 4001/11111 does not count. |
| IBKR session is displaced | Choose the required IBKR product. TWS refuses a new launch while Desktop runs; Desktop refuses a new launch while TWS/Gateway runs. Existing clients are preserved. Gateway does not evict competing apps locally. The full group can launch Gateway and TWS concurrently. |
| Executable missing or wrong version starts | Compare [install defaults](setup.md#install-paths-and-configuration) with actual installs and customized IBC paths. |
| Credential store unavailable after moving user/machine | DPAPI is bound to its Windows context. Recreate the IBKR entry with the updater under the intended user; do not print or hand-copy decrypted secrets. |
| IBC config write fails | Check private-folder permissions and credential validity. Failed publication is an error; do not make the folder broadly writable. |
| GUI worker declines input or login is unverified | Complete login manually; inspect the app-specific log. Do not loosen fingerprints or repeatedly guess clicks. |
| OBS is running but not recording | Start recording in OBS, or close OBS and rerun `start-obs.ps1`; `-NoRecord` starts OBS without the recording check. This launcher never sends input to OBS. |
| Hidden Gateway prompt | Run `.\show-gateway-window.ps1`; complete authentication manually. |
| Stopped process returns | Review local IBC/external watchdog settings. Unknown replacement processes are not swept up by shutdown. |
| Scheduled startup does not run | Inspect `TradingApps-Autostart` in Task Scheduler. Registration defaults to disabled; the trigger is user logon with a 20-second delay. |
| Validation says pinned modules are missing | Explicitly run `tools/Install-TestDependencies.ps1`, then retry `tools/Test-Project.ps1`. See [testing](testing.md). |

## Manual authentication stays manual

IBC can fill IB Gateway/TWS credentials, but passkey/Windows Security confirmation is manual. IBKR Desktop has no IBC integration; its password and passkey remain manual. Futubull's own Automatic Login is preferred and does not automatically unlock trading.

thinkorswim login is permitted only when a uniquely classified login step is visible at the expected size. GUI input checks exact root-window identity, geometry, bounds, foreground state and input counts; the state is rechecked near injection. Login scripts share a nonblocking mutex. These checks reduce risk but cannot make global mouse/keyboard input atomic with a screenshot. Avoid interacting with the desktop during GUI login; unexpected screens require manual attention, not repeated guessed clicks.

`login-thinkorswim.ps1 -TestOnly` observes the current form without bringing or resizing it. Diagnostic screenshots are opt-in using `-CaptureDiagnostics` and remain private under `logs/`. The ZSQH worker verifies the requested account before submission and no longer treats UI-provider errors as authentication success. Unexposed account controls may require manual login rather than an unsafe remembered-account assumption.

Futubull has no committed, verified workspace fingerprint. Its fallback can recognize and submit a known login form once, but without a supplied `-MainScreenFingerprint` cannot positively certify the resulting workspace. A pre-existing unrecognized workspace is left untouched and logged as unverified. After an attempted login, an unverified result fails so `-Wait` can surface manual attention. Do not pass an arbitrary fingerprint to silence that failure.

## Credentials

- `secrets/credentials.sec`: CurrentUser DPAPI; usable only under the appropriate Windows user/machine context.
- `secrets/ibc-config.ini`: plaintext required by IBC; restrictive user/SYSTEM DACL and atomic publication on new writes. It persists for supervisor restarts. Ignore rules are not encryption and do not prevent the same Windows user or administrators from reading data.
- Config rendering escapes Java Properties, preserves Unicode via escapes, and rejects values IBC would trim/change. Logs identify the credential source but never the value.
- Password comparisons during credential refresh are case-sensitive. Failed publication or readback is a failure, not a successful update.
- `show-credentials.ps1` is a deliberate secret-printing tool. Do not run it in a shared terminal, transcript, automated test, or CI job.
- `type-secret.ps1` is manual input into the selected desktop context. A missing username never falls back to notes/password. Do not use it as unattended startup automation.
- Windows auto-logon administration writes a password to Winlogon registry data. It is independent of project DPAPI storage and is not enabled or changed by this refactor.

## Stop and restart

Auxiliary stops include TradingView, thinkorswim, wh6, AlgoMaster, Q73N, Futubull, and IBKR Desktop. Excel/OBS are deliberately protected. Standalone TWS/Double Commander are not implicitly included in auxiliary stop policy. Captured process IDs and start times are revalidated; new/reused identities are not swept up by a later name match. IBC Java identities require the exact main-class marker.

Graceful closure is attempted before the existing bounded force phase. Force can lose unsaved application state or disconnect clients; use these commands only when intended. Root wrappers preserve errors, and restart launch is cancelled if a stop fails.

A local IBC batch or external watchdog may respawn a stopped process. The scripts do not indiscriminately kill cmd/Java/powershell parents or unknown replacement processes. Review the supervisor configuration manually if a restart does not stay stopped. TWS/Desktop/Gateway sharing an IBKR login can displace one another's sessions; do not assume simultaneous sessions are supported. Before a new launch, TWS stops IBKR Desktop, and IBKR Desktop stops TWS and IB Gateway (graceful close, then bounded force). TWS does not explicitly stop Gateway, and Gateway does not stop TWS or Desktop. Already-running starters skip these launch-time stops. Shared-credential conflicts can therefore still occur, particularly in the full group.

## Tasks, tray, runtime maintenance

Repository edits do not change existing task state. Inspect Task Scheduler for the current machine state. Running the manual setup command creates or replaces `TradingApps-Autostart` using an interactive current-user logon trigger, a 20-second delay, and limited privileges. The task launches the full group and is disabled unless explicitly passed `-Enable`; registration errors terminate instead of creating an unexpected Startup shortcut.

The tray helper reports expected-process/listener presence, not brokerage health. Exit removes only the helper/icon and restores relevant windows; it does not stop Gateway. New icons may be hidden by Windows under the tray overflow chevron. Promote through Windows Taskbar settings if desired; registry promotion hacks are not used.

The ignored IBC runtime contains locally customized absolute paths. Back it up privately before updates or moving the repository; a fresh upstream extraction is not necessarily equivalent. Keep private diagnostics out of Git. No runtime folder or historical screenshot was automatically deleted during restructuring.

### Dedicated paper Gateway

`start-ibgateway.ps1 -Paper -PrepareOnly` prepares the dedicated instance without
launching an application or opening a login window. It uses only the encrypted
`ibkr_tws_gateway_paper` entry and writes the ignored paper config/batch. Missing
paper credentials fail closed; live credentials and 1Password fallback are
forbidden for paper mode. `-UseDirectExe` is rejected with `-Paper`.

`start-ibgateway.ps1 -Paper` launches that instance on **4002**, using
`ibc/settings-paper` and `logs/ibc-paper`. The live config, settings, logs,
processes, port 4001, and tray are not reused or altered. Process readiness
requires the exact paper config argument and ownership of port 4002. A different
process on 4002 causes a failure before any config write. An already-running
paper instance is never reconfigured. Concurrent starts are serialized.

The generated configuration uses `ExistingSessionDetectedAction=secondary`, so
an account-session conflict terminates the new session instead of displacing an
existing one. The API starts **read-only**, and second-factor timeout retries are
disabled. Authentication/passkey and any first-time prompts remain manual. An
explicit start may show Gateway UI; use `-PrepareOnly` for headless preparation.
No application is launched during offline validation.

Listener readiness does not establish account identity. Before changing a
consumer's saved port, use a read-only managedAccounts probe and require the
entire result to equal its existing expected paper account list. Never change
that allowlist to fit the observed session. Enabling order submission is a
separate explicit operator decision; this preparation does not enable it.

A pre-existing WSL user unit `ibkr-paper-start.service` invokes `-Paper` at boot
on this host. This source change does not register, enable, start, or restart the
unit. The test suite covers mode/port isolation, live-batch preservation, ownership,
credential failures, and prepare-only behavior using synthetic fixtures.

The separate settings/log directories follow the
[IBC multiple-instance guidance](https://github.com/IbcAlpha/IBC/blob/master/userguide.md#multiple-ibc-instances).
