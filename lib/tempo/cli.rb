# frozen_string_literal: true

module Tempo
  # Subcommand dispatch for bin/tempo. The three compat bins
  # (install_plugins / update_plugins / clean_plugins) are thin sh wrappers
  # over this.
  class CLI
    USAGE = <<~TEXT
      usage: tempo <command> [args]

        init [--yes]            set up tmux to use this checkout (drop-in for tpm)
        install [--frozen]      install missing + enforce the lock + clean
        add <spec>              declare a plugin in your config, then install it
        remove <name>           delete a plugin's declaration from your config
        update all|<name>...    update plugins (parallel)
        clean                   remove undeclared plugin dirs
        rollback [N]            undo: flip back to the previous generation (or N)
        generate                regenerate the loader artifact
        status                  declared plugins, lock state and generations
        doctor                  check requirements, paths and artifact health

      options: --frozen      (install) enforce the lockfile offline;
                             fails if it is not satisfiable, never writes it
               --yes, -y     (init) skip the confirmation prompt
    TEXT

    # Flags each subcommand accepts, on top of the global --tmux-echo.
    # Anything else is a usage error: silently swallowing unknown flags is
    # exactly what let `--frozen` be a no-op that reported success.
    FLAGS = {
      "init" => ["--yes", "-y"],
      "install" => ["--frozen"],
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

      dispatch(command, args, env, ui, frozen: frozen, yes: yes)
    rescue ObserverError => e
      # The one place these are caught (D34/D35). Every mutating verb runs
      # `Commands.preflight` before it touches disk, so refusing here refuses
      # early, and "nothing was changed" is literally true.
      refuse(ui, "cannot determine the declared plugin set: #{e.message}")
    rescue Git::Unavailable, Lockfile::Unparseable => e
      refuse(ui, e.message)
    end

    def self.refuse(ui, why)
      ui.err("tempo: #{why}")
      ui.err("tempo: nothing was changed")
      1
    end

    def self.dispatch(command, args, env, ui, frozen:, yes:)
      case command
      when "install" then Commands.install(env, ui, frozen: frozen)
      when "add" then ConfigEdit.add(env, ui, args)
      when "remove" then ConfigEdit.remove(env, ui, args)
      when "update" then Commands.update(env, ui, args)
      when "clean" then Commands.clean(env, ui)
      when "generate" then Commands.generate(env)
      when "rollback" then Commands.rollback(env, ui, args)
      when "status" then Commands.status(env, ui)
      # Not in USAGE: an internal call from bindings/update_plugins, never typed.
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
