# frozen_string_literal: true

require "open3"
require "shellwords"

module Tempo
  # Thin wrapper over the tmux CLI. The `start-server ;` prefixes mirror the
  # original tpm: the bin/ scripts must work before any server exists, and
  # tmux transparently routes to the caller's socket via $TMUX_TMPDIR.
  module Tmux
    module_function

    def option(name)
      out, ok = run("start-server", ";", "show-option", "-gqv", name)
      ok ? out.chomp : ""
    end

    # A tmux *global environment variable* (not an OS env var). Returns nil
    # when unset.
    def global_env(name)
      out, ok = run("start-server", ";", "show-environment", "-g", name)
      return nil unless ok

      out.chomp.split("=", 2)[1]
    end

    def set_global_env(name, value)
      run("start-server", ";", "set-environment", "-g", name, value)
    end

    # The original's "temporary pane" UX: every interactive line is
    # delivered as `tmux run-shell "echo <line>"`. The nested client must
    # inherit our stdout — the text reaches the tmux output view through
    # the enclosing run-shell job's captured stdout, so capturing it here
    # (or redirecting it in a binding script) makes it vanish.
    def display_echo(message)
      system("tmux", "run-shell", "echo #{Shellwords.escape(message)}")
    end

    def run(*args)
      out, status = Open3.capture2e("tmux", *args)
      [out, status.success?]
    rescue Errno::ENOENT
      ["", false]
    end
  end
end
