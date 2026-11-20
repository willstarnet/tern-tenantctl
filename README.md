# tern-tenantctl

[![CI](https://github.com/willstarnet/tern-tenantctl/actions/workflows/ci.yml/badge.svg)](https://github.com/willstarnet/tern-tenantctl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A [Tern](https://docs.stencil.so/tern/) plugin that turns the output of
[tenantctl](https://github.com/willstarnet/tenantctl), the Microsoft 365 admin CLI, into native
views: reports led by their verdict, findings ranked by severity with the command that fixes each,
tables whose rows open into their full details, and errors and approvals as cards. The original
output is one click away (**Raw**).

```sh
tenantctl troubleshoot user jane@contoso.com    # verdict, ranked findings, account, MFA, sign-ins, devices
tenantctl intune devices list --top 50          # a table; click a row for every field
tenantctl entra users get jane                  # labeled fields, dates with their age
```

## What you get

- **Reports** (`troubleshoot`, `get`, `status`, `health overview`): the verdict or summary first,
  colored by the worst finding; then the fields as a labeled grid (`lastSyncDateTime` reads *Last
  sync*); nested objects and lists as sections you can fold.
- **Findings** ranked high to info, each with its detail and its `next` command: click the
  command to copy it. Low and info findings fold under the problems. Sections tenantctl could not
  check (a missing licence or permission) are listed as *Not checked*.
- **Tables** for every list: status words as colored badges (*Noncompliant*, *Service
  degradation*), dates as their age with the exact time on hover, ids last in mono. Click a row to
  open a card with every field, including the ones the table had no room for; click it again to
  close it. "More results exist" shows when a list was cut.
- **Errors** as a card: the message, its code, the hint and the Graph request id.
- **Confirmations** (`confirmMode token`) as a card: the preview, its warnings, when it expires and
  the re-run command, copyable.
- stderr notes (fallbacks, partial results) stay visible under the result.

While a command runs you see its raw output, so a device-code sign-in or a `[y/N]` approval
prompt shows and takes your answer as usual; the native view replaces it when the command ends.
Help, `--version` and output the lens can't read stay raw.

## Install

```sh
tern plugin install github.com/willstarnet/tern-tenantctl           # install
tern plugin install github.com/willstarnet/tern-tenantctl --force   # update
tern plugin remove tern-tenantctl                                   # uninstall
```

Requires Tern 0.9 or later and tenantctl 0.2 or later. To run a local checkout instead,
`tern plugin link <dir>` uses it in place; `tern plugin unlink tern-tenantctl` undoes that.

**Open a new pane after installing.** The plugin gives new shells `TENANTCTL_OUTPUT=json` (see
below); panes that were already open still get native views, read from tenantctl's table format,
where long values are cut at 60 characters.

## How it works

- The lens claims every command line Tern reads as `tenantctl …` (also after `sudo`, `env`,
  `VAR=value` and with a full path, and `bun run tenantctl …` in a tenantctl checkout). Pipelines,
  lists (`a && b`) and redirected output are never lensed: they print as before.
- Zsh reports alias-expanded command lines, so a zsh alias for tenantctl is claimed too.
- Inside a lens tenantctl writes to a terminal and would print its table format, which cuts long
  values and drops nested ones. So a `spawn` hook sets `TENANTCTL_OUTPUT=json` in new shells and
  the lens reads the full JSON. A `TENANTCTL_OUTPUT` you set yourself (login environment or shell
  rc) wins.
- The side effect: tenantctl commands that are *not* lensed in a Tern shell (a list such as
  `tenantctl x && echo done`, or with Settings › Terminal › Native command output off) print JSON.
  To keep tables there, `export TENANTCTL_OUTPUT=table` in your shell rc; the lens then reads the
  table format.
- Output over 4 MiB stays raw (`--all` on a very large tenant).

## Privacy

- Command output is read in Tern's host process and kept only to draw the view; it is never
  written, logged or sent anywhere. No network requests, no processes, no files.
- The only change outside the view is the `TENANTCTL_OUTPUT` variable in new shells.

## Development

```sh
bash scripts/setup.sh    # pinned lune, stylua, selene, luau-lsp into .tools/bin; Tern API types
bash scripts/check.sh    # format, lint, types, unit tests
```

| Path | Role |
|---|---|
| `host.luau` | Host entry: the lens and the spawn hook (the only file that touches `tern`) |
| `lens/json.luau` | JSON decoder that keeps member order |
| `lens/text.luau` | Reads tenantctl's table format and `--csv` |
| `lens/output.luau` | One run's lines into a result, error or confirmation, plus notes |
| `lens/format.luau` | Labels, status tones, dates |
| `lens/render.luau` | The view |
| `scripts/gen-fixtures.ts` | Renders `tests/fixtures/` with tenantctl's own output code |

[CONTRIBUTING.md](CONTRIBUTING.md) covers setup, the sandboxed dev loop, tests and pull requests.

## Contributing and support

Bug reports, ideas and pull requests are welcome: read [CONTRIBUTING.md](CONTRIBUTING.md) first.
Questions go where [SUPPORT.md](SUPPORT.md) says; report vulnerabilities privately as described
in [SECURITY.md](SECURITY.md). Everyone taking part follows the
[Code of Conduct](CODE_OF_CONDUCT.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
