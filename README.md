# tempo

A drop-in replacement for [tpm](https://github.com/tmux-plugins/tpm), the
tmux plugin manager — same config lines, same key bindings, same install
path — plus the things tpm never grew: a **lockfile** for reproducible
plugin sets, **real exit codes**, a **`doctor`** command, and a startup hot
path that runs zero Ruby and zero network.

Your existing `.tmux.conf` does not change. If it worked with tpm, it works
with tempo.

## Requirements

- **tmux ≥ 1.9** — same floor as tpm.
- **git** — used for all plugin installs and updates.
- **Ruby ≥ 3.0** (standard library only; no gems, no bundler) — needed only
  for management operations (install / update / clean / sync). Loading
  already-installed plugins at tmux startup does **not** need Ruby: startup
  executes a pregenerated `sh` artifact. macOS note: the deprecated system
  Ruby 2.6 is not enough; install a current Ruby via Homebrew or a version
  manager.

Not sure what you have? After cloning, run `bin/tempo doctor` from the
checkout (see Troubleshooting).

## Install

Clone the repo anywhere you like, then let `tempo init` wire it in:

```sh
git clone git@github.com:<your-github-username>/tmux-tempo.git ~/.tmux/plugins/tempo-src
cd ~/.tmux/plugins/tempo-src
bin/tempo init
```

While this repo is private, clone over SSH as above (HTTPS will prompt for
credentials). The path is yours to choose — `~/.tmux/plugins/tempo-src`,
`~/src/tmux-tempo`, a stow package, anywhere. `init` records where the
checkout actually is.

`init` **wires, it never installs**: no network, no git clones, no running
tmux required. It reads your tmux config files (`~/.tmux.conf`, the XDG
`~/.config/tmux/tmux.conf`, system configs), looks at their `run` /
`run-shell` lines, and picks one of two modes:

- **Drop-in mode** — your config already has a `run '~/.tmux/plugins/tpm/tpm'`
  line (you are a tpm user). Whatever currently occupies
  `~/.tmux/plugins/tpm` is **renamed aside** to `tpm.orig-<timestamp>`, and
  `~/.tmux/plugins/tpm` becomes a symlink to your checkout. **Your tmux
  config is not modified at all** — the existing run line now resolves into
  tempo.
- **Fresh mode** — no tpm run line found. `init` symlinks
  `<plugin-path>/tempo` (`~/.tmux/plugins/tempo`, or
  `~/.config/tmux/plugins/tempo` if you use an XDG config) at your checkout
  and appends `run '~/.tmux/plugins/tempo/tempo'` to your tmux config. An
  existing config is copied to `<conf>.bak-<timestamp>` first; if you have
  no config at all, a minimal one is created (a commented `@plugin` example
  plus the run line). An already-present run line is not duplicated.

Before touching anything, `init` prints its full plan — every rename,
symlink, and config write, with final paths — and, when run interactively,
asks `Proceed? [y/N]`. Answering no aborts with nothing changed. Pass
`--yes` (or `-y`) to skip the prompt; non-interactive runs (scripts,
provisioning) proceed without asking.

If a run line already resolves into this checkout, `init` prints
`Already set up` and does nothing — it is idempotent, safe to re-run. In
fresh mode, if `<plugin-path>/tempo` already exists as a real directory or
as a symlink to something else, `init` **refuses**: it exits 1 with a
message and touches nothing.

Then declare plugins in your tmux config — the standard tpm block,
unchanged:

```tmux
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'

# keep this line at the very bottom of tmux.conf
run '~/.tmux/plugins/tempo/tempo'
```

Reload tmux (`tmux source ~/.tmux.conf`) and press **`prefix` + `I`**
(capital i) to install the declared plugins. A `tempo.lock` file appears
next to your config file — commit it to your dotfiles.

### Alternative: clone straight to the tpm path

`init` is optional. You can still clone this repo where the tmux ecosystem
hardcodes the plugin manager (yes, the directory is named `tpm` — every
dotfiles snippet in the wild points there, and tempo impersonates that
layout on purpose):

```sh
git clone git@github.com:<your-github-username>/tmux-tempo.git ~/.tmux/plugins/tpm
```

with the usual `run '~/.tmux/plugins/tpm/tpm'` line at the bottom of your
config. Nothing else changes; the two layouts behave identically.

Installing into a symlinked directory (`~/.tmux/plugins/tpm` → a checkout
elsewhere, as dotfiles managers like stow do) is supported and tested —
that is exactly the shape `init` creates.

## Migrating

**From tpm**: clone and run `init`. That is the whole migration.

```sh
git clone git@github.com:<your-github-username>/tmux-tempo.git ~/.tmux/plugins/tempo-src
~/.tmux/plugins/tempo-src/bin/tempo init
```

`init` detects your existing `run '.../tpm/tpm'` line and takes drop-in
mode: your old tpm clone is renamed to `~/.tmux/plugins/tpm.orig-<timestamp>`
(kept, not deleted — the migration is reversible) and the tpm path is
symlinked at the tempo checkout. No `rm -rf`, no config edits.

Your already-installed plugins under `~/.tmux/plugins/` are adopted in
place — the first `prefix + I` reports them as `Already installed` and
snapshots them into `tempo.lock`. No plugin re-downloads.

**From manual `run-shell` lines**: if your config loads plugins directly
(e.g. `run-shell ~/clones/tmux-resurrect/resurrect.tmux`), switch each line
to a declaration and let tempo own the clone:

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
```

Then `prefix + I`. Plugin options (`set -g @resurrect-*` etc.) stay exactly
where they are. Once installed, delete your manual clones.

If your config file is a **symlink** into a dotfiles repo, the lockfile is
written next to the real file — inside the repo, where you can commit it.

## Usage

Key bindings (identical to tpm, overridable via `@tpm-install`,
`@tpm-update`, `@tpm-clean`):

- `prefix` + `I` — install declared plugins
- `prefix` + `U` — update plugins (prompts: a name, or `all`)
- `prefix` + `alt` + `u` — remove plugins no longer in the config

The same operations — and the new ones — are available from a shell:

```
~/.tmux/plugins/tpm/bin/tempo <command>

  init         wire this checkout into your tmux setup
  install      install declared plugins
  update all   update plugins (parallel)
  clean        remove undeclared plugin dirs
  sync         install missing + restore locked commits + clean
               (--frozen: enforce the lock offline, never write it)
  restore      put every plugin back on its locked commit
               (--frozen: as above, without installing or cleaning)
  rollback     undo the last operation (rollback N: go to generation N)
  status       declared plugins, lock state and generation history
  generate     regenerate the loader artifact
  doctor       check requirements, paths and artifact health
```

Uninstalling a **plugin** is the tpm gesture: delete (or comment out) its
`@plugin` line, then `prefix` + `alt` + `u`.

### Where plugins actually live

`~/.tmux/plugins/<name>` is a **symlink**. The clone itself lives once per
`(url, commit)` under `~/.local/share/tempo/store/` (XDG), and a filed copy
is never modified again: `update` pulls in a throwaway working copy and files
the result as a new entry, then flips the link; `restore` flips the link back.
Nothing in your config changes, and plugins still see the familiar
`~/.tmux/plugins/<name>/…` path in `$0` — the symlink is not resolved before
they run.

What you get: two configs (or two machines' worth of dotfiles under one
`$HOME`) that want the same plugin at the same commit share one clone,
and rolling back to a locked commit is instant and offline whenever that
commit was ever installed here.

Two consequences worth knowing:

- **A shared clone is a shared directory.** A plugin that caches state inside
  its own folder shares that cache with every config pointing at the same
  entry. If that matters for a plugin you use, keep its directory in the old
  flat layout (below) — the hybrid layout is supported indefinitely.
- **Existing plain directories are adopted lazily**, on the first
  install/update/sync/restore, and only when the directory is a faithful
  checkout of its remote: no uncommitted or untracked files, and a HEAD some
  remote branch contains. Anything else keeps its real directory, keeps
  working exactly as before, and says so once:

  ```
    "tmux-menus" kept as a plain directory: uncommitted changes
  ```

  That is a notice, not an error — the command still succeeds. To adopt such
  a plugin later, commit or discard the local changes and run any mutating
  command again.

Old entries are reclaimed by generations (below), so the store does not grow
without bound.

### Generations and rollback

Every operation that changes what is installed — `install`, `update`, `clean`,
`sync`, `restore`, and the `prefix + I` / `prefix + U` bindings — first files a
**generation**: the lockfile exactly as it stood, plus which store entry each
plugin pointed at. Filing one is cheap (a few hundred bytes; the plugins are
already in the store), so the previous state is always still there.

`prefix + U` broke something?

```
$ bin/tempo rollback
  "tmux-yank" rolled back
rolled back to generation 7
```

The plugin-path symlinks flip back, `tempo.lock` is rewritten to that
generation's bytes — that is deliberate: the revert should show up in your
dotfiles diff — and the next tmux reload runs the old code. Nothing goes over
the network. `bin/tempo rollback 4` goes to a specific generation instead of
the previous one, and `bin/tempo status` lists what is available:

```
generations (newest first, keeping 10):
    8    2026-08-15T09:41:02Z  update   3 plugin(s)
  * 7    2026-08-15T09:12:44Z  install  3 plugin(s)
```

Rolling back does not file a generation of its own — it moves the `*` marker —
so rolling back twice walks further into the past rather than bouncing between
two states.

Two things rollback deliberately does not do:

- **It never edits your tmux config.** A plugin you declared after the target
  generation has nothing to roll back to; rollback names it and moves on
  (`"tmux-fzf" is declared but not in generation 4; run install or sync`).
- **It does not touch plugins kept as plain directories** (adoption declined,
  above) — there is no second copy of those to flip to, so they are reported
  and left alone.

The last **10** generations are kept. That number is a constant, not a
setting. When a generation ages out, any store entry that no remaining
generation references — and that no plugin currently links to — is deleted
with it. That is what keeps `~/.local/share/tempo/store/` from growing
forever.

### The lockfile

Every install/update/clean writes `tempo.lock` (JSON: plugin → url, branch,
commit) next to your real config file. On a new machine, after cloning your
dotfiles and this repo: `bin/tempo sync` reproduces the exact locked
plugin set — same commits, not just same plugins. `restore` checks out
locked commits without installing or cleaning; `update` moves the lock
forward.

#### `--frozen`

`sync --frozen` (and `restore --frozen`) is the `cargo --locked` posture,
for CI and for machines where a surprise download is not acceptable. It
never touches the network and never writes `tempo.lock`. Before changing
anything it checks that every declared plugin is installed, is in the
lockfile, and has its locked commit already in its local clone. If any of
those fails it prints **every** offending plugin and exits 1 having changed
nothing — no partial enforcement of a lock that cannot be satisfied:

```
$ bin/tempo sync --frozen
frozen: lockfile not satisfied
  "tmux-sensible" not installed
  "tmux-yank" locked commit a1b2c3d4e5f6 missing locally
```

The fix is a plain `bin/tempo sync`, which is allowed to download.

Unrecognized flags are a usage error everywhere (`--frozen` on `install`
included — installing is a network operation by definition), so a typo
fails loudly instead of being ignored.

## Security

Installing a tmux plugin means running someone else's code with your
privileges, and tempo does not sandbox it — the lockfile pins what runs,
which is a real but limited defense. What that does and does not protect
against is spelled out in [THREAT-MODEL.md](THREAT-MODEL.md).

## Troubleshooting

`~/.tmux/plugins/tpm/bin/tempo doctor` prints one line per fact that
matters — tmux and Ruby versions against their gates, git presence, the
resolved plugin path and its writability, which config files were found,
declared vs installed plugin counts, loader-artifact freshness, and the
lockfile's location and parseability. It exits non-zero when a hard
requirement (tmux ≥ 1.9, git) is missing, so it is scriptable.

Common first-run cases it (or the install output) explains:

- **"No plugins declared"** — your config has no `@plugin` lines, or tmux
  is reading a different config file than you edited (doctor lists the
  candidates it checked).
- **"tempo requires Ruby >= 3.0"** — management operations are gated; see
  Requirements. Already-installed plugins keep loading without Ruby.

## Uninstall

Remove the clone and the generated state; your plugins and config are
untouched:

```sh
rm -rf ~/.tmux/plugins/tpm ~/.local/share/tempo
```

**Rolling back `tempo init`** — both modes are reversible, and `init` left
you the pieces:

- **Drop-in mode**: delete the symlink and restore the backup tpm clone.
  Your config never changed, so it goes back to running tpm.

  ```sh
  rm ~/.tmux/plugins/tpm
  mv ~/.tmux/plugins/tpm.orig-<timestamp> ~/.tmux/plugins/tpm
  ```

- **Fresh mode**: delete the symlink and drop the run line `init` appended
  (or restore the whole config from `<conf>.bak-<timestamp>`).

  ```sh
  rm ~/.tmux/plugins/tempo
  # then delete the `run '~/.tmux/plugins/tempo/tempo'` line from your config
  ```

Note that `tempo clean` never deletes the manager's own install directory,
whatever it happens to be named — the guard resolves real paths, so a
checkout symlinked in as `tempo`, `tpm`, or anything else is safe from it.

To stop using plugins entirely, also remove the `@plugin` and `run` lines
from your tmux config and delete `~/.tmux/plugins/`, `tempo.lock`, and
`~/.local/share/tempo/` — the last of these holds the generated loader **and
the plugin store**, so deleting the plugins directory alone leaves the clones
on disk.

## How it works

Short version: Ruby is a _compiler_, not a runtime. Management commands
scan your config once and emit a straight-line `sh` loader plus a
freshness fingerprint into `~/.local/share/tempo/`; every tmux server
start just executes that artifact. Plugins themselves are stored once per
`(url, commit)` in the same directory and linked into `~/.tmux/plugins/`,
which is what makes updates and rollbacks link flips. The full walkthrough —
hot path, management plane, the store, lockfile semantics, and the
intentional divergences from tpm (real exit codes, visible
non-executable-file warnings) — is in
[ARCHITECTURE.md](ARCHITECTURE.md).

## For maintainers: publishing a snapshot

This repo is a manual snapshot of the `tempo/` directory of a private
development monorepo (where the compat suite and the vendored original
live). To publish a new snapshot: run the monorepo gates (unit, flows,
compat), copy the contents of `tempo/` over this repo's working tree,
review the diff, commit, push. There is no publish automation by design.
