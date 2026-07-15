#!/bin/sh
# Receives the prefix+U prompt input (already word-split by run-shell).
# Empty input arrives as zero args → cancel silently, like the original.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/helpers.sh"

[ $# -eq 0 ] && exit 0

# No stdout redirect — the update report reaches the output view through
# this job's stdout, exactly like the original's prompt handler.
TEMPO_TMUX_ECHO=1 "$ROOT/bin/tempo" update --tmux-echo "$@"
reload_tmux_environment
end_message
