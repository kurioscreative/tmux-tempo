# How tempo works (Stage 1)

A walkthrough of the Stage 1 implementation, written against the code as of
2026-07-15. The contract itself lives in [`../docs/INTERFACE.md`](../docs/INTERFACE.md)
and the product decisions in [`../PRD.md`](../PRD.md); this document explains
how the ~1,700 lines in this directory realize them.

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
killed the hot path in an earlier iteration (see `../NOTES.md`).

## The management plane (Ruby, stdlib-only)

[`bin/tempo`](bin/tempo) is an sh shim that owns the Ruby ≥ 3.0 gate (D1: one
clear message, do nothing else), then execs `lib/tempo/main.rb`. The three
compat bins (`bin/install_plugins`, `bin/update_plugins`, `bin/clean_plugins`)
are thin wrappers over it at the paths the ecosystem hardcodes. The Ruby side
is seven small collaborators:

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
  mutating command ends in `finalize`: rewrite the lockfile, regenerate the
  artifact — so the hot path and lock always reflect disk.
- **`UI`** ([`lib/tempo/ui.rb`](lib/tempo/ui.rb)) — dual-mode output
  (stdout/stderr for CLI, `tmux run-shell "echo …"` for bindings) plus failure
  tracking: any `err` flips the exit code to 1, which is divergence 1 (the
  original lost failures in backgrounded subshells and always exited 0).
- **`Store`** ([`lib/tempo/store.rb`](lib/tempo/store.rb)) — below.
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
- **restore** flips to the entry holding the locked commit, and only builds
  that entry (staging clone + checkout, with the usual fetch retry unless
  `--frozen`) when it has never been filed.

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
still pulls it in place, restore still checks out in place. The hybrid layout
is supported indefinitely, not a migration deadline.

## The lockfile (S1.8, the new capability)

`tempo.lock` is JSON next to the primary config file, mapping plugin
name → `{url, branch, commit}`. The key design choice: it is a
**snapshot-from-disk** after every mutating op — entries come from
`git remote get-url` + HEAD of what's actually declared+installed, never from
remembered install-time state. There is no state to drift.
`sync` = install missing + enforce locked commits + clean undeclared, then
snapshots the now-enforced state, so it round-trips. `restore` is just the
locked-commits part. What it promises is the commit, not the shape of HEAD:
flipping onto an entry that was cloned lands on that entry's branch, while an
entry built by checkout is detached. `update` moves the lock forward. Legacy
`@tpm_plugins` entries lock identically to `@plugin`
entries — they are the same after parsing.

## The interactive UX (the subtle part)

tmux shows a `run-shell` job's captured stdout in its output view, and nested
`tmux run-shell "echo …"` clients _inherit_ that stdout. So the bindings are
choreographed around one rule: **never capture stdout in the banner/update
chain**. `Tmux.display_echo` uses `system` (not `capture2e`), and
[`bindings/update_plugins`](bindings/update_plugins) deliberately leaves
stdout unredirected while install/clean redirect it — matching the original's
exact UX on tmux ≥ 3. The first implementation captured somewhere in that
chain and all interactive output silently vanished (see `../DECISIONS.md`).

The `prefix+U` flow: reload environment → echo the installed-plugins banner
(divergence 3: `#branch`-pinned plugins now appear, because names are
branch-stripped before the installed check) → `command-prompt -p 'plugin
update:'` → empty input arrives as zero args and cancels silently; otherwise
the handler runs the same word-splitting path as the CLI, then reloads and
prints the `Done, press ESCAPE/ENTER to continue` message keyed off
`mode-keys`.

## What "Stage 1 done" means

Everything in S1.1–S1.8 is present: impersonation layout (clone to
`~/.tmux/plugins/tpm`, zero dotfile edits), all four intentional divergences
(real update exit codes; CLI default-path fallback; `#branch` in the update
list; non-executable warning), all six licensed drops (exact-match clean,
byte-sort, recursive source scan, normalized `$0`, clean exits, real version
compare), and the lockfile. The gate:

```sh
TPM_UNDER_TEST=../tempo ./compat-tests/run.sh   # 29 tests, one with a divergence note (update exit code)
ruby -Ilib -Itest test/run_all.rb               # tempo's own suite
```

## Known trade-offs

- **Per-user artifact, not per-plugin-path**: two configs alternating
  `TMUX_PLUGIN_MANAGER_PATH` under one `$HOME` regenerate on each switch —
  correct, just uncached.
- **Fingerprint granularity is mtime-seconds + size**: a same-second,
  same-size edit is theoretically invisible; any management op (or
  `bin/tempo generate`) forces regeneration.
- **Stale artifact + no Ruby runs the stale set silently** — a deliberate
  D1 mitigation, recorded in `../DECISIONS.md`.
- **Store entries are shared and writable** (D24): a plugin that caches
  inside its own directory shares that cache with every config linked to the
  same entry. Read-only entries would break such plugins outright, so
  immutability is a rule about git state that tempo obeys, not a permission
  bit. The escape hatch is the hybrid layout — a plugin kept as a real
  directory is never shared.
- **The store only grows.** Superseded entries stay filed; reclaiming them is
  generations' job (S2.2), not the store's.
