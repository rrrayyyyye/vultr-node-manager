# Project guidance

This is a Windows PowerShell 5.1 and Windows Forms project. Keep runtime code compatible with Windows PowerShell 5.1. Save `.ps1` files as UTF-8 with BOM for Chinese text; generated YAML must be UTF-8 without BOM. Shell templates use LF.

Private runtime settings are `nodes.json` and `vultr-api.key`. Never commit them, generated client configs, real bootstrap scripts, logs, deployment records or backups. Use `nodes.example.json` and mocked fixtures in tests.

Run all test scripts documented in README before committing changes. Tests must not need real credentials or call live cloud APIs. Live status checks are read-only; never create or destroy real cloud resources as an automated test.

## Code Review Rules

### Region isolation

- Flag any create/delete behavior that targets another configured region, allows duplicate creation without checking existing instances, or deletes ambiguous duplicate labels. Queries must include pagination.
- Each simultaneously running node needs its own domain. A local lock cannot prevent another computer from racing a cloud operation; do not claim cross-machine locking.

### Credentials and portability

- Flag real credentials, exported client files, personal deployment data, or secret-bearing bootstrap scripts added to tracked files.
- Keep paths relative to the script directory. Migration must preserve private local settings, and first-run setup must not create cloud resources.

### Status reporting

- Never report the complete proxy connection as healthy based only on TCP 443 or DNS checks. Failed child processes must return nonzero exit codes.
