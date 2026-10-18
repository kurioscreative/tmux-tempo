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
  static generation: the resolved plugin path, the live `@tpm_plugins`
  option value, and `mtime size path` for every config file consulted —
  including files that _didn't exist_, recorded as `m <path>`, so creating
  one later invalidates too.

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
  An observation that fails — tmux will not answer, or a config file cannot
  be read — raises `ObserverError` instead of yielding an empty set, and
  `CLI.run` rescues it exactly once (D34): every verb consults the declared
  set before it mutates, so refusing there refuses early.
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
  original (no `--depth`). Every operation runs in place in the plugin's own
  clone; `checkout` moves the current branch to the target commit
  (`checkout -B`) rather than detaching HEAD, and refuses rather than discard
  a conflicting local edit (D36).
- **`Commands`** ([`lib/tempo/commands.rb`](lib/tempo/commands.rb)) — one
  function per subcommand, output strings byte-compatible with the original
  (`"<name>" download success` etc.). Updates run in parallel threads with
  per-plugin atomic output. Clean is exact-match membership (licensed drop of
  the substring quirk) and never deletes the dir literally named `tpm`. Every
  mutating command ends in `finalize`: write the lockfile, regenerate the
  artifact — so the hot path always reflects disk and the lock reflects the
  run — the lock is an input to that write, and only what `update` moved is
  re-derived (D33). Every mutating command begins in `preflight`: git must
  run, the lock must parse, the declared set must be observable, each a
  refusal before anything is touched (D35). An `install` or `update` that
  finds nothing declared returns before `finalize`: no lock write, no
  regeneration.
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
- **`Lockfile`** ([`lib/tempo/lockfile.rb`](lib/tempo/lockfile.rb)) — below.

## Plugins on disk (D36)

Every plugin is a plain git clone at `<plugin-path>/<name>`, exactly where
tpm puts it — so a tree tpm (or a hand-run `git clone`) left behind is already
a tree tempo manages, with nothing to migrate. Every git operation runs in
place in that clone:

- **install** clones what is missing (`Git.clone_plugin`), then moves each
  installed plugin onto its locked commit with `Git.checkout`, retrying once
  after a `git fetch` when the commit is not local (never under `--frozen`).
- **update** runs `git pull` in the clone; its output is the `    |`
  indented report the compat contract pins.
- **install --frozen** proves every locked commit is already present
  (`git cat-file -e` in the clone, read-only) before it moves anything.

The data dir (`~/.local/share/tempo/`) holds only the two files the hot path
needs, `load.sh` and `fingerprint`. Undo for a bad update is the lockfile you
committed: restore the previous `tempo.lock` from your dotfiles repo and run
`install`, which puts every plugin back on the commits it names.

## The lockfile (S1.8, the new capability)

`tempo.lock` is JSON next to the primary config file, mapping plugin
name → `{url, branch, commit}`. The key design choice (D33): the lock is an
**input** to every write, never a snapshot. `Lockfile.write(env, refresh)`
carries the entry of every still-declared plugin over verbatim, observes an
entry only for a declared plugin the lock has never seen (freshly cloned, or
a clone tpm or a hand-run `git clone` left there), drops the entries of
plugins the same run just cleaned, and re-derives only the names in
`refresh` — the plugins `update` actually updated. So there is still no
remembered install-time state — the first time a plugin is seen, its entry
is read off disk (`git remote get-url` + HEAD) — but a pin is never
re-derived while the lock already has an answer, which is what lets a failed
clone, a failed restore or a plugin the observer could not see leave the
committed pin exactly where it was.
`install` = install missing + enforce locked commits + clean undeclared
(D32 — tpm's install could only do the first of those, having no lockfile to
enforce). Enforcement keeps the branch attached (D36): when HEAD is on a
branch, that branch is moved to the locked commit, so the next `update` —
a plain `git pull` — fast-forwards from there. A detached checkout would make
that pull fail with "not currently on a branch", turning every enforced
plugin into one `update` can no longer move. A clone that is already detached
stays detached, and a conflicting local edit makes the checkout refuse: that
is a `restore fail` with the pin unchanged, deliberately not a
`reset --hard` that would discard the edit. Only `update` moves a pin.
Legacy `@tpm_plugins` entries lock identically to `@plugin` entries — they
are the same after parsing.

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
- **No cross-config dedup, no tool-level undo** (D36): two plugin paths
  holding the same plugin hold two full clones, and tempo keeps no history of
  its own to step back through. Undo is the committed `tempo.lock` plus
  `install`, which needs the lock to be under version control and needs the
  network for any commit the clone no longer has.
