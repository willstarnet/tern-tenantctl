# Security policy

## Supported versions

Only the latest release gets fixes. Update with
`tern plugin install github.com/willstarnet/tern-tenantctl --force`.

## Reporting a vulnerability

Report it privately through GitHub:
<https://github.com/willstarnet/tern-tenantctl/security/advisories/new>. Do not open a public
issue, pull request or discussion about it.

Include what you found, the tern-tenantctl version (`tern plugin list`), the Tern version
(`tern --version`), the tenantctl version, your OS, and steps or a proof of concept. Never include
tenant data, tokens or secrets. You will get a reply within a week; the fix ships in a new release
with a published advisory.

## Scope

Tern has no plugin permission system, so these guarantees are the plugin's own, enforced by its
code and review. A way to make tern-tenantctl break one is in scope:

- storing, logging or sending command output, a command line or a working directory;
- any network request, child process, file write or change to Tern's settings;
- typing into or running commands in a terminal;
- changing a shell's environment beyond setting `TENANTCTL_OUTPUT` when it is unset;
- output from tenantctl (or a program claiming to be it) making the view open links or run
  actions the user didn't click.

Out of scope: vulnerabilities in Tern itself (report those to Stencil), in tenantctl (report
those at <https://github.com/willstarnet/tenantctl/security/advisories/new>), other plugins, and a
modified copy of the plugin's source.
