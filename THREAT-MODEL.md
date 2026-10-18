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

`tempo.lock` sits next to your tmux config: for each plugin, its URL, its
branch, and the exact commit — the 40-character git ID of one precise
snapshot of the code. `tempo install` puts the plugin back on exactly that
commit. It reads the lock before it acts and never rewrites the pin of a
plugin you still declare: it only adds entries for plugins it just installed
and drops entries for plugins you no longer declare, so a run that fails
partway — no network, upstream gone, the locked commit unreachable — leaves
your committed pins untouched for the next attempt. Only an explicit
`tempo update` moves a pin; to undo one, restore the previous `tempo.lock`
from your dotfiles history and run `install`. A lock that exists but does not
parse — merge-conflict markers, say — stops `install` rather than being
replaced by a fresh snapshot. (The plugin directory is a plain git clone, as
under tpm. When it is on a branch, install moves that branch to the locked
commit rather than detaching HEAD, so a later `tempo update` can still pull;
if you have edited the plugin's files in a way that conflicts, install
refuses and reports it instead of discarding your edit. Either way the bytes
that run are the locked ones.) `install --frozen` does the same offline and
refuses to fetch anything.

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
hand-made clones no tool keeps track of, which are strictly worse.

The posture is **pin** instead: you decide what to run by writing the
`@plugin` line, and tempo makes the pin strong. That is honestly weaker than
isolation. It helps you avoid running _unexpected_ code; it does nothing
about code you chose to run.

## There is no install-time confirmation prompt

tempo does not ask you to approve a source before cloning it, and adding one
would not buy much. `prefix + I` runs inside a tmux `run-shell` with no
terminal on stdin, and the compat `bin/install_plugins` scripts exist to be
called from provisioning — both are non-interactive by construction, so any
prompt would skip the path nearly everyone installs through. A prompt on the
remaining path would
be asking you to confirm a URL you typed into your own config seconds
earlier, which trains a reflex rather than a decision. And a per-URL approval
gates the source, never the code: approving a repository once approves every
commit ever fetched from it afterwards.

What actually constrains what runs on your machine is the lockfile: it pins
exact commits, `install --frozen` refuses to move off them, and any change shows
up as a diff in your dotfiles. That is the control worth relying on.

## What tempo will not do

Not shortcomings to be fixed later — deliberate non-goals: sandboxing plugin
execution, operating a registry or vetting plugins, scanning plugin code,
and checking signatures (there is nothing signed in this ecosystem to check;
that would be revisited only if that changes).

## What actually helps

Read the `*.tmux` entry scripts of anything you install. Keep the plugin set
small and boring. Commit `tempo.lock`, and use `install --frozen` wherever a
surprise download would be unwelcome. Update on purpose, and read the diff
when you do.
