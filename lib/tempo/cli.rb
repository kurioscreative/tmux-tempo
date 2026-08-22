# frozen_string_literal: true

module Tempo
  # Subcommand dispatch for bin/tempo. The three compat bins
  # (install_plugins / update_plugins / clean_plugins) are thin sh wrappers
  # over this.
  class CLI
    USAGE = <<~TEXT
      usage: tempo <command> [args]

        init [--yes]            set up tmux to use this checkout (drop-in for tpm)
        install                 install declared plugins that are missing
        add <spec>              declare a plugin in your config, then install it
        remove <name>           delete a plugin's declaration from your config
        update all|<name>...    update plugins (parallel)
        clean                   remove undeclared plugin dirs
        sync [--frozen]         install missing + enforce the lock + clean
        restore [--frozen]      put every plugin back on its locked commit
        rollback [N]            undo: flip back to the previous generation (or N)
        generate [--force]      regenerate the loader artifact
        status                  declared plugins, lock state and generations
        doctor                  check requirements, paths and artifact health
        update-list             internal: plugin list behind the prefix+U prompt

      options: --tmux-echo   deliver output through `tmux run-shell echo`
               --frozen      (sync/restore) enforce the lockfile offline;
                             fails if it is not satisfiable, never writes it
               --yes, -y     (init) skip the confirmation prompt
    TEXT

    # Flags each subcommand accepts, on top of the global --tmux-echo.
    # Anything else is a usage error: silently swallowing unknown flags is
    # exactly what let `sync --frozen` be a no-op that reported success.
    FLAGS = {
      "init" => ["--yes", "-y"],
      "generate" => ["--force"],
      "sync" => ["--frozen"],
      "restore" => ["--frozen"],
    }.freeze

    YES = ["--yes", "-y"].freeze

    def self.run(argv)
      args = argv.dup
      tmux_echo = !args.delete("--tmux-echo").nil?
      command = args.shift
      unknown = unknown_flags(command, args)
      unless unknown.empty?
        $stderr.puts("unknown option: #{unknown.first}")
        $stderr.puts(USAGE)
        return 1
      end

      frozen = args.include?("--frozen")
      yes = !(args & YES).empty?
      env = Env.new
      ui = UI.new(tmux_echo: tmux_echo)

      case command
      when "install" then Commands.install(env, ui)
      when "add" then ConfigEdit.add(env, ui, args)
      when "remove" then ConfigEdit.remove(env, ui, args)
      when "update" then Commands.update(env, ui, args)
      when "clean" then Commands.clean(env, ui)
      when "generate" then Commands.generate(env)
      when "sync" then Commands.sync(env, ui, frozen: frozen)
      when "restore" then Commands.restore(env, ui, frozen: frozen)
      when "rollback" then Commands.rollback(env, ui, args)
      when "status" then Commands.status(env, ui)
      when "update-list" then Commands.update_list(env, ui)
      when "doctor" then Doctor.run(env, ui)
      when "init" then Init.run(env, ui, yes: yes)
      else
        $stderr.puts(USAGE)
        1
      end
    end

    # Every token after `update` is prompt data the user typed — the
    # prefix+U prompt hands the string over as-is — so `update --weird` must
    # keep reaching the "not installed!" path instead of usage-erroring.
    def self.unknown_flags(command, args)
      return [] if command == "update"

      args.select { |a| a.start_with?("-") } - FLAGS.fetch(command, [])
    end
  end
end
