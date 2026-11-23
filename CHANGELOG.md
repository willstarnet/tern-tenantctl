# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- A record's actions show on labeled lines instead of behind panels: **Look up** lists every
  troubleshooting read and every read in the record's own area (a device's Details, Compliance,
  Config states, Apps, BitLocker key, LAPS, Actions, Sync status), with the other areas' under its
  **More**; **Change** leads with the most used changes, the rest under its **More**; **Related**
  holds the related records' buttons.
- **BitLocker key** shows the recovery keys, not only their ids (it runs `bitlocker-key --reveal`;
  tenantctl records the reveal in the Entra audit log). **Reveal BitLocker key** is gone.

### Added

- A `bitlocker-key` run without `--reveal` leads with **Reveal keys**, and a `laps` run without it
  with **Reveal LAPS password**.

### Fixed

- The first line of a view (a record's **Look up** buttons) wraps before the top-right corner,
  where Tern draws its tenantctl · Native · Raw switch when the block is selected, so no button
  hides under it.

## [0.4.1] - 2026-11-21

### Fixed

- A record opened in the tenantctl panel by one name and by another (a device by its name and by
  its id) no longer keeps two workspaces: once either is read, they merge into one with the tabs
  and activity of both. Names are matched without regard to case.

## [0.4.0] - 2026-11-21

### Added

- The tenantctl panel is a workspace per record: the record opens read whole, in a tab of its
  own, with its actions at the top (a button spins while its command runs). Lookups show in tabs
  that refresh in place; changes go to the workspace's activity and the record is read again once
  they are done. **Open** brings a listed record to the front; **Refresh** and **×** read it again
  or close it. Workspaces survive a restart.
- **Work on these** opens a list of records in the panel; **Pick several** there (or under any list
  of records in the panel) runs one action on each picked row, four at a time, with each row's
  outcome in a **Last action** column, one prompt for input they all need, and **Approve all**.
- **Reveal BitLocker key**, **Defender full scan**, **Wipe, keep enrollment**, **Wipe, keep user
  files** (Windows), **Fresh start, keep user files** on devices; **Full scan** and **Isolate, keep
  Outlook and Teams** on Defender machines.
- **Copy** next to revealed passwords and keys.

### Changed

- Picking an action from a panel in the tenantctl block closes the panel, so its result shows in
  its place.
- Approving a confirmation settles it: its **Approve** no longer stays offered.

## [0.3.0] - 2026-11-21

### Added

- **Reveal LAPS password** in a Windows device's **Look up** panel, next to **LAPS**: runs
  `intune devices laps --reveal`. LAPS is no longer offered on devices that aren't Windows.

### Changed

- A record leads with its most used actions (a device's Sync, Troubleshoot, Restart and Rotate
  LAPS; a user's Troubleshoot, Sign-ins, Revoke sessions and Reset password) instead of every
  change it has. **Look up**, **Manage** and each related record open a panel with a column per
  area that wraps in a narrow pane, in place of the folded groups of buttons.
- Fields holding ids come last in a record's details, as in tables.
- A finding's **Run** and a confirmation's **Approve** come before their command, and a finding's
  severity keeps its width in a narrow pane.
- In the tenantctl block a run is headed by its command, with a copy button, instead of repeating
  it below; its error or confirmation shows inside the run's card, not as a card of its own.

## [0.2.0] - 2026-11-20

### Added

- Actions on every record: a selected row's card, the record a report is about and the records
  nested in it get buttons for each tenantctl command that acts on them (sync, restart, rotate
  LAPS, revoke sessions, reset password, remove member, …), plus folded groups for lookups,
  other areas and related records (a device's user, Entra object and Defender machine).
- Actions run in a **tenantctl** block below the pane, never typed into the terminal: progress
  while they run, then their result with its own actions and a toast. A command that needs more
  input asks for it first. Only tenantctl runs, and only from links carrying the plugin's secret.
- **Run** on a finding's next step and **Approve** on a confirmation card.
- An ambiguous match (`"WS-PF3" matches 4 devices`) lists the candidates as a table: **Use** runs
  the same command on that one, and selecting a row gives it its actions.

## [0.1.0] - 2026-11-20

### Added

- A lens for every `tenantctl` command: raw output while it runs, a native view when it ends.
- Reports led by their verdict or summary, findings ranked by severity with copyable `next`
  commands, and *Not checked* lines for sections tenantctl couldn't read.
- Tables for lists with status badges, dates as their age and ids last; clicking a row opens a
  card with every field.
- Error and confirmation cards, and stderr notes under the result.
- Reads tenantctl's JSON, its table format and `--csv`.
- New shells get `TENANTCTL_OUTPUT=json` unless it is already set.

[Unreleased]: https://github.com/willstarnet/tern-tenantctl/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/willstarnet/tern-tenantctl/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/willstarnet/tern-tenantctl/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/willstarnet/tern-tenantctl/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/willstarnet/tern-tenantctl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/willstarnet/tern-tenantctl/releases/tag/v0.1.0
