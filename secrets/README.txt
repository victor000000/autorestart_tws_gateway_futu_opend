Credential storage
==================

This directory is private runtime data. Git ignores every file here except
this documentation. Do not commit stores, generated configurations, backups,
or screenshots containing account information.

credentials.sec
  JSON encrypted with Windows DPAPI, CurrentUser scope. It is bound to the
  original Windows user/machine context. Copying it to another profile does
  not make it decryptable there.

  The ibkr_tws_gateway entry contains username/password and an update time.
  Other application entries are preserved when the IBKR entry is refreshed.
  Refresh with the root update-ibkr-credentials.ps1 command after an IBKR
  password change. The 1Password authorization step may be interactive.

ibc-config.ini
  Generated PLAINTEXT credentials required by the locally configured IBC
  launchers. Unlike credentials.sec, this file is NOT encrypted. Publication
  uses a restricted current-user/SYSTEM DACL and an atomic staging/replace
  operation. The config persists because IBC may reread it for restarts.
  Do not move/delete it while an active supervisor depends on it.

No validation or CI test reads these real files. Tests use synthetic data and
temporary files only. The show-credentials.ps1 helper deliberately decrypts
and prints secrets; run it only as an intentional private manual operation.

See ../docs/operations.md for security boundaries and recovery cautions.
