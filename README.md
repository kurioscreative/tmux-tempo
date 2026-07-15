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

Not sure what you have? After installing, run
`~/.tmux/plugins/tpm/bin/tempo doctor` (see Troubleshooting).

## Install

Clone this repo where the tmux ecosystem hardcodes the plugin manager
(yes, the directory is named `tpm` — every dotfiles snippet in the wild
points there, and tempo impersonates that layout on purpose):

```sh
git clone git@github.com:<your-github-username>/tmux-tempo.git ~/.tmux/plugins/tpm
```

While this repo is private, clone over SSH as above (HTTPS will prompt for
credentials). Then make sure your tmux config declares plugins and runs the
entry script — the standard tpm block, unchanged:

```tmux
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'

# keep this line at the very bottom of tmux.conf
run '~/.tmux/plugins/tpm/tpm'
```

Reload tmux (`tmux source ~/.tmux.conf`) and press **`prefix` + `I`**
(capital i) to install the declared plugins. A `tempo.lock` file appears
next to your config file — commit it to your dotfiles.

Installing into a symlinked directory (`~/.tmux/plugins/tpm` → a checkout
elsewhere, as dotfiles managers like stow do) is supported and tested.

## Migrating

**From tpm**: replace the old clone and keep everything else.

```sh
rm -rf ~/.tmux/plugins/tpm
git clone git@github.com:<your-github-username>/tmux-tempo.git ~/.tmux/plugins/tpm
```

Your already-installed plugins under `~/.tmux/plugins/` are adopted in
place — the first `prefix + I` reports them as `Already installed` and
snapshots them into `tempo.lock`. No plugin re-downloads, no config edits.

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

  install      install declared plugins
  update all   update plugins (parallel)
  clean        remove undeclared plugin dirs
  sync         install missing + restore locked commits + clean
  restore      check out lockfile commits (detached HEAD)
  status       declared plugins and lock state
  generate     regenerate the loader artifact
  doctor       check requirements, paths and artifact health
```

Uninstalling a **plugin** is the tpm gesture: delete (or comment out) its
`@plugin` line, then `prefix` + `alt` + `u`.

### The lockfile

Every install/update/clean writes `tempo.lock` (JSON: plugin → url, branch,
commit) next to your real config file. On a new machine, after cloning your
dotfiles and this repo: `bin/tempo sync` reproduces the exact locked
plugin set — same commits, not just same plugins. `restore` checks out
locked commits without installing or cleaning; `update` moves the lock
forward.

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

To stop using plugins entirely, also remove the `@plugin` and `run` lines
from your tmux config and delete `~/.tmux/plugins/` and `tempo.lock`.

## How it works

Short version: Ruby is a _compiler_, not a runtime. Management commands
scan your config once and emit a straight-line `sh` loader plus a
freshness fingerprint into `~/.local/share/tempo/`; every tmux server
start just executes that artifact. The full walkthrough — hot path,
management plane, lockfile semantics, and the intentional divergences from
tpm (real exit codes, visible non-executable-file warnings) — is in
[ARCHITECTURE.md](ARCHITECTURE.md).

## For maintainers: publishing a snapshot

This repo is a manual snapshot of the `tempo/` directory of a private
development monorepo (where the compat suite and the vendored original
live). To publish a new snapshot: run the monorepo gates (unit, flows,
compat), copy the contents of `tempo/` over this repo's working tree,
review the diff, commit, push. There is no publish automation by design.
