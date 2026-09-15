# How tempo works

A walkthrough of the implementation. The tpm compatibility contract this code
is written against, the product decisions behind it (referenced below as
D<n>), and the decision and notes logs live in the development monorepo this
repository is snapshotted from; this document explains how the code here
realizes them.

The whole thing is split into two planes: a **POSIX-sh hot path** that tmux
runs on every server start (never touches Ruby), and a **Ruby management
plane** that only runs when you install/update/clean.

## The core idea: static generation (D2)

tempo never "loads plugins" at startup the way tpm does (scraping config with
bash+awk every time). Instead, Ruby acts as a _compiler_: it scans your tmux
config once and emits two files into `~/.local/share/tempo/`:

- **`load.sh`** — the artifact: a straight-line sh script with one
  `run_plugin_dir '<path>/'` call per declared plugin
  (`lib/tempo/generator.rb`). The runner function inside it encodes the entire
  contract execution model: glob top-level `*.tmux` files, byte-sort with
  `LC_ALL=C`, run each _as an executable_ with output discarded, `|| :` so one
  broken plugin never stops the rest, plus the divergence-4 stderr warning for
  non-executable files.
- **`fingerprint`** — a line-oriented record of everything that fed the
  generation: the resolved plugin path, the live `@tpm_plugins` option value,
  and `mtime size path` for every config file consulted — including files that
  _didn't exist_, recorded as `m <path>`, so creating one later invalidates
  too.

Compat is a property of the artifact, not the generator: the compat suite
cannot tell the architecture changed because the `run` line sits in the same
place in the user's config and the artifact re-executes on every reload.

## The hot path (every tmux start)

Your config's `run '~/.tmux/plugins/tpm/tpm'` hits the argument-less
[`tpm`](tpm) entry script, which does four cheap things: gate on tmux ≥ 1.9
(real numeric comparison, same outcome as the original's digit-concat hack —
a licensed drop), publish `TMUX_PLUGIN_MANAGER_PATH` as a tmux **global
environment variable** only-if-unset, install the three key bindings
(`prefix+I/U/M-u`, each overridable via `@tpm-install` / `@tpm-update` /
`@tpm-clean`), then hand off to
[`scripts/source_plugins.sh`](scripts/source_plugins.sh) — the decision point:

```
artifact fresh?   → run load.sh                     (zero Ruby, zero network — steady state)
stale + Ruby OK   → bin/tempo generate, run load.sh (~100ms Ruby, still no network)
stale + no Ruby   → run the STALE artifact anyway   (a previously working set beats nothing)
missing + no Ruby → one gate message on stderr, load nothing
```

Always `exit 0` — a broken plugin set must never break config loading
(a tpm guarantee since v1.1.0).

The freshness check (`artifact_fresh` in
[`scripts/helpers.sh`](scripts/helpers.sh)) is pure sh: it re-reads the
fingerprint and fails on _any_ mismatch or any line it doesn't recognize —
the bias is "when in doubt, regenerate," because regeneration is cheap and a
wrong plugin set isn't. The `_stat_mtime_size` helper probes both GNU and BSD
`stat` dialects and only accepts output shaped like two integers — GNU
`stat -f` _succeeds_ in filesystem mode with garbage output, which silently
killed the hot path in an earlier iteration.

## The management plane (Ruby, stdlib-only)

[`bin/tempo`](bin/tempo) is an sh shim that owns the Ruby ≥ 3.0 gate (D1: one
clear message, do nothing else), then execs `lib/tempo/main.rb`. The three
compat bins (`bin/install_plugins`, `bin/update_plugins`, `bin/clean_plugins`)
are thin wrappers over it at the paths the ecosystem hardcodes. The Ruby side
is a set of small collaborators — the load-bearing ones:

- **`Env`** ([`lib/tempo/env.rb`](lib/tempo/env.rb)) — resolves all machine
  state: plugin path (tmux global env var, `~`/`$HOME` expanded, trailing
  slash forced; falls back to the XDG-aware default when unset — divergence 2,
  the fix that makes the documented auto-install snippet finally work on a
  fresh machine), the config-file candidate list (the full set tmux itself
  loads — a strict superset of tpm's either/or rule), and the ordered spec
  list: legacy `@tpm_plugins` first, then scraped `@plugin` lines, duplicates
  preserved like the original. Every value is constructor-overridable so tests
  never need tmux.
- **`Scraper`** ([`lib/tempo/scraper.rb`](lib/tempo/scraper.rb)) — regexes
  matching the original awk matcher exactly (deliberately _no_ word boundary
  after `@plugin`, because the original matches `@plugins` too and accepting
  less than the original is the only real breakage), recursive
  `source`/`source-file` following (superset of tpm's one level), and a
  fingerprint entry for every path it touches — including the parent dir of
  any sourced glob, since a glob can gain matches without any scanned file
  changing.
- **`Spec`** ([`lib/tempo/spec.rb`](lib/tempo/spec.rb)) — the riskiest line in
  the whole project per the PRD: `#branch` is stripped first, then
  name = basename minus one trailing `.git`. Getting this wrong makes every
  existing installation "disappear."
- **`Git`** ([`lib/tempo/git.rb`](lib/tempo/git.rb)) — verbatim URL tried
  first, GitHub `git::@` shorthand expansion only on failure;
  `GIT_TERMINAL_PROMPT=0` everywhere so nothing can ever block on a credential
  prompt (a hang here wedges tmux's `run-shell`). Full-history clones like the
  original (no `--depth`).
- **`Commands`** ([`lib/tempo/commands.rb`](lib/tempo/commands.rb)) — one
  function per subcommand, output strings byte-compatible with the original
  (`"<name>" download success` etc.). Updates run in parallel threads with
  per-plugin atomic output. Clean is exact-match membership (licensed drop of
  the substring quirk) and never deletes the dir literally named `tpm`. Every
  mutating command ends in `finalize`: write the lockfile, regenerate the
  artifact — so the hot path always reflects disk and the lock reflects the
  run — the lock is an input to that write, and only what `update` moved is
  re-derived (D33). An `install` or `update` that finds nothing declared
  returns before `finalize`: no lock write, no regeneration, no generation.
- **`ConfigEdit`** ([`lib/tempo/config_edit.rb`](lib/tempo/config_edit.rb)) —
  the only code that writes the user's tmux config (D22), behind `tempo add`
  and `tempo remove`. `add` appends the one canonical `@plugin` serialization;
  `remove` deletes a declaration only when it can parse the whole line, and
  otherwise refuses with the exact `file:line` and "remove it by hand" —
  `@tpm_plugins` membership, `%if` blocks and sourced files are always
  refusals. It is the deliberate counterweight to the Non-Goals ban on a
  manifest: the config _is_ the plugin list, so editing it must be
  conservative enough to never mangle a hand-tuned file. Writes go through a
  timestamped `.bak-` copy, and through a symlinked conf rather than over it.
- **`UI`** ([`lib/tempo/ui.rb`](lib/tempo/ui.rb)) — dual-mode output
  (stdout/stderr for CLI, `tmux run-shell "echo …"` for bindings) plus failure
  tracking: any `err` flips the exit code to 1, which is divergence 1 (the
  original lost failures in backgrounded subshells and always exited 0).
- **`Store`** ([`lib/tempo/store.rb`](lib/tempo/store.rb)) — below.
- **`Generations`** ([`lib/tempo/generations.rb`](lib/tempo/generations.rb)) —
  below.
- **`Lockfile`** ([`lib/tempo/lockfile.rb`](lib/tempo/lockfile.rb)) — below.

## The plugin store (S2.1, D24)

`<plugin-path>/<name>` is a symlink. The clone lives at
`$XDG_DATA_HOME/tempo/store/<sha256(url)>/<commit>/`, so a plugin is stored
once per `(url, commit)` no matter how many configs or names want it. The URL
is never recovered by inverting the digest — it is read back from the entry's
own `origin` remote, which is also what the lockfile reads through the link.

One invariant carries the design: **tempo never runs a mutating git command
inside a filed entry.** Concretely:

- **install** clones into a staging dir under the store root, reads the commit
  the clone actually landed on (unknowable before it lands), renames staging
  into place — same filesystem, so atomic — and links.
- **update** local-clones the current entry into staging (git hardlinks the
  object database, so this is nearly free), points `origin` back at the real
  upstream, and pulls **there**. That pull's own output is the `   |`
  indented report the compat contract pins, so the report stays real git
  output rather than a reconstruction. The result is filed as a _new_ entry
  and the link flips; a pull landing on an already-filed commit files nothing.
- **install**'s lock-enforcement step flips to the entry holding the locked
  commit, and only builds that entry (staging clone + checkout, with the usual
  fetch retry unless `--frozen`) when it has never been filed.

Every flip is symlink-at-a-temp-name plus `rename`, never unlink-then-link:
a tmux server starting mid-flip must never find a missing plugin directory.
The hot path needs no regeneration for a flip, because the artifact bakes
plugin-path strings and globs `*.tmux` at runtime (see above) — it never
learns the store exists.

**Adoption** is lazy and clean-only. A real directory left by tpm, an older
tempo, or a hand-run `git clone` is moved into the store on the first mutating
op, but only when the work tree is clean (untracked files included — adoption
_shares_ whatever it moves) and HEAD is contained in a remote-tracking branch.
Anything else keeps its real directory, warns once, and keeps working: update
still pulls it in place, lock enforcement still checks out in place. The hybrid layout
is supported indefinitely, not a migration deadline.

## Generations and rollback (S2.2, D25)

A generation is the pair that fully describes "which plugins are live": the
lockfile bytes, and which store entry each declared plugin's symlink pointed
at. Both live under `<data_dir>/generations/`:

```
current            the number the plugin path is standing on
<N>/manifest.json  {version, op, time, links:{name=>entry}, unmanaged:[…]}
<N>/tempo.lock     a byte copy of the lockfile as it stood
```

`manifest.json` is written last, so a crash mid-file leaves a directory that
`Generations.numbers` simply does not count. Every mutating command files one:
`install`/`update`/`clean` through `Commands.finalize` (after the lock
write — the generation snapshots the bytes that call produced), and
`install --frozen` directly, since it bypasses `finalize` and never writes the
lock. Its generation records the _enforced_ state carrying whatever lock
content it was handed, which is exactly what rolling back to it should
reproduce. The exception is a run that mutates nothing: `install`, `update`
and `install --frozen` all return early when no plugin is declared (D33), so
there is no state change to file — and `--frozen` exits 1 doing so, because a
CI gate must not pass vacuously.

This is only affordable because of the store: a generation does not copy
plugins, it records entry paths, so filing one costs a few hundred bytes and
rolling back costs a `rename` per plugin.

`rollback [N]` — bare means the generation below `current` — flips each link
with the same temp-symlink-plus-`rename` the store uses, restores the stored
lock bytes (**not** a re-snapshot of disk: `Lockfile.write` would produce the
same content today, but restoring stored bytes is the honest semantic and
immune to future drift), regenerates the artifact, and moves the marker.
Rolling back files nothing, so a second rollback walks further down instead of
ping-ponging. Two deliberate non-actions: it never edits `tmux.conf`, so a
plugin declared after the target generation is _reported_ rather than
invented; and a plugin kept as a plain directory (adoption declined) is
recorded `unmanaged` and left alone, because there is no second copy to flip
to.

Retention is the constant **10** — no flag, no env var, no config. Pruning and
store GC ride every new generation, which is what finally bounds the store D24
left growing. GC deletes a store entry only when no kept generation references
it **and** no live plugin-path symlink resolves into it; the second half
matters, because the entry you are standing on can be older than the oldest
kept generation.

## The lockfile (S1.8, the new capability)

`tempo.lock` is JSON next to the primary config file, mapping plugin
name → `{url, branch, commit}`. The key design choice (D33): the lock is an
**input** to every write, never a snapshot. `Lockfile.write(env, refresh)`
carries the entry of every still-declared plugin over verbatim, observes an
entry only for a declared plugin the lock has never seen (freshly cloned, or
a pre-existing directory it adopted), drops the entries of plugins the same
run just cleaned, and re-derives only the names in `refresh` — the plugins
`update` actually updated. So there is still no remembered install-time
state — the first time a plugin is seen, its entry is read off disk (`git
remote get-url` + HEAD) — but a pin is never re-derived while the lock
already has an answer, which is what lets a failed clone, a failed restore
or a plugin the observer could not see leave the committed pin exactly where
it was.
`install` = install missing + enforce locked commits + clean undeclared
(D32 — tpm's install could only do the first of those, having no lockfile to
enforce). What enforcement promises is the commit, not the shape of HEAD:
flipping onto an entry that was cloned lands on that entry's branch, while an
entry built by checkout is detached. Only `update` (and `rollback`) moves a
pin. Legacy `@tpm_plugins` entries lock identically to `@plugin`
entries — they are the same after parsing.

## The interactive UX (the subtle part)

tmux shows a `run-shell` job's captured stdout in its output view, and nested
`tmux run-shell "echo …"` clients _inherit_ that stdout. So the bindings are
choreographed around one rule: **never capture stdout in the banner/update
chain**. `Tmux.display_echo` uses `system` (not `capture2e`), and
[`bindings/update_plugins`](bindings/update_plugins) deliberately leaves
stdout unredirected while install/clean redirect it — matching the original's
exact UX on tmux ≥ 3. The first implementation captured somewhere in that
chain and all interactive output silently vanished.

The `prefix+U` flow: reload environment → echo the installed-plugins banner
(divergence 3: `#branch`-pinned plugins now appear, because names are
branch-stripped before the installed check) → `command-prompt -p 'plugin
update:'` → empty input arrives as zero args and cancels silently; otherwise
the handler runs the same word-splitting path as the CLI, then reloads and
prints the `Done, press ESCAPE/ENTER to continue` message keyed off
`mode-keys`.

## What "Stage 1 done" means

Everything in S1.1–S1.8 is present: impersonation layout (clone to
`~/.tmux/plugins/tpm`, zero dotfile edits), all five intentional divergences
(real update exit codes; CLI default-path fallback; `#branch` in the update
list; non-executable warning; a reconciling `install`, D32), all six licensed
drops (exact-match clean,
byte-sort, recursive source scan, normalized `$0`, clean exits, real version
compare), and the lockfile. The gate:

```sh
ruby -Ilib -Itest test/run_all.rb   # tempo's own suite, ships here
sh test/flows/run_flows.sh          # end-to-end flows, ships here
```

The third gate — the held-out tpm compatibility suite (30 tests, two carrying
divergence notes: the update exit code and the reconciling `install`) — runs
against this tree from the
development monorepo, where the suite and the vendored original live. It is
deliberately not vendored here: a parity suite you can edit alongside the
implementation has stopped being a held-out test.

## Known trade-offs

- **Per-user artifact, not per-plugin-path**: two configs alternating
  `TMUX_PLUGIN_MANAGER_PATH` under one `$HOME` regenerate on each switch —
  correct, just uncached.
- **Fingerprint granularity is mtime-seconds + size**: a same-second,
  same-size edit is theoretically invisible; any management op (or
  `bin/tempo generate`) forces regeneration.
- **Stale artifact + no Ruby runs the stale set silently** — a deliberate
  D1 mitigation.
- **Store entries are shared and writable** (D24): a plugin that caches
  inside its own directory shares that cache with every config linked to the
  same entry. Read-only entries would break such plugins outright, so
  immutability is a rule about git state that tempo obeys, not a permission
  bit. The escape hatch is the hybrid layout — a plugin kept as a real
  directory is never shared.
- **Reclaiming store entries is generations' job, not the store's.** The store
  itself never deletes; entries go only when the last generation referencing
  them is pruned (10 back) and nothing links them. So a box that never runs a
  mutating op never reclaims — correct, and the same "regeneration is cheap,
  a wrong state isn't" bias as the fingerprint.
