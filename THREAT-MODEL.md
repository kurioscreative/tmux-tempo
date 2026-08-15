# tempo's threat model, in plain language

This page is for tmux users, not security engineers: what you are actually
trusting when you install a plugin, what tempo's lockfile does and does not
defend, and why tempo does not try to sandbox anything. If a mechanism does
not protect you, this page says so.

## Installing a plugin means running arbitrary code as you

A tmux plugin is not data, and it is not a configuration value. It is a
program. tempo clones the plugin's git repository, and at every tmux server
start tmux executes the plugin's `*.tmux` entry scripts. They run as your
user, with your files, your network access, your SSH agent, and your shell.
A plugin can do anything you can do from a terminal.

So "install a plugin" means: _let the people who control this repository run
commands on my machine, as me, now and on every tmux start._ That was true
of tpm and no tmux plugin manager can change it — reaching into your live
tmux server and your shell is the whole point of a plugin. Pick plugins the
way you pick shell scripts to source from your `.bashrc`; it is the same
decision.

## What the lockfile pins

Every install, update, clean, and sync writes `tempo.lock` next to your tmux
config: for each plugin, its URL, its branch, and the exact commit — the
40-character git ID of one precise snapshot of the code. `tempo sync` and
`tempo restore` check that commit out (a _detached HEAD_: git is parked on
one specific commit instead of following whatever a branch points at today).
`sync --frozen` does the same offline and refuses to fetch anything.

What that buys you: an upstream **force-push** — the plugin's author
rewriting already-published history so the same branch or tag name now
resolves to different code — cannot silently change what you run. Neither
can a moved tag. Another machine, or the same machine next month, gets those
exact bytes rather than "whatever `main` is today". This is the cheapest
meaningful defense in a git-based ecosystem, and it is tempo's main one.

## What pinning does not protect against

- **A malicious commit you already pinned.** Pinning makes what you run
  reproducible; it does not make it good. If the code was hostile when you
  installed it, the lock faithfully reproduces that on every machine.
- **The first install.** Before there is anything to pin, tempo fetches
  whatever the branch points at right then.
- **Anything the plugin does while running.** Once it starts, nothing limits
  it. See the next section.
- **Your own machine being compromised.** Anyone who can run code as you can
  rewrite `tempo.lock` and the plugin clones alongside it.
- **Not knowing what changed.** tempo never reads or judges plugin code.
  `tempo update` moves the lock forward; it does not tell you whether the
  diff is safe. Reviewing is your job (`git log <old>..<new>` in the
  plugin's directory).

## Why there is no sandbox

tempo deliberately does not sandbox, isolate, or permission-gate plugins —
a choice, not an oversight. A plugin's entire job is to talk to your tmux
server and run shell commands, so a meaningful sandbox would have to forbid
the things plugins exist to do. Browser extensions show the cost of
retrofitting a permission model onto an ecosystem built without one: it
breaks legitimate uses, and here it would mostly push people back to
unmanaged manual clones, which are strictly worse.

The posture is **trust and pin** instead: make the decision to trust a
source explicit, and make the pin strong. That is honestly weaker than
isolation. It helps you avoid running _unexpected_ code; it does nothing
about code you chose to run.

## The first-install trust prompt (scoped behavior)

This section describes decided-and-scoped behavior that is not shipped yet;
re-read it once the trust prompt lands.

The first time the tempo CLI (`tempo install`, `tempo sync`, `tempo add`) is
asked to clone a source this host has never seen, it asks you to confirm,
showing the URL it will actually fetch. Approved URLs go in an **allowlist**
— a plain text file of one URL per line under tempo's data directory, which
you can read and edit yourself. In a terminal you get a `[y/N]` prompt; with
no terminal (a script, CI) tempo skips that plugin, prints how to proceed,
and exits non-zero. `--yes` approves without asking and records the URL, for
automation.

Its limits, stated plainly:

- **It covers the tempo CLI only.** `prefix + I`, `prefix + U`, and the
  compat `bin/install_plugins` scripts install without any prompt, because
  their behavior is pinned to match tpm exactly. A `@plugin` line installed
  with `prefix + I` is never gated; on that path your protection is the lock
  plus `sync --frozen`, not the prompt.
- **Trust is per host, on purpose.** Syncing your committed lock onto a
  fresh machine will prompt once per source — or needs `--yes` in CI.
  Approving a source on your laptop says nothing about your server.
- **It gates the URL, not the code.** Approving a repository once approves
  every future commit fetched from it. It is a "did you mean to add this
  source?" check, not a review, and nothing verifies who controls that URL.

## What tempo will not do

Not shortcomings to be fixed later — deliberate non-goals: sandboxing plugin
execution, operating a registry or vetting plugins, scanning plugin code,
and checking signatures (there is nothing signed in this ecosystem to check;
that would be revisited only if that changes).

## What actually helps

Read the `*.tmux` entry scripts of anything you install. Keep the plugin set
small and boring. Commit `tempo.lock`, and use `sync --frozen` wherever a
surprise download would be unwelcome. Update on purpose, and read the diff
when you do.
