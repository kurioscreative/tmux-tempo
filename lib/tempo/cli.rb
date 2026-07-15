# frozen_string_literal: true

module Tempo
  # Subcommand dispatch for bin/tempo. The three compat bins
  # (install_plugins / update_plugins / clean_plugins) are thin sh wrappers
  # over this.
  class CLI
    USAGE = <<~TEXT
      usage: tempo <command> [args]

        install                 install declared plugins
        update all|<name>...    update plugins (parallel)
        clean                   remove undeclared plugin dirs
        sync                    install missing + restore locked + clean
        restore                 check out lockfile commits (detached HEAD)
        generate [--force]      regenerate the loader artifact
        status                  declared plugins and lock state

      options: --tmux-echo   deliver output through `tmux run-shell echo`
    TEXT

    def self.run(argv)
      args = argv.dup
      tmux_echo = !args.delete("--tmux-echo").nil?
      args.delete("--force") # generate is always a full regeneration
      command = args.shift
      env = Env.new
      ui = UI.new(tmux_echo: tmux_echo)

      case command
      when "install" then Commands.install(env, ui)
      when "update" then Commands.update(env, ui, args)
      when "clean" then Commands.clean(env, ui)
      when "generate" then Commands.generate(env)
      when "sync" then Commands.sync(env, ui)
      when "restore" then Commands.restore(env, ui)
      when "status" then Commands.status(env, ui)
      when "update-list" then Commands.update_list(env, ui)
      else
        $stderr.puts(USAGE)
        1
      end
    end
  end
end
