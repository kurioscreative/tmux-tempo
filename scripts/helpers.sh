# POSIX-sh helpers shared by the tempo entry point, bin/ shims and
# bindings/ scripts. Sourced, never executed. No bashisms.

# --- ruby gate (D1) ----------------------------------------------------------

# Sets RUBY_GATE_MSG and returns 1 when no usable Ruby >= 3.0 exists.
# Management operations are the only Ruby consumers; the hot path must
# keep working without it.
ruby_gate() {
	if ! command -v ruby >/dev/null 2>&1; then
		RUBY_GATE_MSG="tempo requires Ruby >= 3.0; no ruby found in PATH"
		return 1
	fi
	_ruby_version="$(ruby -e 'print RUBY_VERSION' 2>/dev/null)"
	case "$_ruby_version" in
		[3-9].* | [1-9][0-9].*) return 0 ;;
	esac
	RUBY_GATE_MSG="tempo requires Ruby >= 3.0; found ${_ruby_version:-an unidentifiable ruby}"
	return 1
}

# --- tmux version gate -------------------------------------------------------

# Same >=1.9 outcome as the original, via a real numeric comparison instead
# of the digit-concat comparator (licensed drop, INTERFACE.md §3).
# Unparseable versions ("tmux master", "tmux next-X") count as supported.
tmux_version_supported() {
	_mm="$(tmux -V 2>/dev/null | sed -nE 's/^[^0-9]*([0-9]+)(\.([0-9]+))?.*$/\1 \3/p')"
	[ -n "$_mm" ] || return 0
	_major="${_mm%% *}"
	_minor="${_mm#* }"
	[ -n "$_minor" ] || _minor=0
	[ "$_major" -gt 1 ] && return 0
	[ "$_major" -eq 1 ] && [ "$_minor" -ge 9 ] && return 0
	return 1
}

# 5-second prompt message without clobbering the user's display-time,
# mirroring the original's check_tmux_version.sh.
display_message() {
	_saved_display_time="$(tmux show-option -gqv display-time)"
	[ -n "$_saved_display_time" ] || _saved_display_time=750
	tmux set-option -gq display-time 5000
	tmux display-message "$1"
	tmux set-option -gq display-time "$_saved_display_time"
}

# --- paths -------------------------------------------------------------------

# tpm's user-config rule: the XDG config if it exists, else ~/.tmux.conf.
user_tmux_conf() {
	_xdg_conf="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
	if [ -f "$_xdg_conf" ]; then
		printf '%s\n' "$_xdg_conf"
	else
		printf '%s\n' "$HOME/.tmux.conf"
	fi
}

default_plugin_path() {
	_xdg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/tmux"
	if [ -f "$_xdg_dir/tmux.conf" ]; then
		printf '%s\n' "$_xdg_dir/plugins/"
	else
		printf '%s\n' "$HOME/.tmux/plugins/"
	fi
}

# TMUX_PLUGIN_MANAGER_PATH as used: expanded (leading ~ / $HOME, like the
# original), forced trailing slash — normalized, not doubled (licensed
# drop). Falls back to the default when unset (divergence 2). Must produce
# byte-identical output to Ruby's Env#plugin_path.
current_plugin_path() {
	_raw="$(tmux start-server \; show-environment -g TMUX_PLUGIN_MANAGER_PATH 2>/dev/null | cut -d= -f2-)"
	if [ -z "$_raw" ]; then
		default_plugin_path
		return 0
	fi
	case "$_raw" in
		"~") _raw="$HOME" ;;
		"~/"*) _raw="$HOME${_raw#"~"}" ;;
		'$HOME') _raw="$HOME" ;;
		'$HOME/'*) _raw="$HOME${_raw#\$HOME}" ;;
	esac
	case "$_raw" in
		*/) printf '%s\n' "$_raw" ;;
		*) printf '%s/\n' "$_raw" ;;
	esac
}

tempo_data_dir() {
	printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/tempo"
}

# --- artifact freshness (D2) -------------------------------------------------

# "<mtime> <size>" for a file, GNU or BSD stat. Order and validation both
# matter: GNU stat accepts -f (filesystem mode) and BSD stat accepts -c-ish
# errors differently, and a PATH can put either first on macOS — so accept
# an answer only when it looks like two integers. No answer reads as stale.
_stat_mtime_size() {
	for _fmt in "-c:%Y %s" "-f:%m %z"; do
		_out="$(stat "${_fmt%%:*}" "${_fmt#*:}" "$1" 2>/dev/null)"
		case "$_out" in
			*[!0-9\ ]* | "") ;; # not "digits digits" — wrong stat dialect
			[0-9]*\ [0-9]*) printf '%s\n' "$_out"; return 0 ;;
		esac
	done
	return 1
}

# Fresh = fingerprint + artifact exist, and the fingerprint still matches
# the current plugin path, the live @tpm_plugins value, and every recorded
# config file's mtime+size (including still-missing ones). Any doubt —
# unknown line, unreadable file — reads as stale: regeneration is cheap,
# a wrong plugin set is not.
artifact_fresh() {
	_data_dir="$(tempo_data_dir)"
	_fingerprint="$_data_dir/fingerprint"
	[ -f "$_fingerprint" ] || return 1
	[ -f "$_data_dir/load.sh" ] || return 1
	_cur_path="$(current_plugin_path)"
	_cur_plugins="$(tmux start-server \; show-option -gqv @tpm_plugins 2>/dev/null)"
	_first_line=1
	while IFS= read -r _line || [ -n "$_line" ]; do
		if [ -n "$_first_line" ]; then
			[ "$_line" = "tempo-fingerprint 1" ] || return 1
			_first_line=""
			continue
		fi
		case "$_line" in
			"path "*)
				[ "${_line#path }" = "$_cur_path" ] || return 1 ;;
			"tpm_plugins "*)
				[ "${_line#tpm_plugins }" = "$_cur_plugins" ] || return 1 ;;
			"tpm_plugins")
				[ -z "$_cur_plugins" ] || return 1 ;;
			"f "*)
				_rest="${_line#f }"
				_mtime="${_rest%% *}"
				_rest="${_rest#* }"
				_size="${_rest%% *}"
				_file="${_rest#* }"
				[ "$(_stat_mtime_size "$_file")" = "$_mtime $_size" ] || return 1 ;;
			"m "*)
				[ ! -e "${_line#m }" ] || return 1 ;;
			*)
				return 1 ;;
		esac
	done < "$_fingerprint"
	return 0
}

# --- interactive output (the temporary-pane UX) --------------------------------

tmux_echo() {
	_escaped="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
	tmux run-shell "echo '$_escaped'"
}

end_message() {
	if tmux show -gw mode-keys 2>/dev/null | grep -q emacs; then
		_continue_key="ESCAPE"
	else
		_continue_key="ENTER"
	fi
	tmux_echo ""
	tmux_echo "TMUX environment reloaded."
	tmux_echo ""
	tmux_echo "Done, press $_continue_key to continue."
}

reload_tmux_environment() {
	tmux source-file "$(user_tmux_conf)" >/dev/null 2>&1
}
