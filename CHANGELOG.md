# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/willstarnet/tern-tenantctl/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/willstarnet/tern-tenantctl/releases/tag/v0.1.0
