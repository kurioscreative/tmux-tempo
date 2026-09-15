#!/bin/sh
# Install-flow suite: end-to-end first-install scenarios for tempo, run
# against a copy of this source tree placed where dotfiles expect it
# (~/.tmux/plugins/tpm). POSIX sh — invoked as `sh tempo/test/flows/run_flows.sh`.
#
# Sandboxing mirrors the compat suite's approach (fresh $HOME, private
# $TMUX_TMPDIR so bare `tmux` calls never reach the developer's server,
# local git fixture repos) but is reimplemented here: compat-tests/ is the
# held-out contract gate and must not be sourced or edited.

set -u

FLOWS_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPO_SRC="$(cd "$FLOWS_DIR/../.." && pwd)"
# System temp dir, NOT a project path: the tmux socket lives inside the
# sandbox and macOS caps socket paths at 104 bytes.
SANDBOX_ROOT="${TMPDIR:-/tmp}"

PASS=0
FAIL=0
TEST_RC=0

# --- sandbox lifecycle -------------------------------------------------------

setup_sandbox() {
	SANDBOX="$(mktemp -d "$SANDBOX_ROOT/tempo-flow.XXXXXX")"
	HOME="$SANDBOX/home"; export HOME
	TMUX_TMPDIR="$SANDBOX/sock"; export TMUX_TMPDIR
	mkdir -p "$HOME" "$TMUX_TMPDIR"
	# TMUX_PLUGIN_MANAGER_PATH is the one that bites: a shell inside tmux
	# inherits it, a sandbox server seeds its global env from this shell, and
	# the manager under test then resolves the OPERATOR'S real plugins dir and
	# cleans it (NOTES 2026-08-16). Isolation is established here, by
	# construction, not by a prefix the operator has to remember.
	unset TMUX TMUX_PANE TMUX_PLUGIN_MANAGER_PATH XDG_CONFIG_HOME XDG_DATA_HOME
	TERM=xterm-256color; export TERM
	PLUGINS_DIR="$HOME/.tmux/plugins"
	FIXTURES="$SANDBOX/fixtures"
	make_fixture_repo "tmux-example-plugin"
}

teardown_sandbox() {
	tmux kill-server 2>/dev/null # sandbox server only: TMUX_TMPDIR is set
	rm -rf "$SANDBOX"
}

# --- fixtures ----------------------------------------------------------------

fixgit() {
	_d="$1"; shift
	git -C "$_d" -c user.name=tempo-test -c user.email=tempo-test@example.com \
		-c commit.gpgsign=false "$@"
}

# A local git repo usable as a plugin source (specs are tried verbatim as
# git URLs, so local paths clone offline).
make_fixture_repo() {
	_dir="$FIXTURES/$1"
	mkdir -p "$_dir"
	git -C "$_dir" init -q -b master
	# Logs its own $0: that is how a plugin finds its siblings, so it is also
	# how a flow proves the store is reached through the *logical* path.
	printf '#!/bin/sh\necho "$0" >> "$HOME/plugins_ran.log"\n' > "$_dir/$1.tmux"
	chmod +x "$_dir/$1.tmux"
	fixgit "$_dir" add -A
	fixgit "$_dir" commit -qm init
}

# Place a copy of the tempo source tree at $1 (the impersonation layout:
# $1 becomes the dir dotfiles' `run '~/.tmux/plugins/tpm/tpm'` points into).
install_tempo_copy() {
	mkdir -p "$(dirname "$1")"
	cp -R "$TEMPO_SRC" "$1"
}

write_conf() {
	cat > "$HOME/.tmux.conf"
}

# A PATH with everything the sh entry points need — except ruby. Same
# minimal-PATH trick as the NOTES.md stat-dialect investigation.
ruby_free_path() {
	_shim="$SANDBOX/noruby-bin"
	mkdir -p "$_shim"
	for _t in dirname sed grep sort cut stat uname tmux git mktemp; do
		_p="$(command -v "$_t" 2>/dev/null)" && ln -s "$_p" "$_shim/$_t"
	done
	printf '%s\n' "$_shim"
}

# A `git` that is the real git except for the three subcommands that reach
# the network — those log the call and exit 99. Prepending it to PATH proves
# offline-ness from outside the Ruby, which no in-process assertion can.
# tempo always invokes git as `git <sub> …` or `git -C <dir> <sub> …`, so the
# subcommand is $1 or $3; matching those exactly avoids false hits on paths.
make_git_shim() {
	FLOW_SHIM_BIN="$SANDBOX/frozen-bin"
	FLOW_NETWORK_LOG="$SANDBOX/network.log"
	FLOW_REAL_GIT="$(command -v git)"
	export FLOW_NETWORK_LOG FLOW_REAL_GIT
	mkdir -p "$FLOW_SHIM_BIN"
	cat > "$FLOW_SHIM_BIN/git" <<'SHIM'
#!/bin/sh
for _a in "$1" "${3:-}"; do
	case "$_a" in
		clone|fetch|pull) printf '%s\n' "$*" >> "$FLOW_NETWORK_LOG"; exit 99 ;;
	esac
done
exec "$FLOW_REAL_GIT" "$@"
SHIM
	chmod +x "$FLOW_SHIM_BIN/git"
}

assert_no_network() {
	[ ! -f "$FLOW_NETWORK_LOG" ] || {
		fail "$1 reached the network"
		sed 's/^/      | git /' "$FLOW_NETWORK_LOG"
	}
}

# --- tmux lifecycle ----------------------------------------------------------

# Starts the sandbox server; tpm's run-shell bootstrap is asynchronous, so
# wait until it has published TMUX_PLUGIN_MANAGER_PATH before returning.
start_tmux() {
	tmux new-session -d -x 80 -y 24
	_i=0
	while [ "$_i" -lt 50 ]; do
		tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH >/dev/null 2>&1 && return 0
		sleep 0.1
		_i=$((_i + 1))
	done
	fail "tpm never published TMUX_PLUGIN_MANAGER_PATH"
	return 1
}

# --- assertions --------------------------------------------------------------

# Re-source the config so the run-shell bootstrap fires again, then wait for
# the plugin's own log line. Cheaper and safer than cycling the server.
reload_and_wait_for_plugins() {
	rm -f "$HOME/plugins_ran.log"
	tmux source-file "$HOME/.tmux.conf" 2>/dev/null
	_i=0
	while [ "$_i" -lt 50 ] && [ ! -f "$HOME/plugins_ran.log" ]; do
		sleep 0.1
		_i=$((_i + 1))
	done
}

assert_store_link() {
	[ -L "$1" ] || { fail "expected a symlink into the store: $1"; return 1; }
	case "$(readlink "$1")" in
		"$HOME/.local/share/tempo/store"/*) : ;;
		*) fail "symlink does not point into the store: $(readlink "$1")" ;;
	esac
}

fail() {
	echo "    FAIL: $1"
	TEST_RC=1
	return 1
}

assert_contains() {
	case "$1" in
		*"$2"*) : ;;
		*) fail "expected output to contain '$2'"; printf '%s\n' "$1" | sed 's/^/      | /' ;;
	esac
}

assert_not_contains() {
	case "$1" in
		*"$2"*) fail "expected output NOT to contain '$2'" ;;
		*) : ;;
	esac
}

assert_dir() {
	[ -d "$1" ] || fail "expected directory: $1"
}

assert_file() {
	[ -f "$1" ] || fail "expected file: $1"
}

# --- flows -------------------------------------------------------------------

# Fresh machine: clone-layout copy at ~/.tmux/plugins/tpm, one declared
# plugin, server start, then the CLI install everyone's dotfiles snippet
# calls. Must clone, write the lock next to the conf, and generate the
# hot-path artifact.
flow_fresh_install() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	run '~/.tmux/plugins/tpm/tpm'
	EOF
	start_tmux || return 1
	out="$("$PLUGINS_DIR/tpm/bin/install_plugins" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "install_plugins exited $rc"
	assert_contains "$out" '"tmux-example-plugin" download success'
	assert_dir "$PLUGINS_DIR/tmux-example-plugin/.git"
	assert_file "$HOME/tempo.lock"
	assert_file "$HOME/.local/share/tempo/load.sh"
}

# Migration: a plugins tree that an earlier manager (or manual clones)
# already populated. tempo must adopt it — "Already installed", no
# re-clone — and snapshot it into a fresh lockfile.
flow_migration_existing_tree() {
	mkdir -p "$PLUGINS_DIR"
	git clone -q "$FIXTURES/tmux-example-plugin" "$PLUGINS_DIR/tmux-example-plugin"
	install_tempo_copy "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	run '~/.tmux/plugins/tpm/tpm'
	EOF
	start_tmux || return 1
	out="$("$PLUGINS_DIR/tpm/bin/install_plugins" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "install_plugins exited $rc"
	assert_contains "$out" 'Already installed "tmux-example-plugin"'
	assert_file "$HOME/tempo.lock"
	grep -q "tmux-example-plugin" "$HOME/tempo.lock" || fail "lockfile missing adopted plugin"
}

# ~/.tmux/plugins/tpm as a symlink to the real checkout (dotfiles-manager
# setups). The entry script's dirname-$0 resolution must survive it.
flow_symlinked_install_dir() {
	install_tempo_copy "$SANDBOX/tempo-real"
	mkdir -p "$PLUGINS_DIR"
	ln -s "$SANDBOX/tempo-real" "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	run '~/.tmux/plugins/tpm/tpm'
	EOF
	start_tmux || return 1
	out="$("$PLUGINS_DIR/tpm/bin/install_plugins" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "install_plugins exited $rc"
	assert_contains "$out" '"tmux-example-plugin" download success'
	assert_dir "$PLUGINS_DIR/tmux-example-plugin/.git"
}

# bin/tempo reached through a PATH-style symlink (~/.local/bin/tempo).
# ROOT must resolve the file's own link chain — one absolute and one
# relative link cover both target forms — while the install dir itself
# stays logical (the previous flow pins that half).
flow_cli_via_path_symlink() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	touch "$HOME/.tmux.conf"
	mkdir -p "$SANDBOX/bin"
	ln -s "../home/.tmux/plugins/tpm/bin/tempo" "$SANDBOX/bin/tempo-rel"
	ln -s "$SANDBOX/bin/tempo-rel" "$SANDBOX/bin/tempo"
	out="$("$SANDBOX/bin/tempo" doctor 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || { fail "doctor via PATH symlink exited $rc"; printf '%s\n' "$out" | sed 's/^/      | /'; }
	assert_contains "$out" "ruby"
}

# No usable Ruby: the sh gate must print one clear message to stderr and
# exit 1 without doing anything else.
flow_no_ruby_gate() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	err="$(PATH="$(ruby_free_path)" "$PLUGINS_DIR/tpm/bin/tempo" install 2>&1 >/dev/null)"
	rc=$?
	[ "$rc" -eq 1 ] || fail "expected exit 1 from the ruby gate, got $rc"
	assert_contains "$err" "tempo requires Ruby >= 3.0"
}

# Doctor on an unhealthy box (ruby hidden) must exit 1 — the gate fires
# before Ruby ever runs, same posture as every other subcommand.
flow_doctor_no_ruby_exits_1() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	PATH="$(ruby_free_path)" "$PLUGINS_DIR/tpm/bin/tempo" doctor >/dev/null 2>&1
	rc=$?
	[ "$rc" -eq 1 ] || fail "expected doctor to exit 1 without ruby, got $rc"
}

# Doctor on a healthy sandbox: exit 0 and report the key facts.
flow_doctor_healthy() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	touch "$HOME/.tmux.conf"
	out="$("$PLUGINS_DIR/tpm/bin/tempo" doctor 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "doctor exited $rc"
	assert_contains "$out" "tmux"
	assert_contains "$out" "ruby"
	assert_contains "$out" "lockfile"
}

# A tmux that will not answer must not read as "nothing declared" (D34):
# every verb refuses before touching anything, status still reports, and a
# stale-artifact regenerate keeps the previous loader.
flow_observer_failure_changes_nothing() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	EOF
	"$PLUGINS_DIR/tpm/bin/tempo" install >/dev/null 2>&1 || fail "seed install failed"
	cp "$HOME/tempo.lock" "$SANDBOX/lock.before"
	cp "$HOME/.local/share/tempo/load.sh" "$SANDBOX/load.before"
	mute="$SANDBOX/mute-tmux-bin"
	mkdir -p "$mute"
	printf '#!/bin/sh\nexit 1\n' > "$mute/tmux"
	chmod +x "$mute/tmux"

	out="$(PATH="$mute:$PATH" "$PLUGINS_DIR/tpm/bin/tempo" install 2>&1)"
	rc=$?
	[ "$rc" -eq 1 ] || fail "install with a mute tmux exited $rc"
	assert_contains "$out" "cannot determine the declared plugin set"
	assert_contains "$out" "nothing was changed"
	cmp -s "$HOME/tempo.lock" "$SANDBOX/lock.before" || fail "a failed observation rewrote the lockfile"
	assert_dir "$PLUGINS_DIR/tmux-example-plugin"
	[ "$(cat "$HOME/.local/share/tempo/generations/current")" = "1" ] || fail "a failed observation moved the generation marker"

	printf '# edit\n' >> "$HOME/.tmux.conf" # stale fingerprint: the hot path would regenerate
	PATH="$mute:$PATH" "$PLUGINS_DIR/tpm/bin/tempo" generate >/dev/null 2>&1 && fail "generate succeeded with a mute tmux"
	cmp -s "$HOME/.local/share/tempo/load.sh" "$SANDBOX/load.before" || fail "a failed observation replaced the artifact"

	out="$(PATH="$mute:$PATH" "$PLUGINS_DIR/tpm/bin/tempo" status 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "status with a mute tmux exited $rc"
	assert_contains "$out" "plugins could not be determined"
}

# Zero plugins declared: install must guide the user toward @plugin.
flow_zero_plugin_guidance() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	touch "$HOME/.tmux.conf"
	out="$("$PLUGINS_DIR/tpm/bin/install_plugins" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "install_plugins exited $rc"
	assert_contains "$out" "@plugin"
	assert_contains "$out" "No plugins declared"
	# An empty observation writes nothing (D33): no empty lock in the dotfiles,
	# no "0 plugin(s)" generation.
	[ ! -e "$HOME/tempo.lock" ] || fail "zero-plugin install wrote a lockfile"
	[ ! -d "$HOME/.local/share/tempo/generations" ] || fail "zero-plugin install filed a generation"
}

# Negative guard for the contract output API: with a plugin declared, the
# guidance must NOT appear.
flow_declared_plugin_suppresses_guidance() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	EOF
	out="$("$PLUGINS_DIR/tpm/bin/install_plugins" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "install_plugins exited $rc"
	assert_contains "$out" '"tmux-example-plugin" download success'
	assert_not_contains "$out" "No plugins declared"
}

# Fresh-mode init from a checkout cloned anywhere: init writes the conf's
# run line and the canonical symlink, then a real server must boot through
# the whole new chain (run line → tempo alias → tpm entry →
# TMUX_PLUGIN_MANAGER_PATH published) and install the declared plugin.
flow_init_fresh() {
	install_tempo_copy "$SANDBOX/checkout"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	EOF
	"$SANDBOX/checkout/bin/tempo" init --yes >/dev/null 2>&1
	rc=$?
	[ "$rc" -eq 0 ] || fail "init exited $rc"
	grep -q "run '~/.tmux/plugins/tempo/tempo'" "$HOME/.tmux.conf" || fail "run line missing from conf"
	[ -L "$PLUGINS_DIR/tempo" ] || fail "manager symlink missing"
	start_tmux || return 1
	out="$("$PLUGINS_DIR/tempo/bin/install_plugins" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "install_plugins exited $rc"
	assert_contains "$out" '"tmux-example-plugin" download success'
	assert_dir "$PLUGINS_DIR/tmux-example-plugin/.git"
}

# Drop-in init over a tpm-style sandbox: original backed up, tpm path now a
# symlink into the checkout, conf byte-identical — and the untouched conf
# still boots a working server that installs through the tpm path.
flow_init_drop_in() {
	install_tempo_copy "$SANDBOX/checkout"
	mkdir -p "$PLUGINS_DIR/tpm"
	touch "$PLUGINS_DIR/tpm/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	run '~/.tmux/plugins/tpm/tpm'
	EOF
	cp "$HOME/.tmux.conf" "$SANDBOX/conf.before"
	"$SANDBOX/checkout/bin/tempo" init >/dev/null 2>&1
	rc=$?
	[ "$rc" -eq 0 ] || fail "init exited $rc"
	cmp -s "$HOME/.tmux.conf" "$SANDBOX/conf.before" || fail "drop-in mode changed the conf"
	[ -L "$PLUGINS_DIR/tpm" ] || fail "tpm path is not a symlink"
	ls -d "$PLUGINS_DIR/"tpm.orig* >/dev/null 2>&1 || fail "original tpm not backed up"
	start_tmux || return 1
	out="$("$PLUGINS_DIR/tpm/bin/install_plugins" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "install_plugins exited $rc"
	assert_contains "$out" '"tmux-example-plugin" download success'
}

# Clean after a fresh init must remove orphans but never the manager's own
# symlink — its name is "tempo", so the literal tpm guard alone won't save it.
flow_clean_after_fresh_init() {
	install_tempo_copy "$SANDBOX/checkout"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	EOF
	"$SANDBOX/checkout/bin/tempo" init >/dev/null 2>&1 || fail "init failed"
	start_tmux || return 1
	"$PLUGINS_DIR/tempo/bin/install_plugins" >/dev/null 2>&1
	mkdir -p "$PLUGINS_DIR/tmux-orphan"
	out="$("$PLUGINS_DIR/tempo/bin/tempo" clean 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "clean exited $rc"
	[ ! -d "$PLUGINS_DIR/tmux-orphan" ] || fail "orphan survived clean"
	[ -L "$PLUGINS_DIR/tempo" ] || fail "clean removed the manager's own symlink"
	assert_not_contains "$out" 'Removing "tempo"'
}

# The CI gesture: dotfiles are checked out with a committed tempo.lock and
# the plugins already at their locked commits. `install --frozen` must enforce
# that state and exit 0 without a single network call, and without
# rewriting the lock it was handed.
flow_frozen_install_offline() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	EOF
	"$PLUGINS_DIR/tpm/bin/tempo" install >/dev/null 2>&1 || fail "seed install failed"
	cp "$HOME/tempo.lock" "$SANDBOX/lock.before"
	make_git_shim

	out="$(PATH="$FLOW_SHIM_BIN:$PATH" "$PLUGINS_DIR/tpm/bin/tempo" install --frozen 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || { fail "install --frozen exited $rc"; printf '%s\n' "$out" | sed 's/^/      | /'; }
	assert_no_network "install --frozen"
	cmp -s "$HOME/tempo.lock" "$SANDBOX/lock.before" || fail "frozen rewrote the lockfile"
	assert_file "$HOME/.local/share/tempo/load.sh"
}

# The same box with one plugin missing: frozen must refuse, name it, and
# stay offline even on the failure path — no opportunistic re-clone.
flow_frozen_violation_stays_offline() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	EOF
	"$PLUGINS_DIR/tpm/bin/tempo" install >/dev/null 2>&1 || fail "seed install failed"
	cp "$HOME/tempo.lock" "$SANDBOX/lock.before"
	rm -rf "$PLUGINS_DIR/tmux-example-plugin"
	make_git_shim

	out="$(PATH="$FLOW_SHIM_BIN:$PATH" "$PLUGINS_DIR/tpm/bin/tempo" install --frozen 2>&1)"
	rc=$?
	[ "$rc" -eq 1 ] || fail "expected exit 1 from a violating frozen install, got $rc"
	assert_contains "$out" "tmux-example-plugin"
	assert_no_network "a violating install --frozen"
	[ ! -d "$PLUGINS_DIR/tmux-example-plugin" ] || fail "frozen re-installed a missing plugin"
	cmp -s "$HOME/tempo.lock" "$SANDBOX/lock.before" || fail "a failed frozen run rewrote the lockfile"
}

# Store-backed install, end to end: the plugin path entry is a symlink into
# the XDG store, and a real tmux server runs the plugin *through* it — with the
# logical, unresolved path in $0, which is how plugins locate their own files.
flow_store_backed_install_runs_through_the_symlink() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	run '~/.tmux/plugins/tpm/tpm'
	EOF
	start_tmux || return 1
	out="$("$PLUGINS_DIR/tpm/bin/install_plugins" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "install_plugins exited $rc"
	assert_contains "$out" '"tmux-example-plugin" download success'
	assert_store_link "$PLUGINS_DIR/tmux-example-plugin"
	assert_dir "$PLUGINS_DIR/tmux-example-plugin/.git"

	reload_and_wait_for_plugins
	assert_file "$HOME/plugins_ran.log"
	grep -q "plugins/tmux-example-plugin/tmux-example-plugin.tmux" "$HOME/plugins_ran.log" ||
		{ fail "plugin did not run through the logical plugin-path"; \
			sed 's/^/      | /' "$HOME/plugins_ran.log"; }
}

# Adoption under the store: a plugins tree an earlier manager (or a manual
# clone) populated is taken over on the first mutating op — the real directory
# becomes a symlink into the store at the *same* commit — and the server still
# boots and runs the plugin afterwards.
flow_store_adopts_existing_flat_clone() {
	mkdir -p "$PLUGINS_DIR"
	git clone -q "$FIXTURES/tmux-example-plugin" "$PLUGINS_DIR/tmux-example-plugin"
	before="$(git -C "$PLUGINS_DIR/tmux-example-plugin" rev-parse HEAD)"
	[ -L "$PLUGINS_DIR/tmux-example-plugin" ] && fail "fixture should start as a real dir"
	install_tempo_copy "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	run '~/.tmux/plugins/tpm/tpm'
	EOF
	start_tmux || return 1
	out="$("$PLUGINS_DIR/tpm/bin/tempo" install 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || { fail "install exited $rc"; printf '%s\n' "$out" | sed 's/^/      | /'; }

	assert_store_link "$PLUGINS_DIR/tmux-example-plugin"
	after="$(git -C "$PLUGINS_DIR/tmux-example-plugin" rev-parse HEAD)"
	[ "$before" = "$after" ] || fail "adoption moved HEAD: $before -> $after"

	reload_and_wait_for_plugins
	assert_file "$HOME/plugins_ran.log"
}

# Rollback, judged by what actually runs. The fixture's `*.tmux` prints a
# version marker, so a real tmux server executing it after the rollback is the
# only assertion that cannot be faked by a lock-only revert: the plugin must
# emit its PRE-update line again.
flow_rollback_reverts_plugin_content() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	_repo="$FIXTURES/tmux-example-plugin"
	printf '#!/bin/sh\necho "v1 $0" >> "$HOME/plugins_ran.log"\n' > "$_repo/tmux-example-plugin.tmux"
	fixgit "$_repo" commit -qam v1
	write_conf <<-EOF
	set -g @plugin '$_repo'
	run '~/.tmux/plugins/tpm/tpm'
	EOF
	start_tmux || return 1
	"$PLUGINS_DIR/tpm/bin/tempo" install >/dev/null 2>&1 || fail "install failed"
	cp "$HOME/tempo.lock" "$SANDBOX/lock.v1"
	cp "$HOME/.local/share/tempo/load.sh" "$SANDBOX/art.v1"

	# Upstream moves, and the update follows it.
	printf '#!/bin/sh\necho "v2 $0" >> "$HOME/plugins_ran.log"\n' > "$_repo/tmux-example-plugin.tmux"
	fixgit "$_repo" commit -qam v2
	out="$("$PLUGINS_DIR/tpm/bin/tempo" update all 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || { fail "update all exited $rc"; printf '%s\n' "$out" | sed 's/^/      | /'; }
	cmp -s "$HOME/tempo.lock" "$SANDBOX/lock.v1" && fail "update did not move the lockfile"
	reload_and_wait_for_plugins
	grep -q '^v2 ' "$HOME/plugins_ran.log" || fail "the server did not run v2 after the update"

	out="$("$PLUGINS_DIR/tpm/bin/tempo" rollback 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || { fail "rollback exited $rc"; printf '%s\n' "$out" | sed 's/^/      | /'; }
	assert_contains "$out" "rolled back to generation 1"
	cmp -s "$HOME/tempo.lock" "$SANDBOX/lock.v1" || fail "rollback did not restore the lockfile"
	cmp -s "$HOME/.local/share/tempo/load.sh" "$SANDBOX/art.v1" || fail "rollback changed the artifact"
	assert_store_link "$PLUGINS_DIR/tmux-example-plugin"

	reload_and_wait_for_plugins
	grep -q '^v1 ' "$HOME/plugins_ran.log" ||
		{ fail "the server did not run the pre-update plugin content after rollback"; \
			sed 's/^/      | /' "$HOME/plugins_ran.log"; }
}

# `prefix + I` end to end through a real server: bindings/install_plugins
# must clone a source this host has never seen without prompting for
# anything. Anything interactive on this path would hang here — and would
# break the held-out compat suite.
flow_binding_install_never_prompts() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	run '~/.tmux/plugins/tpm/tpm'
	EOF
	start_tmux || return 1
	"$PLUGINS_DIR/tpm/bindings/install_plugins" </dev/null >/dev/null 2>&1
	assert_dir "$PLUGINS_DIR/tmux-example-plugin/.git"
}

# `tempo add` end to end: the declaration lands in the real config file, the
# plugin installs through the store, and a real server boots and runs it.
# Judged by the plugin's own log line, which no config assertion can fake.
flow_add_declares_and_boots_the_plugin() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	run '~/.tmux/plugins/tpm/tpm'
	EOF
	start_tmux || return 1
	out="$("$PLUGINS_DIR/tpm/bin/tempo" add "$FIXTURES/tmux-example-plugin" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || { fail "add exited $rc"; printf '%s\n' "$out" | sed 's/^/      | /'; }
	assert_contains "$out" '"tmux-example-plugin" download success'
	grep -qF "set -g @plugin '$FIXTURES/tmux-example-plugin'" "$HOME/.tmux.conf" ||
		fail "the canonical declaration is not in the conf"
	ls "$HOME"/.tmux.conf.bak-* >/dev/null 2>&1 || fail "add did not back up the conf"
	assert_store_link "$PLUGINS_DIR/tmux-example-plugin"
	assert_file "$HOME/tempo.lock"

	reload_and_wait_for_plugins
	assert_file "$HOME/plugins_ran.log"
}

# `tempo remove` end to end: the declaration goes, the plugin's *files* stay
# (that is `tempo clean`'s job), and after a regenerate the server no longer
# runs it — the only assertion that proves the hot path followed the edit.
flow_remove_stops_the_plugin_from_running() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	write_conf <<-EOF
	set -g @plugin '$FIXTURES/tmux-example-plugin'
	run '~/.tmux/plugins/tpm/tpm'
	EOF
	start_tmux || return 1
	"$PLUGINS_DIR/tpm/bin/tempo" install >/dev/null 2>&1 || fail "seed install failed"
	reload_and_wait_for_plugins
	assert_file "$HOME/plugins_ran.log"

	out="$("$PLUGINS_DIR/tpm/bin/tempo" remove tmux-example-plugin 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || { fail "remove exited $rc"; printf '%s\n' "$out" | sed 's/^/      | /'; }
	assert_contains "$out" "tempo clean"
	if grep -q '@plugin' "$HOME/.tmux.conf"; then
		fail "the declaration survived remove"
		sed 's/^/      | /' "$HOME/.tmux.conf"
	fi
	assert_dir "$PLUGINS_DIR/tmux-example-plugin" # remove never deletes files

	"$PLUGINS_DIR/tpm/bin/tempo" generate >/dev/null 2>&1 || fail "generate exited non-zero"
	reload_and_wait_for_plugins
	[ ! -f "$HOME/plugins_ran.log" ] || fail "the plugin still ran after remove + generate"
}

# --- runner ------------------------------------------------------------------

run_test() {
	TEST_RC=0
	setup_sandbox
	"$1"
	teardown_sandbox
	if [ "$TEST_RC" -eq 0 ]; then
		echo "ok - $1"
		PASS=$((PASS + 1))
	else
		echo "not ok - $1"
		FAIL=$((FAIL + 1))
	fi
}

for _test in \
	flow_fresh_install \
	flow_migration_existing_tree \
	flow_symlinked_install_dir \
	flow_cli_via_path_symlink \
	flow_no_ruby_gate \
	flow_doctor_no_ruby_exits_1 \
	flow_doctor_healthy \
	flow_zero_plugin_guidance \
	flow_observer_failure_changes_nothing \
	flow_declared_plugin_suppresses_guidance \
	flow_init_fresh \
	flow_init_drop_in \
	flow_clean_after_fresh_init \
	flow_frozen_install_offline \
	flow_frozen_violation_stays_offline \
	flow_store_backed_install_runs_through_the_symlink \
	flow_store_adopts_existing_flat_clone \
	flow_rollback_reverts_plugin_content \
	flow_binding_install_never_prompts \
	flow_add_declares_and_boots_the_plugin \
	flow_remove_stops_the_plugin_from_running; do
	run_test "$_test"
done

echo "# run_flows.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
