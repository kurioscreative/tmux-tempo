# frozen_string_literal: true

# Entry point invoked by the bin/tempo sh shim (which owns the Ruby >= 3.0
# version gate). Not meant to be run directly.
$LOAD_PATH.unshift(File.expand_path("..", __dir__))
require "tempo"

exit Tempo::CLI.run(ARGV)
