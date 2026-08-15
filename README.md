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
git clone https://github.com/kurioscreative/tmux-tempo.git ~/.tmux/plugins/tempo-src
cd ~/.tmux/plugins/tempo-src
bin/tempo init
```

The path is yours to choose — `~/.tmux/plugins/tempo-src`,
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
git clone https://github.com/kurioscreative/tmux-tempo.git ~/.tmux/plugins/tpm
```

with the usual `run '~/.tmux/plugins/tpm/tpm'` line at the bottom of your
config. Nothing else changes; the two layouts behave identically.

Installing into a symlinked directory (`~/.tmux/plugins/tpm` → a checkout
elsewhere, as dotfiles managers like stow do) is supported and tested —
that is exactly the shape `init` creates.

## Migrating

**From tpm**: clone and run `init`. That is the whole migration.

```sh
git clone https://github.com/kurioscreative/tmux-tempo.git ~/.tmux/plugins/tempo-src
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
               (--yes: trust new sources without asking)
  add <spec>   declare a plugin in your config, then install it
               (--yes: trust new sources without asking)
  remove       delete a plugin's declaration from your config
  update all   update plugins (parallel)
  clean        remove undeclared plugin dirs
  sync         install missing + restore locked commits + clean
               (--frozen: enforce the lock offline, never write it)
               (--yes: trust new sources without asking)
  restore      put every plugin back on its locked commit
               (--frozen: as above, without installing or cleaning)
  rollback     undo the last operation (rollback N: go to generation N)
  search       find plugins in the curated index
  trust        record a source as trusted, without installing it
  status       declared plugins, lock state and generation history
  generate     regenerate the loader artifact
  doctor       check requirements, paths and artifact health
```

### Finding plugins

```
$ tempo search clipboard
tmux-yank — Copy to the system clipboard from copy mode and the command prompt
  set -g @plugin 'tmux-plugins/tmux-yank'
```

The second line is exactly what goes in your config — copy it in, then
`prefix + I`. Search matches names, descriptions and tags, case-insensitively.

The index is a single reviewed JSON file in its own public repo,
[`tmux-tempo-index`](https://github.com/kurioscreative/tmux-tempo-index) — no
registry, no service, no account. It is
fetched the first time you search and cached for a day under
`~/.local/share/tempo/index.json`. That fetch is the **only** network access
tempo makes outside `install`/`update` — starting tmux never touches the
network, and neither does anything else. If the fetch fails, an existing
cached copy is used and says so; `tempo doctor` shows how old it is.

Run `tempo search` in a terminal and it also offers to install one of the
matches for you:

```
$ tempo search clipboard
1. tmux-yank — Copy to the system clipboard from copy mode and the command prompt
  set -g @plugin 'tmux-plugins/tmux-yank'

Install which? [1-1, Enter to skip] 1
```

Enter is always the safe answer, and the picker never appears without a
terminal — in a pipe or a script, `search` prints its matches and stops.

### Adding and removing plugins

`tempo add` writes the declaration for you and installs it:

```
$ tempo add tmux-plugins/tmux-yank
Added to /Users/you/.tmux.conf: set -g @plugin 'tmux-plugins/tmux-yank'
Backed up /Users/you/.tmux.conf -> /Users/you/.tmux.conf.bak-20260815-114500
Installing "tmux-yank"
  "tmux-yank" download success
```

It appends exactly one line — the same canonical form `search` prints — and
copies your config to a timestamped `.bak-` file first. A symlinked config
(dotfiles setups) is written _through_: the link survives and the file in
your repo is what changes. Adding a plugin you already declare, in any quote
form, changes nothing and says where it is already declared.

`tempo remove <name>` deletes the declaration again:

```
$ tempo remove tmux-yank
Removed /Users/you/.tmux.conf:12: set -g @plugin 'tmux-plugins/tmux-yank'
Its files are still installed — run `tempo clean` to delete them.
```

It only ever deletes a whole line it can fully parse, in your primary config.
Anything else it refuses, names, and leaves alone:

```
$ tempo remove tmux-foo
tempo remove: refusing to edit this declaration
  /Users/you/.tmux.conf:8: set -g @tpm_plugins "tmux-foo tmux-bar"
      the legacy @tpm_plugins list is never edited by tempo — remove it by hand.
```

The same refusal covers a declaration inside a `%if` block, one in a file
your config `source-file`s, and one written in a form tempo cannot parse
whole. Your config is your file: a manager that guesses at a hand-tuned line
is worse than one that tells you exactly which line to edit. Nothing is
changed on a refusal, not even a backup.

The old gesture still works, of course: delete (or comment out) the
`@plugin` line by hand, then `prefix` + `alt` + `u`.

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
against is spelled out in [THREAT-MODEL.md](THREAT-MODEL.md); to report a
vulnerability in tempo itself, see [SECURITY.md](SECURITY.md).

### The first-install prompt

The first time you ask the **`bin/tempo` CLI** to clone a source this machine
has never fetched from, it shows the URL git will actually be handed and asks:

```
$ tempo install

tempo has never installed from this source on this host:

  tmux-plugins/tmux-yank
  https://git::@github.com/tmux-plugins/tmux-yank

A tmux plugin runs as you, with your files and your network,
every time tmux starts.
Trust this source and install "tmux-yank"? [y/N]
```

Answer `y` and the URL is appended to `~/.local/share/tempo/trusted_urls` — a
plain text file, one URL per line, `#` comments allowed, yours to read and
edit. It is never asked about again. Answer `n` and that plugin is skipped;
the others in your config still install.

With no terminal (a script, CI, a cron job) there is nobody to ask, so tempo
skips the plugin, prints the URL and how to proceed, and exits non-zero:

```
  "tmux-yank" skipped: source not trusted on this host
      tmux-plugins/tmux-yank
      approve it with `tempo trust tmux-yank`, or re-run with --yes
```

`tempo trust <name-or-url>` records a source without installing anything —
give it a declared plugin's name or a URL directly. `--yes` on
`install`/`sync` approves and records whatever is about to be cloned, which
is the CI gesture.

Three limits, stated plainly:

- **The CLI only.** `prefix + I`, `prefix + U` and `bin/install_plugins`
  install without asking, because their behavior is pinned byte-for-byte to
  tpm's. On those paths your protection is the lockfile and `sync --frozen`.
- **Per host, on purpose.** Syncing a committed lock onto a new machine asks
  once per source (or takes `--yes`). Trusting a source on your laptop says
  nothing about your server.
- **It gates the URL, not the code.** Approving a repository approves every
  commit ever fetched from it afterwards. It is a "did you mean to add this
  source?" check, not a review.

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

## License

MIT — see [LICENSE](LICENSE). Security reports go through
[SECURITY.md](SECURITY.md).

## For maintainers: publishing a snapshot

This repo is a manual snapshot of the `tempo/` directory of the development
monorepo (which also holds the tpm compat suite and the vendored original).
There is no publish automation, by design — a snapshot is a deliberate act:

1. In the monorepo, run all three gates and make sure they are green:

   ```sh
   cd tempo && ruby -Ilib -Itest test/run_all.rb
   sh tempo/test/flows/run_flows.sh
   TPM_UNDER_TEST=./tempo ./compat-tests/run.sh
   ```

2. Copy the **contents** of `tempo/` over this repo's working tree (the
   snapshot is byte-faithful to that tree at the gate-green commit; `tempo/`
   contents land at the repo root).
3. Review the diff in full, then commit and push.
4. Tag releases here (`v1.0.0`, …) on the snapshot commit.

The curated search index is a **separate** repo, `tmux-tempo-index`, and
follows the same manual copy-review-commit rhythm: its reviewed source lives
at `tools/tmux-tempo-index/` in the monorepo, and `search` reads it from
`https://raw.githubusercontent.com/kurioscreative/tmux-tempo-index/main/index.json`.
