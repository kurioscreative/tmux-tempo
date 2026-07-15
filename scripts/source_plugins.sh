#!/bin/sh
# The hot path (D2): check artifact freshness, regenerate via Ruby only
# when stale, then run the generated loader. Steady state costs no Ruby
# and never touches the network. Always exits 0 — a broken or missing
# plugin set must never break config loading (guarantee since tpm v1.1.0).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/helpers.sh"

ARTIFACT="$(tempo_data_dir)/load.sh"

if ! artifact_fresh; then
	if ruby_gate; then
		"$ROOT/bin/tempo" generate >/dev/null 2>&1 || :
	elif [ ! -f "$ARTIFACT" ]; then
		printf 'tempo: %s\n' "$RUBY_GATE_MSG" >&2
	fi
	# Stale artifact + no Ruby: fall through and run the stale artifact —
	# a previously working plugin set beats loading nothing (D1 mitigation).
fi

[ -f "$ARTIFACT" ] && sh "$ARTIFACT"
exit 0
