# frozen_string_literal: true

module Tempo
  # Output + failure tracking, mirroring the original's echo helpers:
  # shell mode writes ok→stdout / err→stderr; tmux mode delivers every line
  # through `tmux run-shell echo`. Any err makes the exit code 1 — for
  # update too (intentional divergence 1: the original lost FAIL in
  # backgrounded subshells and always exited 0).
  class UI
    def initialize(tmux_echo: false, out: $stdout, err: $stderr)
      @tmux_echo = tmux_echo
      @out = out
      @err = err
      @failed = false
      @mutex = Mutex.new # updates emit from threads
    end

    def ok(message)
      emit(message, @out)
    end

    def err(message)
      @failed = true
      emit(message, @err)
    end

    def failed?
      @failed
    end

    def exit_code
      @failed ? 1 : 0
    end

    private

    def emit(message, stream)
      @mutex.synchronize do
        if @tmux_echo
          message.to_s.split("\n", -1).each { |line| Tmux.display_echo(line) }
        else
          stream.puts(message)
        end
      end
    end
  end
end
