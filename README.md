# tempo

A drop-in replacement for [tpm](https://github.com/tmux-plugins/tpm), the
tmux plugin manager: same `@plugin` lines, same `run` line, same key
bindings, same install path. On top of that, the things tpm never grew: a
**lockfile** that makes your plugin set reproducible, **real exit codes**, a
**`doctor`** command, and a tmux startup that runs no Ruby and touches no
network.

Your `.tmux.conf` does not change. One behavior differs on purpose:
`prefix` + `I` reconciles your plugins against the lockfile instead of only
adding to them. See [Usage](#usage).

## Why tempo over tpm

tpm is the original, it works, and it needs nothing but bash and git. If
that is all you want, keep it; your config will not care. tempo exists for
the day a plugin update breaks your setup, or a new machine needs your exact
plugin set back. What it adds, and what each addition costs:

| What                        | tempo                                                         | tpm                                   | the honest cost                                                                                          |
| --------------------------- | ------------------------------------------------------------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Config lines & key bindings | same `@plugin` lines, same `run` line, same keys              | the same                              | none: that is the point (what the keys _do_ is the row below)                                            |
| Reproducible plugin sets    | `tempo.lock` (exact commits), enforced by `install`           | no                                    | one more file to commit to your dotfiles                                                                 |
| Undo a bad update           | revert `tempo.lock` in your dotfiles, then `install`          | re-clone by hand                      | needs the lock committed; offline only while the old commit is still in the plugin's clone               |
| Failure reporting           | real exit codes, `doctor`, `status`                           | exit 0 no matter what                 | a script that relied on tpm always exiting 0 needs a look                                                |
| `prefix` + `I` semantics    | reconciles: adds, enforces the lock, removes undeclared       | adds only: it has no lock to enforce  | **the one binding that behaves differently**: a plugin you updated by hand goes back to its locked commit |
| Declaring plugins           | `add` and `remove` from the CLI                               | edit the config by hand               | none: the config file is still the plugin list, and hand-editing still works                             |
| Runtime dependencies        | sh + git, **Ruby ≥ 3.0 for the management commands**          | bash + git only                       | the Ruby dependency is real; tpm's lack of it is a genuine tpm advantage                                 |
| Startup (every reload)      | runs one pregenerated `sh` artifact                           | re-parses config, re-queries tmux     | tempo's parsing cost moves to config-change time and is paid in Ruby (below)                             |
| Field history               | new in 2026, held to tpm by a 30-test held-out compat suite   | the original, about a decade in use   | maturity favors tpm; the compat suite is the mitigation, not a substitute                                |

### Measured

Median of 12 runs each, 10 minimal local plugins, Apple Silicon macOS
(arm64), tmux 3.7b, Ruby 3.4.5, 2026-08. Produced by
`tools/bench-tpm-comparison.sh` in the development monorepo, which runs
both managers against identical offline sandboxes with the vendored
original tpm as the comparator and prints every raw sample beside the
median. Re-run it rather than trusting this table. **These numbers predate
plugins becoming plain clones** (an earlier design kept an extra copy of
each one) and are pending re-measurement.

| Moment                       | tempo   | tpm     | reading                                                                                                                  |
| ---------------------------- | ------- | ------- | ------------------------------------------------------------------------------------------------------------------------ |
| steady-state reload          | 197 ms  | 205 ms  | effectively a tie at this plugin count: the plugins themselves dominate both (see below)                                 |
| reload after a config change | 369 ms  | 195 ms  | **tpm wins this moment**: tempo regenerates its artifact in Ruby, about 170 ms, once per config edit                      |
| cold install of 10 plugins   | 1951 ms | 1209 ms | **tpm wins this moment**: tempo spent about 0.7 s more, measured when every install still made a second copy (see above) |

Read the reload row for what it is, not as a speedup. Roughly 180 ms of
both medians is the ten plugins themselves running, identically under
either manager. The difference is what the manager's own slice is made of.
tpm re-derives the plugin list on every reload (shell out to tmux, `awk`
over the config), so its overhead grows with config complexity and runs code
at every startup. tempo's steady-state overhead is a freshness check (a few
`stat` calls, two tmux queries) plus one generated straight-line `sh` file:
no parsing, no Ruby, no network, whatever your config looks like. The
deferred cost surfaces in the other two rows, and they are tpm wins:
tempo's install and config-change moments pay for the lockfile and the
artifact. If you reload rarely and never want the lockfile, that trade is
against you. Use tpm.

## Requirements

- **tmux ≥ 1.9**, the same floor as tpm.
- **git**, for every clone and update.
- **Ruby ≥ 3.0** (standard library only; no gems, no bundler), needed only
  for the management commands (`install`, `update`, `clean`, `add`, and so
  on). Loading already-installed plugins at tmux startup does **not** need
  Ruby: startup runs a pregenerated `sh` artifact. macOS note: the
  deprecated system Ruby 2.6 is not enough; install a current Ruby through
  Homebrew or a version manager.

Not sure what you have? After cloning, run `bin/tempo doctor` from the
checkout (see [Troubleshooting](#troubleshooting)).

## Install

Clone the repo anywhere you like, then let `tempo init` wire it in:

```sh
git clone https://github.com/kurioscreative/tmux-tempo.git ~/.tmux/plugins/tempo-src
cd ~/.tmux/plugins/tempo-src
bin/tempo init
```

The path is yours to choose: `~/.tmux/plugins/tempo-src`,
`~/src/tmux-tempo`, a stow package, anywhere. `init` records where the
checkout actually is.

`init` **wires, it never installs**: no network, no git clones, no running
tmux required. It reads your tmux config files (`~/.tmux.conf`, the XDG
`~/.config/tmux/tmux.conf`, system configs), looks at their `run` and
`run-shell` lines, and picks one of two modes:

- **Drop-in mode**: your config already has a `run '~/.tmux/plugins/tpm/tpm'`
  line, so you are a tpm user. Whatever currently occupies
  `~/.tmux/plugins/tpm` is **renamed aside** to
  `~/.tmux/tpm.orig-<timestamp>`, and `~/.tmux/plugins/tpm` becomes a
  symlink to your checkout. **Your tmux config is not modified at all**: the
  existing run line now resolves into tempo.
- **Fresh mode**: no tpm run line found. `init` symlinks `tempo` inside the
  default plugin path (`~/.tmux/plugins/tempo`, or
  `~/.config/tmux/plugins/tempo` if your config is the XDG one) at your
  checkout and appends `run '~/.tmux/plugins/tempo/tempo'` to your tmux
  config. An existing config is copied to `<conf>.bak-<timestamp>` first;
  if you have no config at all, a minimal one is created (a commented
  `@plugin` example plus the run line). An already-present run line is not
  duplicated.

Before touching anything, `init` prints its full plan (every rename,
symlink and config write, with final paths) and, when run interactively,
asks `Proceed? [y/N]`. Answering no aborts with nothing changed. Pass
`--yes` (or `-y`) to skip the prompt; non-interactive runs (scripts,
provisioning) proceed without asking.

If a run line already resolves into this checkout, `init` prints
`Already set up` and does nothing: it is idempotent and safe to re-run. In
fresh mode, if the `tempo` link target already exists as a real directory
or as a symlink to something else, `init` **refuses**: exit 1, nothing
touched.

Then declare plugins in your tmux config, the standard tpm block,
unchanged:

```tmux
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'

# keep this line at the very bottom of tmux.conf
run '~/.tmux/plugins/tempo/tempo'
```

Reload tmux (`tmux source ~/.tmux.conf`) and press **`prefix` + `I`**
(capital i) to install the declared plugins. A `tempo.lock` file appears
next to your config file. Commit it to your dotfiles.

`bin/tempo` in this README is the script inside the checkout. After
drop-in mode it is also reachable as `~/.tmux/plugins/tpm/bin/tempo`, and
after fresh mode as `~/.tmux/plugins/tempo/bin/tempo`.

### Alternative: clone straight to the tpm path

`init` is optional. You can still clone this repo where the tmux ecosystem
hardcodes the plugin manager (yes, the directory is named `tpm`: every
dotfiles snippet in the wild points there, and tempo impersonates that
layout on purpose):

```sh
git clone https://github.com/kurioscreative/tmux-tempo.git ~/.tmux/plugins/tpm
```

with the usual `run '~/.tmux/plugins/tpm/tpm'` line at the bottom of your
config. Nothing else changes; the two layouts behave identically.

Installing into a symlinked directory (`~/.tmux/plugins/tpm` pointing at a
checkout elsewhere, as dotfiles managers like stow do) is supported and
tested. It is exactly the shape `init` creates.

## Migrating

**From tpm**: clone and run `init`. That is the whole migration.

```sh
git clone https://github.com/kurioscreative/tmux-tempo.git ~/.tmux/plugins/tempo-src
~/.tmux/plugins/tempo-src/bin/tempo init
```

`init` detects your existing `run '~/.tmux/plugins/tpm/tpm'` line and
takes drop-in mode: your old tpm clone is renamed to
`~/.tmux/tpm.orig-<timestamp>` (kept, not deleted, so the migration is
reversible) and the tpm path is symlinked at the tempo checkout. No
`rm -rf`, no config edits.

Your already-installed plugins under `~/.tmux/plugins/` are plain git
clones, and tempo uses them in place, exactly as tpm left them. The first
`prefix` + `I` reports them as `Already installed` and records their current
commits in `tempo.lock`. Nothing is re-downloaded.

**From manual `run-shell` lines**: if your config loads plugins directly
(say `run-shell ~/clones/tmux-resurrect/resurrect.tmux`), switch each line
to a declaration and let tempo own the clone:

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
```

Then `prefix` + `I`. Plugin options (`set -g @resurrect-*` and friends) stay
exactly where they are. Once installed, delete your manual clones.

If your config file is a **symlink** into a dotfiles repo, the lockfile is
written next to the real file: inside the repo, where you can commit it.

## Usage

Same keys as tpm, overridable via `@tpm-install`, `@tpm-update` and
`@tpm-clean`:

- `prefix` + `I`: install missing plugins, put installed ones on their locked
  commits, remove undeclared ones (see below; this is the one binding whose
  behavior differs from tpm's)
- `prefix` + `U`: update plugins (prompts for a name, or `all`)
- `prefix` + `alt` + `u`: remove plugins no longer in the config

The same operations, and the new ones, are available from a shell:

```
bin/tempo <command>

  init [--yes]            wire this checkout into your tmux setup
  install [--frozen]      install missing + enforce the lock + clean undeclared
                          (--frozen: enforce the lock offline, never write it)
  add <spec>...           declare one or more plugins in your config, then install
  remove <name-or-spec>   delete a plugin's declaration from your config
  update all|<name>...    update plugins (parallel)
  clean                   remove undeclared plugin dirs
  status                  declared plugins and their lock state
  generate                regenerate the artifact
  doctor                  check requirements, paths and artifact health
```

**`install` reconciles; it is not tpm's additive install.** tpm could only
ever clone what was missing, because a directory's existence was the only
desired state it had. tempo has a lockfile, so `install` means what it means
in npm, bundler and poetry: clone what is missing, put installed plugins
back on their locked commits, and remove the ones your config no longer
declares. Pressing `prefix` + `I` after cloning your dotfiles onto a new
machine reproduces your exact locked set.

That is the whole workflow, and `install` is the only verb in it you run
routinely: `install` (or `prefix` + `I`) to get what the lock says, `update`
when you want newer code, and a reverted `tempo.lock` plus `install` to undo.
There is no second install mode to learn; `--frozen` below exists for one
unusual kind of host and is not part of the everyday path.

Two consequences worth knowing. A plugin you updated by hand outside tempo
is moved back to its locked commit; `update` is what moves the lock
forward. And if your config declares **no** plugins, `install` deliberately
skips its clean step, and neither it nor `update` writes `tempo.lock` or
regenerates the artifact. An empty
reading nearly always means tmux read a different config than the one you
edited, and erasing every pin over that is as wrong as deleting every
plugin. `tempo clean` still removes them when you mean it.

### Adding and removing plugins

`tempo add` writes the declaration for you and installs it:

```
$ tempo add tmux-plugins/tmux-yank
Added to /Users/you/.tmux.conf: set -g @plugin 'tmux-plugins/tmux-yank'
Backed up /Users/you/.tmux.conf -> /Users/you/.tmux.conf.bak-20260815-114500
Installing "tmux-yank"
  "tmux-yank" download success
```

It appends exactly one line per plugin, tempo's one canonical declaration
form, and copies your config to a timestamped `.bak-` file first. A
symlinked config (dotfiles setups) is written _through_: the link survives
and the file in your repo is what changes. Adding a plugin you already
declare, in any quote form, changes nothing and says where it is already
declared.

`tempo remove <name>` deletes the declaration again:

```
$ tempo remove tmux-yank
Removed /Users/you/.tmux.conf:12: set -g @plugin 'tmux-plugins/tmux-yank'
Its files are still installed — run `tempo clean` to delete them.
```

It only ever deletes a whole line it can fully parse, in your primary
config (the XDG config if it exists, else `~/.tmux.conf`). Anything else it
refuses, names, and leaves alone:

```
$ tempo remove tmux-foo
tempo remove: refusing to edit this declaration
  /Users/you/.tmux.conf:8: set -g @tpm_plugins "tmux-foo tmux-bar"
      the legacy @tpm_plugins list is never edited by tempo — remove it by hand.
```

The same refusal covers a declaration inside a `%if` block, one in a file
your config `source-file`s, and one written in a form tempo cannot parse
whole. Your config is your file: a manager that guesses at a hand-tuned
line is worse than one that tells you exactly which line to edit. Nothing
is changed on a refusal, not even a backup.

The old gesture still works, of course: delete (or comment out) the
`@plugin` line by hand, then `prefix` + `alt` + `u`.

### The lockfile

`tempo.lock` (JSON: plugin name to url, branch, commit) sits next to your
real config file, and `install` reads it before it acts. It never rewrites
the pin of a plugin you still declare; it only adds entries for plugins it
just installed and drops entries for plugins you removed from your config.
`update` is what moves a pin forward. So on a new machine, after cloning
your dotfiles and this repo, `bin/tempo install` reproduces the exact
locked plugin set, same commits and not just same plugins, and an install
that fails partway (offline, upstream gone) leaves your committed pins
exactly as they were.

When `install` moves a plugin back to its pin it prints
`"<name>" restored to <commit>`. When it cannot, because you have edited
the plugin's files in a way the checkout would clobber, or because upstream
no longer has that commit, it prints a line that names the way out:

```
  "tmux-yank" restore fail: locked commit a1b2c3d4e5f6 unavailable (`tempo update tmux-yank` moves the pin)
```

The pin stays where it was, so this recurs on every install until you
either fix the clone or move the pin.

#### Undoing a bad update

`prefix` + `U` broke something? The undo is your dotfiles history, not a
tempo command, and it assumes `tempo.lock` is committed there. Put the
previous lock back, then install:

```sh
cd ~/dotfiles                      # wherever tempo.lock is committed
git checkout HEAD~1 -- tempo.lock  # or `git restore tempo.lock` if uncommitted
~/.tmux/plugins/tpm/bin/tempo install   # or prefix + I
```

`install` moves each plugin back to its locked commit. The plugin stays on
its branch, so the next `update` pulls normally. No network is needed as
long as the old commit is still in the plugin's clone, and a normal
`git pull` keeps old commits. `tempo doctor` says so if the lockfile is not
tracked by git, because then this undo does not exist.

#### Checking the lock in CI

The question CI should ask is "does the committed lock fully describe this
config?" Plain `install` answers it: run it on a clean checkout, then fail
the job if it changed the lock.

```sh
~/.tmux/plugins/tpm/bin/tempo install
git diff --exit-code tempo.lock
```

A declared plugin that was never locked gets a fresh pin on that run, and
a lock that was edited by hand gets re-serialized, so either shows up as a
diff. No flag is needed, and this works on a machine that starts with no
plugins at all.

#### `--frozen` (exceptional)

`install --frozen` is for one kind of host: one that already has its clones
and must never download anything, such as an air-gapped or change-controlled
machine. You do not need it otherwise, and it is not a substitute for the
CI check above: its first complaint is `not installed`, so it cannot run on
a fresh machine, and once plain `install` has run, any gap in the lock has
already been filled in.

What it does: never touches the network and never writes `tempo.lock`.
Before changing anything it checks that every declared plugin is installed,
is in the lockfile, and has its locked commit already in its local clone.
If any of those fails it prints **every** offending plugin and exits 1
having changed nothing: no partial enforcement of a lock that cannot be
satisfied. It also exits 1 when it finds no plugins declared at all, because
a check that passes having verified nothing has verified nothing.

```
$ bin/tempo install --frozen
frozen: lockfile not satisfied
  "tmux-sensible" not installed
  "tmux-yank" locked commit a1b2c3d4e5f6 missing locally
```

The fix is a plain `bin/tempo install`, which is allowed to download.

Unrecognized flags are a usage error everywhere, `--frozen` on `update`
included, since updating is a network operation by definition. A typo
fails loudly instead of being quietly ignored.

### Plugins that need files of their own

Some plugins look for your files inside their own directory: tmux-resurrect
finds restore strategies in its `strategies/` folder, for example. tempo
leaves untracked files in a plugin's clone alone, but they exist only on
that machine; a fresh clone anywhere else will not have them. To make such
a file part of your setup, commit it to a fork on a branch of its own and
declare that branch:

```tmux
set -g @plugin 'you/tmux-resurrect#my-strategy'
```

To pick up upstream changes later, **merge** upstream into that branch and
push, then `tempo update tmux-resurrect`. Do not rebase it: a rebased branch
has to be force-pushed, and `update` is a plain `git pull`, which cannot
fast-forward over a force-push.

## Security

Installing a tmux plugin means running someone else's code with your
privileges, and tempo does not sandbox it. Nothing prompts you before an
install either; [THREAT-MODEL.md](THREAT-MODEL.md) explains why. The
lockfile is the real defense: it pins exact commits, `install` puts every
plugin back on them, and every change shows up in your dotfiles diff.
What that does and does not protect against is spelled out in
THREAT-MODEL.md; to report a vulnerability in tempo itself, see
[SECURITY.md](SECURITY.md).

## Troubleshooting

`bin/tempo doctor` prints one line per fact that matters: tmux and Ruby
versions against their gates, git, the resolved plugin path and its
writability, which config files were found, declared versus installed
plugin counts, artifact freshness, and the lockfile's location, whether it
parses, and whether git tracks it. It exits non-zero only when a hard
requirement (tmux ≥ 1.9, git, a readable plugin set) is missing, so it is
scriptable.

Common first-run cases it (or the command's own output) explains:

- **"No plugins declared"**: your config has no `@plugin` lines, or tmux
  is reading a different config file than you edited (doctor lists the
  candidates it checked). Your installed plugins are safe: `install`
  deliberately skips its clean step when nothing is declared, precisely
  because this case is usually a config tmux never read.
- **"git is not usable: …"**: `git --version` failed, and the text after
  the colon is git's own explanation (on macOS, often an Xcode license that
  has not been accepted). `install`, `update`, `clean` and `add` refuse
  before doing anything, because without git every clone would fail and
  every installed plugin would look missing. Fix git, then run the command
  again.
- **"tempo.lock … cannot be parsed"** or **"… is not a tempo lockfile"**:
  the lockfile exists but is not valid JSON of the right shape, most often
  merge-conflict markers after pulling dotfiles from another machine. tempo
  refuses rather than overwrite it: resolve it by hand, or restore it from
  your dotfiles history.
- **"cannot determine the declared plugin set"**: tmux would not answer
  (not in `PATH`, or no server could be started) or a config file could not
  be read. tempo refuses rather than treat an unanswered question as "no
  plugins": nothing is installed, removed, or written, and the previous
  artifact stays in place. `status` still reports; `doctor` names the
  cause.
- **"tempo requires Ruby >= 3.0"**: the management commands are gated; see
  [Requirements](#requirements). Already-installed plugins keep loading
  without Ruby.

## Uninstall

Remove the link `init` made, the generated state, and the checkout itself;
your plugins and config are untouched:

```sh
rm -rf ~/.tmux/plugins/tpm ~/.local/share/tempo   # ~/.tmux/plugins/tempo after fresh mode
rm -rf ~/.tmux/plugins/tempo-src                  # or wherever you cloned
```

**Reversing `tempo init`**: both modes are reversible, and `init` left you
the pieces.

- **Drop-in mode**: delete the symlink and put the saved tpm clone back.
  Your config never changed, so it goes back to running tpm.

  ```sh
  rm ~/.tmux/plugins/tpm
  mv ~/.tmux/tpm.orig-<timestamp> ~/.tmux/plugins/tpm
  ```

- **Fresh mode**: delete the symlink and drop the run line `init` appended
  (or put the whole config back from `<conf>.bak-<timestamp>`).

  ```sh
  rm ~/.tmux/plugins/tempo
  # then delete the `run '~/.tmux/plugins/tempo/tempo'` line from your config
  ```

`tempo clean` never deletes the manager's own checkout, whatever it happens
to be named: the guard resolves real paths, so a checkout symlinked in as
`tempo`, `tpm`, or anything else is safe from it.

To stop using plugins entirely, also remove the `@plugin` and `run` lines
from your tmux config and delete `~/.tmux/plugins/`, `tempo.lock`, and
`~/.local/share/tempo/`. The last of these holds only the generated
artifact (`load.sh`) and its freshness fingerprint; the plugin clones
themselves live in `~/.tmux/plugins/`.

## How it works

Short version: Ruby is a _compiler_, not a runtime. The management
commands scan your config once and emit a straight-line `sh` artifact plus
a freshness fingerprint into `~/.local/share/tempo/`; every tmux server
start just runs that artifact. Plugins themselves are plain git clones at
`~/.tmux/plugins/<name>`, exactly as under tpm, and every git operation
runs in place in them. `install` and `update` are the only commands that
touch the network at all; starting tmux never does, and neither does
anything else. The full walkthrough (hot path, management plane, lockfile
semantics, and the five intentional divergences from tpm: a reconciling
`install`, real exit codes, a visible warning for non-executable plugin
files, and two smaller ones) is in [ARCHITECTURE.md](ARCHITECTURE.md).

## License

MIT, see [LICENSE](LICENSE). Security reports go through
[SECURITY.md](SECURITY.md).

## For maintainers: publishing

This repo's history is a deterministic subtree split of the `tempo/`
directory of the development monorepo (which also holds the tpm compat
suite and the vendored original): every monorepo commit that touched
`tempo/`, re-rooted so its contents sit at this repo's root. Publishing is
still a deliberate act. A script builds and verifies the split locally,
and pushing is a separate explicit step:

1. In the monorepo, run all three gates and make sure they are green. Each
   harness isolates its own tmux server, plugin path and data dir, so they
   are safe to run from inside a live tmux session:

   ```sh
   (cd tempo && ruby -Ilib -Itest test/run_all.rb)
   sh tempo/test/flows/run_flows.sh
   TPM_UNDER_TEST=./tempo ./compat-tests/run.sh
   ```

2. `sh tools/publish-tempo.sh` (in the monorepo) splits, verifies the
   published tree is byte-identical to `tempo/` at HEAD, and lists the
   commits that would go out. If the split would not fast-forward the
   public branch it says so and counts the published commits a push
   would replace.
3. Review that list, then `sh tools/publish-tempo.sh --push`. Re-running
   on extended history fast-forwards.
4. Tag releases here (`v1.0.0`, …) on the published commit.

Consequence to respect: because history is published, anything ever
committed under `tempo/` is published forever, commit messages included.
