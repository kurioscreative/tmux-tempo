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
	unset TMUX XDG_CONFIG_HOME XDG_DATA_HOME
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
	printf '#!/bin/sh\necho ran >> "$HOME/plugins_ran.log"\n' > "$_dir/$1.tmux"
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

# Zero plugins declared: install must guide the user toward @plugin.
flow_zero_plugin_guidance() {
	install_tempo_copy "$PLUGINS_DIR/tpm"
	touch "$HOME/.tmux.conf"
	out="$("$PLUGINS_DIR/tpm/bin/install_plugins" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "install_plugins exited $rc"
	assert_contains "$out" "@plugin"
	assert_contains "$out" "No plugins declared"
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
	"$SANDBOX/checkout/bin/tempo" init >/dev/null 2>&1
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
	flow_no_ruby_gate \
	flow_doctor_no_ruby_exits_1 \
	flow_doctor_healthy \
	flow_zero_plugin_guidance \
	flow_declared_plugin_suppresses_guidance \
	flow_init_fresh \
	flow_init_drop_in \
	flow_clean_after_fresh_init; do
	run_test "$_test"
done

echo "# run_flows.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
