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
  command to copy it, or **Run** to run it. Low and info findings fold under the problems. Sections
  tenantctl could not check (a missing licence or permission) are listed as *Not checked*.
- **Tables** for every list: status words as colored badges (*Noncompliant*, *Service
  degradation*), dates as their age with the exact time on hover, ids last in mono. Click a row to
  open a card with every field, including the ones the table had no room for; click it again to
  close it. "More results exist" shows when a list was cut.
- **Actions** on every record: the card of a selected row, the record a report is about and the
  records nested in it (a user's manager, a device's Entra object) lead with buttons for their
  most used tenantctl commands, and open every other command that acts on them in a panel (see
  below).
- **Errors** as a card: the message, its code, the hint and the Graph request id. When a name
  matches several records, the candidates show as a table: **Use** runs the same command on that
  one by its id, and selecting a row gives it its actions.
- **Confirmations** (`confirmMode token`) as a card: the preview, its warnings, when it expires and
  the re-run command, copyable, with **Approve** to run it.
- stderr notes (fallbacks, partial results) stay visible under the result.

While a command runs you see its raw output, so a device-code sign-in or a `[y/N]` approval
prompt shows and takes your answer as usual; the native view replaces it when the command ends.
Help, `--version` and output the lens can't read stay raw.

## Actions

Select a device in `tenantctl intune devices list` (or under a user in `troubleshoot user`) and its
card leads with **Sync**, **Troubleshoot**, **Restart** and **Rotate LAPS**; select a user and you
get **Troubleshoot**, **Sign-ins**, **Revoke sessions** and **Reset password**. Every tenantctl
command that takes a record as its argument is offered on that record, for users, groups, Intune
and Entra devices, Defender machines, Autopilot devices, apps, policies, incidents, alerts,
mailboxes, inbox rules, sites, files, teams and more:

- its most used commands lead as buttons, destructive ones in red;
- **Look up** opens a panel of the commands that read more about it (details, compliance,
  sign-ins, …), one column per area (Troubleshoot, Entra, Exchange, …), wrapping onto more lines
  in a narrow pane; click it again to close it. A Windows device's panel also has **Reveal LAPS
  password** next to **LAPS** (tenantctl records every reveal in the Entra audit log);
- **Manage** opens the rest of its changes the same way, its own area first, then the others (a
  user's mailbox forwarding, OneDrive access, …);
- each related record gets a button that opens its panel: a device's user, Entra object and
  Defender machine, reached through the ids the row carries (Intune's `azureADDeviceId` names the
  Entra device and the Defender machine);
- a row listed under another record acts on the pair, and that action leads: a member of
  `entra groups members Sales` gets **Remove member**, a trustee of `exchange permissions list`
  gets **Remove permissions** with its access level, an inbox rule gets **Delete** on its
  mailbox. Adding what is already there is not offered.

Commands that would do nothing are left out: **Enable** on an enabled account, **Lock** on a
Windows device, **Rotate LAPS** on an iPhone.

A click runs the action in the **tenantctl** block: a panel that opens below the pane the first
time and collects every action you run from that tab, newest first. Each is headed by its command
(the copy button beside it copies the whole line), shows a progress bar while it runs and then its
result, drawn like any view with its own actions and a toast when it ends. Nothing is typed into
your terminal. Actions run with the same program path and `--profile` as the command that printed
the view, from your login shell's `PATH`.

A command that needs more input (**Rename…**, **Add license…**, a Defender action's
`--comment`) asks for it first in a field over the pane. tenantctl's own safety still applies:
writes need writes enabled, and destructive commands ask for your approval in tenantctl's
dialog; with `confirmMode token` the result is a confirmation card whose **Approve** runs it. An
action that needs a terminal (a `tty` approval prompt, a device-code sign-in) fails with
tenantctl's error: run that command in a pane instead. Actions stop after 10 minutes.

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
  written, logged or sent anywhere. No network requests and no files besides the plugin's own
  store; the only process it starts is tenantctl, when you click an action.
- The changes outside the view are the `TENANTCTL_OUTPUT` variable in new shells and the actions
  you click. Action links carry a secret only the plugin knows, so a link printed in a terminal
  can't run anything.

## Development

```sh
bash scripts/setup.sh    # pinned lune, stylua, selene, luau-lsp into .tools/bin; Tern API types
bash scripts/check.sh    # format, lint, types, unit tests
```

| Path | Role |
|---|---|
| `host.luau` | Host entry: the lens, the tenantctl block that runs actions, the spawn hook |
| `window.luau` | Window entry: routes action links, asks for missing input, opens the block |
| `lens/json.luau` | JSON decoder that keeps member order |
| `lens/text.luau` | Reads tenantctl's table format and `--csv` |
| `lens/output.luau` | One run's lines into a result, error or confirmation, plus notes |
| `lens/format.luau` | Labels, status tones, dates |
| `lens/records.luau` | What kind of record each part of a command's output is |
| `lens/actions.luau` | The commands that act on a record and its relations, as command lines |
| `lens/catalog.luau` | tenantctl's commands and their arguments (generated) |
| `lens/run.luau` | An action's command line into the tenantctl argv to start, and its missing input filled in |
| `lens/block.luau` | The tenantctl block's runs and their view |
| `lens/render.luau` | The view |
| `scripts/gen-fixtures.ts` | Renders `tests/fixtures/` with tenantctl's own output code |
| `scripts/gen-catalog.ts` | Writes `lens/catalog.luau` from tenantctl's command registry |

[CONTRIBUTING.md](CONTRIBUTING.md) covers setup, the sandboxed dev loop, tests and pull requests.

## Contributing and support

Bug reports, ideas and pull requests are welcome: read [CONTRIBUTING.md](CONTRIBUTING.md) first.
Questions go where [SUPPORT.md](SUPPORT.md) says; report vulnerabilities privately as described
in [SECURITY.md](SECURITY.md). Everyone taking part follows the
[Code of Conduct](CODE_OF_CONDUCT.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
