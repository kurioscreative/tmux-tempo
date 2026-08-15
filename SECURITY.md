# Security policy

## Reporting a vulnerability

Please report security issues **privately**, not in a public issue.

Use GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/kurioscreative/tmux-tempo/security/advisories/new)
(the _Security_ tab of this repository → _Report a vulnerability_). It needs
no account setup beyond a GitHub login, and the report stays between you and
the maintainer until a fix ships.

Include what you would want to receive: the version or commit, your OS and
tmux version, what an attacker gains, and the smallest reproduction you have.

## What to expect

This is a single-maintainer project, so the honest numbers are modest ones:

- **Acknowledgement within 7 days.** If you have not heard back by then,
  assume the report was missed and ping the advisory thread.
- **An assessment within 30 days** — either a fix, or a written reason the
  behavior is intended (see below).
- Fixes ship in a normal release; the advisory is published once the fix is
  out, crediting you unless you ask otherwise.

There is no bounty program.

## Scope, and what is intended behavior

Read [THREAT-MODEL.md](THREAT-MODEL.md) before reporting. It is the statement
of what tempo does and does not defend against, and it is deliberately blunt
about the limits — most importantly that installing a tmux plugin runs someone
else's code as you, that there is no sandbox, and that the trust prompt is
scoped to the `tempo` CLI while `prefix + I` / `prefix + U` and the compat
bins stay ungated on purpose.

Those documented limits are **not** vulnerabilities; a report that tempo runs
plugin code will be closed with a pointer back to that document. A report that
tempo does something the threat model says it does not — for example writing
outside the paths it names, running plugin code on a path documented as
Ruby-free and network-free, or letting a lockfile-pinned commit be silently
substituted — is exactly what this policy is for.

In scope: this repository's code and its generated loader artifact. Out of
scope: vulnerabilities in the plugins a user chooses to install (report those
to the plugin), and in tmux, git or Ruby themselves (report those upstream).
