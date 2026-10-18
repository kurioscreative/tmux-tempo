# tempo

A drop-in replacement for [tpm](https://github.com/tmux-plugins/tpm), the
tmux plugin manager — same config lines, same key bindings, same install
path — plus the things tpm never grew: a **lockfile** for reproducible
plugin sets, **real exit codes**, a **`doctor`** command, and a startup hot
path that runs zero Ruby and zero network.

Your existing `.tmux.conf` does not change — same `@plugin` lines, same
`run` line, same keys. One behavior differs on purpose: `prefix` + `I`
reconciles against the lockfile instead of only adding. See
[Usage](#usage).

## Why tempo over tpm

Fair question — tpm is the original, it works, and it needs nothing but
bash and git. If that is all you want, keep it; your config will not care.
tempo exists for the day a plugin update breaks your setup, or a new
machine needs your exact plugin set back. What it adds and what it costs:

| What                        | tempo                                                         | tpm                                   | the honest cost                                                                                           |
| --------------------------- | ------------------------------------------------------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Config lines & key bindings | same `@plugin` lines, same `run` line, same keys              | —                                     | none: that is the point (what the keys _do_ is the row below)                                             |
| Reproducible plugin sets    | `tempo.lock` (exact commits), enforced by `install`           | no                                    | one more file to commit to your dotfiles                                                                  |
| Undo a bad update           | `rollback` — offline, instant, 10 generations kept            | re-clone by hand                      | a floor of superseded clones kept on disk per plugin (bounded, then reclaimed)                            |
| Failure reporting           | real exit codes, `doctor`, `status`                           | exit 0 no matter what                 | a script that relied on tpm always exiting 0 needs a look                                                 |
| `prefix + I` semantics      | reconciles: adds, enforces the lock, removes undeclared       | adds only — it has no lock to enforce | **the one binding that behaves differently**: a plugin you updated by hand goes back to its locked commit |
| Declaring plugins           | `add`, `remove` from the CLI                                  | edit the config by hand               | none: the config file is still the manifest, and hand-editing still works                                 |
| Runtime dependencies        | sh + git, **Ruby ≥ 3.0 for management operations**            | bash + git only                       | the Ruby dependency is real; tpm's absence of it is a genuine tpm advantage                               |
| Startup (every reload)      | executes one pregenerated `sh` artifact                       | re-parses config, re-queries tmux     | tempo's parsing cost moves to config-change time and is paid in Ruby (below)                              |
| Field history               | new in 2026, pinned to tpm by a 30-test held-out compat suite | the original, ~a decade in the wild   | maturity favors tpm; the compat suite is the mitigation, not a substitute                                 |

### Measured

Median of 12 runs each, 10 minimal local plugins, Apple Silicon macOS
(arm64), tmux 3.7b, Ruby 3.4.5, 2026-08. Produced by
`tools/bench-tpm-comparison.sh` in the development monorepo, which runs
both managers against identical offline sandboxes with the vendored
original tpm as the comparator, and prints every raw sample alongside the
median — re-run it rather than trusting this table.

| Moment                       | tempo   | tpm     | reading                                                                                         |
| ---------------------------- | ------- | ------- | ----------------------------------------------------------------------------------------------- |
| steady-state reload          | 197 ms  | 205 ms  | effectively a tie at this plugin count — the plugins themselves dominate both (see below)       |
| reload after a config change | 369 ms  | 195 ms  | **tpm wins this moment**: tempo regenerates its artifact in Ruby, ~170 ms, once per config edit |
| cold install of 10 plugins   | 1951 ms | 1209 ms | **tpm wins this moment**: tempo spends ~0.7 s filing the store, lockfile and generation         |

Read the reload row for what it is, not as a speedup: roughly 180 ms of
both medians is the ten plugins themselves running, identically under
either manager. The difference is what the manager's own slice is made
of. tpm re-derives the plugin list every reload — shell out to tmux,
`awk` over the config — so its overhead grows with config complexity and
runs code at every startup. tempo's steady-state overhead is a freshness
check (a few `stat` calls, two tmux queries) plus one generated
straight-line `sh` file: no parsing, no Ruby, no network, whatever your
config looks like. The deferred cost surfaces in the other two rows, and
they are tpm wins: tempo's install and config-change moments pay for the
lockfile, the store and rollback. If you reload rarely and never want
the lockfile or `rollback`, that trade is against you — use tpm.

## Requirements

- **tmux ≥ 1.9** — same floor as tpm.
- **git** — used for all plugin installs and updates.
- **Ruby ≥ 3.0** (standard library only; no gems, no bundler) — needed only
  for management operations (install / update / clean). Loading
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
  `~/.tmux/plugins/tpm` is **renamed aside** to `~/.tmux/tpm.orig-<timestamp>`, and
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
mode: your old tpm clone is renamed to `~/.tmux/tpm.orig-<timestamp>`
(kept, not deleted — the migration is reversible) and the tpm path is
symlinked at the tempo checkout. No `rm -rf`, no config edits.

Your already-installed plugins under `~/.tmux/plugins/` are adopted in
place — the first `prefix + I` reports them as `Already installed` and
records them in `tempo.lock`. No plugin re-downloads.

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

Same keys as tpm, overridable via `@tpm-install`, `@tpm-update`,
`@tpm-clean`:

- `prefix` + `I` — install missing, put installed plugins on their locked
  commits, remove undeclared ones (see below — this is the one binding whose
  behavior differs from tpm's)
- `prefix` + `U` — update plugins (prompts: a name, or `all`)
- `prefix` + `alt` + `u` — remove plugins no longer in the config

The same operations — and the new ones — are available from a shell:

```
~/.tmux/plugins/tpm/bin/tempo <command>

  init         wire this checkout into your tmux setup
  install      install missing + enforce the lock + clean undeclared
               (--frozen: enforce the lock offline, never write it)
  add <spec>   declare a plugin in your config, then install it
  remove       delete a plugin's declaration from your config
  update all   update plugins (parallel)
  clean        remove undeclared plugin dirs
  rollback     undo the last operation (rollback N: go to generation N)
  status       declared plugins, lock state and generation history
  generate     regenerate the loader artifact
  doctor       check requirements, paths and artifact health
```

**`install` reconciles — it is not tpm's additive install.** tpm could only
ever clone what was missing, because a directory's existence was the only
desired state it had. tempo has a lockfile, so `install` means what it means
in npm, bundler and poetry: clone what is missing, put installed plugins back
on their locked commits, and remove ones your config no longer declares.
Pressing `prefix` + `I` after cloning your dotfiles onto a new machine
reproduces your exact locked set.

Two consequences worth knowing. A plugin you updated by hand outside tempo is
moved back to its locked commit — `update` is what moves the lock forward. And
if your config declares **no** plugins, `install` and `update` deliberately
change nothing at all: no clean, no `tempo.lock` write, no generation. An
empty reading nearly always means tmux read a different config than you
edited, or could not be asked at all, and erasing every pin over that is as
wrong as deleting every plugin. `tempo clean` still removes them when you
mean it.

### Adding and removing plugins

`tempo add` writes the declaration for you and installs it:

```
$ tempo add tmux-plugins/tmux-yank
Added to /Users/you/.tmux.conf: set -g @plugin 'tmux-plugins/tmux-yank'
Backed up /Users/you/.tmux.conf -> /Users/you/.tmux.conf.bak-20260815-114500
Installing "tmux-yank"
  "tmux-yank" download success
```

It appends exactly one line — tempo's one canonical declaration form — and
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
the result as a new entry, then flips the link; `install` flips it back to
the locked commit.
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
  install/update, and only when the directory is a faithful
  checkout of its remote: no uncommitted or untracked files, and a HEAD some
  remote branch contains. Anything else keeps its real directory, keeps
  working exactly as before, and says so on every install and update:

  ```
    "tmux-menus" kept as a plain directory: uncommitted changes (outside rollback's reach; commit or stash them to make it adoptable)
  ```

  That is a notice, not an error — the command still succeeds. To adopt such
  a plugin later, commit or discard the local changes and run any mutating
  command again.

Old entries are reclaimed by generations (below), so the store does not grow
without bound.

### Generations and rollback

Every operation that changes what is installed — `install`, `update`, `clean`,
and the `prefix + I` / `prefix + U` bindings — first files a
**generation**: the lockfile exactly as it stood, plus which store entry each
plugin pointed at. Filing one is cheap (a few hundred bytes; the plugins are
already in the store), so the previous state is always still there. The one
exception is an install or update that finds no plugins declared: it changes
nothing, so it files nothing.

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
  (`"tmux-fzf" is declared but not in generation 4; run install`).
- **It does not touch plugins kept as plain directories** (adoption declined,
  above) — there is no second copy of those to flip to, so they are reported
  and left alone.

The last **10** generations are kept. That number is a constant, not a
setting. When a generation ages out, any store entry that no remaining
generation references — and that no plugin currently links to — is deleted
with it. That is what keeps `~/.local/share/tempo/store/` from growing
forever.

### The lockfile

`tempo.lock` (JSON: plugin → url, branch, commit) sits next to your real
config file, and `install` reads it before it acts: it never rewrites the pin
of a plugin you still declare, it only adds entries for plugins it just
installed and drops entries for plugins you removed from your config.
`update` is what moves a pin forward. So on a new machine, after cloning your
dotfiles and this repo, `bin/tempo install` reproduces the exact locked
plugin set — same commits, not just same plugins — and an install that fails
partway (offline, upstream gone) leaves your committed pins exactly as they
were.

#### `--frozen`

`install --frozen` is the `cargo --locked` posture,
for CI and for machines where a surprise download is not acceptable. It
never touches the network and never writes `tempo.lock`. Before changing
anything it checks that every declared plugin is installed, is in the
lockfile, and has its locked commit already in its local clone. If any of
those fails it prints **every** offending plugin and exits 1 having changed
nothing — no partial enforcement of a lock that cannot be satisfied. It also
exits 1 when it finds no plugins declared at all: a gate that passes having
verified nothing is not a gate.

```
$ bin/tempo install --frozen
frozen: lockfile not satisfied
  "tmux-sensible" not installed
  "tmux-yank" locked commit a1b2c3d4e5f6 missing locally
```

The fix is a plain `bin/tempo install`, which is allowed to download.

Unrecognized flags are a usage error everywhere — `--frozen` on `update`
included, since updating is a network operation by definition — so a typo
fails loudly instead of being quietly ignored.

## Security

Installing a tmux plugin means running someone else's code with your
privileges, and tempo does not sandbox it. Nothing prompts you before an
install either (THREAT-MODEL.md explains why). The lockfile is the real defense — it pins exact
commits, `install --frozen` refuses to move off them, and every change shows up
in your dotfiles diff. What that does and does not protect against is spelled
out in [THREAT-MODEL.md](THREAT-MODEL.md); to report a vulnerability in tempo
itself, see [SECURITY.md](SECURITY.md).

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
  candidates it checked). Your installed plugins are safe: `install`
  deliberately skips its clean step when nothing is declared, precisely
  because this case is usually a config tmux never read.
- **"git is not usable: …"** — `git --version` failed, and the line after
  the colon is git's own explanation (on macOS, often an Xcode license that
  has not been accepted). tempo refuses before doing anything, because
  without git every clone would fail and every installed plugin would look
  missing. Fix git, then run the command again.
- **"tempo.lock … cannot be parsed"** — the lockfile exists but is not
  valid JSON, most often merge-conflict markers after pulling dotfiles from
  another machine. tempo refuses rather than overwrite it with a fresh
  snapshot: resolve the conflict by hand, or `tempo rollback` to restore
  the last lock tempo recorded.
- **"cannot determine the declared plugin set"** — tmux would not answer
  (not in `PATH`, or no server could be started) or a config file could not
  be read. tempo refuses rather than treat an unanswered question as "no
  plugins": nothing is installed, removed, or written, and the previous
  loader stays in place. `status` still reports; `doctor` names the cause.
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
  mv ~/.tmux/tpm.orig-<timestamp> ~/.tmux/plugins/tpm
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
which is what makes updates and rollbacks link flips. `install` and `update`
are the only commands that touch the network at all — starting tmux never
does, and neither does anything else. The full walkthrough —
hot path, management plane, the store, lockfile semantics, and the five
intentional divergences from tpm (a reconciling `install`, real exit codes,
visible non-executable-file warnings, and two smaller ones) — is in
[ARCHITECTURE.md](ARCHITECTURE.md).

## License

MIT — see [LICENSE](LICENSE). Security reports go through
[SECURITY.md](SECURITY.md).

## For maintainers: publishing

This repo's history is a deterministic subtree split of the `tempo/`
directory of the development monorepo (which also holds the tpm compat
suite and the vendored original): every monorepo commit that touched
`tempo/`, re-rooted so its contents sit at this repo's root. Publishing is
still a deliberate act — a script builds and verifies the split locally,
and pushing is a separate explicit step:

1. In the monorepo, run all three gates and make sure they are green. Each
   harness isolates its own tmux server, plugin path and data dir, so they
   are safe to run from inside a live tmux session:

   ```sh
   (cd tempo && ruby -Ilib -Itest test/run_all.rb)
   sh tempo/test/flows/run_flows.sh
   TPM_UNDER_TEST=./tempo ./compat-tests/run.sh
   ```

2. `sh tools/publish-tempo.sh` (in the monorepo) — splits, maps author
   identities to the public handle, verifies the published tree is
   byte-identical to `tempo/` at HEAD, and lists the commits that would
   go out.
3. Review that list, then `sh tools/publish-tempo.sh --push`. Re-running
   on extended history fast-forwards; the push refuses to clobber unseen
   remote work.
4. Tag releases here (`v1.0.0`, …) on the published commit.

Consequence to respect: because history is published, anything ever
committed under `tempo/` is published forever — commits touching `tempo/`
must be publishable as written, messages included.
