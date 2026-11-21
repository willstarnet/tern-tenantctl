# Contributing

Thanks for helping with tern-tenantctl. Small, tested pull requests are the easiest to review.
Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md). Report security problems
privately as [SECURITY.md](SECURITY.md) describes, never in a public issue; questions go where
[SUPPORT.md](SUPPORT.md) says.

## Setup

You need [Tern](https://docs.stencil.so/tern/) 0.9 or later to run the plugin and
[Bun](https://bun.sh) to regenerate fixtures. Everything else is pinned and installed into
`.tools/` (gitignored) by one script, on macOS arm64 and Linux x86_64:

```sh
bash scripts/setup.sh   # lune, stylua, selene, luau-lsp; types/tern.d.luau
bash scripts/check.sh   # what CI runs
```

`setup.sh` writes the Tern API types with `tern plugin types` when Tern is installed, else
downloads the published SDK's. Re-run it after upgrading Tern.

## Checks

`scripts/check.sh` runs, in order, and exits 1 if any fail:

| Step | Command |
|---|---|
| format | `stylua --check host.luau lens tests` (fix with `stylua host.luau lens tests`) |
| lint | `selene host.luau lens tests` |
| types | `luau-lsp analyze` of `host.luau` and `lens/` against the Tern types |
| tests | `lune run tests/run.luau` (add a filter argument to run matching cases only) |

## Code layout

- `host.luau` and `window.luau` are the only files that touch the `tern` global.
- `lens/` is pure: `render` takes `tern.ui` as an argument, so every module runs under Lune.
  `tests/lib/ui.luau` stands in for `tern.ui` with the same node shapes.
- The lens reads JSON first and tenantctl's table format second. Both produce the same `Value`
  tree, so one renderer serves both.
- Actions come from three places. `lens/catalog.luau` lists tenantctl's commands and their
  arguments; it is generated, never edited: run `bun scripts/gen-catalog.ts ../tenantctl` after
  tenantctl adds, renames or changes a command. `lens/records.luau` says what kind of record each
  part of a command's output is (`troubleshoot user`'s `devices` are Intune devices).
  `lens/actions.luau` says which kind each argument takes (`ARGS`) and which field of a record
  gives it (`REFS`): a new command that takes an existing kind needs nothing but the regenerated
  catalog; a new kind of record needs an entry in each. `FEATURED` there lists the commands a
  kind leads with as buttons; everything else opens in its **Look up** and **Manage** panels.
  `VARIANTS` offers a command again with a flag as an action of its own (**Reveal LAPS
  password** is `intune devices laps --reveal`).
- A view's buttons send `run=<command line>`, or `ask=<input>|<command line>` when the command
  needs more input. A lens can't redraw once its command has ended, so actions run elsewhere: the
  click opens a `tern-tenantctl://action/…` link carrying a secret from the plugin's store;
  `window.luau` checks it, asks for the input with `cx:prompt`, then sends the line to the tab's
  `action` block (or opens one), which starts tenantctl with `tern.process.run` and redraws when
  it ends. `lens/run.luau` turns the line back into argv and refuses anything but tenantctl.
- **Look up**, **Manage** and a related record's button send `open=<record path>|<panel>`, which
  the lens or block keeps in its state (`opened`) and draws as columns of buttons on its next
  view. Tern's `menu` node would do, but it neither opens nor sends in a lens view.

## Tests

- Specs live in `tests/unit/<area>_spec.luau` and use `tests/lib/test.luau`
  (`describe`, `it`, `expect(x).toBe/toEqual/toContain/...`).
- Fixtures in `tests/fixtures/` are what tenantctl prints, rendered by tenantctl's own output
  code from invented data: `bun scripts/gen-fixtures.ts ../tenantctl`. Add a case there rather
  than writing fixture text by hand, and **never commit real tenant data** (names, addresses,
  ids, IPs) in a fixture, issue or screenshot.
- Write the failing spec first. A bug fix starts with a spec that reproduces it.
- Assert what a user sees: the text, its tone, the column order, the copy action.

## Trying changes in Tern

Never point a development build at your real Tern. `scripts/sandbox.sh` moves the CLI's config,
daemon and logs into `$SB` and refuses to continue otherwise:

```sh
export SB=/tmp/tenantctl-lens-dev
source scripts/sandbox.sh
mkdir -p "$SB/pkg" && cp -R plugin.toml host.luau lens "$SB/pkg/"
tern plugin link "$SB/pkg"
tern --control "$SB/win.sock" ~ &                     # a sandboxed window
tern ctl --control "$SB/win.sock" run '"tenantctl health overview"'
tern ctl --control "$SB/win.sock" shot health        # target/shots/tern/live/health.png
```

Link a copy, not the checkout: Tern reloads a linked plugin whenever a file in its folder
changes. Copy again to pick up an edit. Plugin log lines land in `$SB/logs`. Quit the window with
`tern ctl --control "$SB/win.sock" quit`. tenantctl itself uses your real sign-in: run read
commands only.

## Pull requests

1. For anything bigger than a bug fix, open an issue first so the approach can be agreed on.
2. Branch from `main`; one change per pull request.
3. Use [Conventional Commits](https://www.conventionalcommits.org/): `feat: ...`, `fix: ...`,
   `docs: ...`, `test: ...`, `build: ...`, `chore: ...`, optionally scoped (`fix(text): ...`).
4. Add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for anything a user would
   notice, and update the README when behavior changes.
5. `bash scripts/check.sh` passes and CI is green on macOS and Linux.
