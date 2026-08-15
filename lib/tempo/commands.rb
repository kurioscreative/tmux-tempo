# frozen_string_literal: true

require "fileutils"

module Tempo
  # One function per CLI subcommand. Output strings are API (INTERFACE.md
  # §1.2) — every user-visible message here is byte-compatible with the
  # original tpm. Each command returns its exit code.
  module Commands
    UPDATE_USAGE = <<~TEXT
      usage:
        tempo update all                   update all plugins
        tempo update tmux-foo              update plugin 'tmux-foo'
        tempo update tmux-bar tmux-baz     update multiple plugins
    TEXT

    # First-run guidance; only ever shown by `install` when the config
    # declares nothing (the compat contract never exercises that case, so
    # this stays additive to the INTERFACE.md §1.2 output API).
    ZERO_PLUGIN_GUIDANCE = <<~TEXT
      No plugins declared.

      Declare plugins in your tmux config with:

        set -g @plugin 'tmux-plugins/tmux-sensible'

      then run this again, or press prefix + I inside tmux.
    TEXT

    module_function

    def install(env, ui)
      prepare_path(env, ui, verify_writable: true)
      if env.specs.empty?
        ui.ok(ZERO_PLUGIN_GUIDANCE)
      else
        install_missing(env, ui)
      end
      finalize(env)
      ui.exit_code
    end

    def update(env, ui, args)
      # Same word-splitting path as the prefix+U prompt, which hands the
      # typed string over as-is.
      names = args.join(" ").split(/\s+/).reject(&:empty?)
      if names.empty?
        ui.err(UPDATE_USAGE)
        return 1
      end

      prepare_path(env, ui, verify_writable: false)
      update_named(env, ui, names)
      finalize(env)
      ui.exit_code
    end

    def clean(env, ui)
      prepare_path(env, ui, verify_writable: false)
      clean_undeclared(env, ui)
      finalize(env)
      ui.exit_code
    end

    def generate(env, _ui = nil)
      Generator.new(env).generate
      0
    end

    # sync = install missing + check out locked commits + clean undeclared
    # (D5). The final lock rewrite snapshots the now-enforced disk state.
    # `--frozen` is the `cargo --locked` posture instead: prove the lock is
    # satisfiable from what is already on disk, enforce it offline, and
    # never write the lock back.
    def sync(env, ui, frozen: false)
      return frozen_enforce(env, ui, clean: true) if frozen

      prepare_path(env, ui, verify_writable: true)
      install_missing(env, ui)
      restore_locked(env, ui)
      clean_undeclared(env, ui)
      finalize(env)
      ui.exit_code
    end

    # restore = the checkout-locked-commits part of sync, alone. Leaves
    # clones on a detached HEAD by design; `update` moves the lock forward.
    def restore(env, ui, frozen: false)
      return frozen_enforce(env, ui, clean: false) if frozen

      restore_locked(env, ui)
      Generator.new(env).generate
      ui.exit_code
    end

    def status(env, ui)
      lock = Lockfile.read(env.lockfile_path)
      ui.ok("plugins path: #{env.plugin_path}")
      ui.ok("lockfile:     #{env.lockfile_path}")
      ui.ok("")
      seen = {}
      env.specs.each do |spec|
        next if seen[spec.name]

        seen[spec.name] = true
        ui.ok("  #{spec.name}: #{status_line(env, lock, spec)}")
      end
      0
    end

    # The prefix+U banner. Names are branch-stripped before the installed
    # check, so #branch-pinned plugins appear (intentional divergence 3).
    def update_list(env, ui)
      ui.ok("Installed plugins:")
      ui.ok("")
      env.specs.each do |spec|
        ui.ok("  #{spec.name}") if env.installed?(spec.name)
      end
      ui.ok("")
      ui.ok("Type plugin name to update it.")
      ui.ok("")
      ui.ok(%(- "all" - updates all plugins))
      ui.ok("- ENTER - cancels")
      0
    end

    # --- shared pieces --------------------------------------------------

    def prepare_path(env, ui, verify_writable:)
      FileUtils.mkdir_p(env.plugin_path)
    rescue SystemCallError
      ui.err("#{env.plugin_path} is not writable!")
    else
      ui.err("#{env.plugin_path} is not writable!") if verify_writable && !File.writable?(env.plugin_path)
    end

    def install_missing(env, ui)
      env.specs.each do |spec|
        if env.installed?(spec.name)
          ui.ok(%(Already installed "#{spec.name}"))
        else
          ui.ok(%(Installing "#{spec.name}"))
          if Git.clone_plugin(spec, env.plugin_path)
            ui.ok(%(  "#{spec.name}" download success))
          else
            ui.err(%(  "#{spec.name}" download fail))
          end
        end
      end
    end

    def update_named(env, ui, names)
      targets =
        if names == ["all"]
          ui.ok("Updating all plugins!")
          ui.ok("")
          env.specs.map(&:name).select { |n| env.installed?(n) }
        else
          names.filter_map do |raw|
            name = Spec.parse(raw).name
            if env.installed?(name)
              name
            else
              ui.err("#{name} not installed!")
              nil
            end
          end
        end

      # Parallel like the original; each plugin's report emits atomically.
      targets.map do |name|
        Thread.new do
          out, ok = Git.pull(env.plugin_dir(name))
          indented = out.split("\n").map { |l| "    | #{l}" }.join("\n")
          if ok
            ui.ok(%(  "#{name}" update success\n#{indented}))
          else
            ui.err(%(  "#{name}" update fail\n#{indented}))
          end
        end
      end.each(&:join)
    end

    def clean_undeclared(env, ui)
      declared = env.specs.map(&:name)
      Dir.glob(File.join(env.plugin_path, "*")).sort.each do |dir|
        next unless File.directory?(dir)

        name = File.basename(dir).sub(/\.git\z/, "")
        next if name == "tpm" # never delete the manager's own install
        next if own_install?(dir) # ...whatever it's named (D13; `init` links it as "tempo")
        next if declared.include?(name) # exact match (licensed drop of the substring quirk)

        ui.ok(%(Removing "#{name}"))
        begin
          FileUtils.rm_rf(dir)
        rescue SystemCallError
          nil
        end
        if File.directory?(dir)
          ui.err(%(  "#{name}" clean fail))
        else
          ui.ok(%(  "#{name}" clean success))
        end
      end
    end

    # Glob yields the symlink path and rm_rf on a symlink removes the link,
    # so this must fire before either; realpath both sides (macOS /tmp).
    def own_install?(dir)
      File.realpath(dir) == File.realpath(File.expand_path("../..", __dir__))
    rescue Errno::ENOENT
      false
    end

    def restore_locked(env, ui, frozen: false)
      lock = Lockfile.read(env.lockfile_path)
      env.specs.each do |spec|
        entry = lock[spec.name]
        next unless entry && entry["commit"]
        next unless env.installed?(spec.name)

        dir = env.plugin_dir(spec.name)
        next if Git.head_commit(dir) == entry["commit"]

        ok = Git.checkout(dir, entry["commit"])
        # The fetch retry is restore's only network touch; frozen drops it,
        # and preflight has already proven the object is here.
        ok ||= Git.fetch(dir) && Git.checkout(dir, entry["commit"]) unless frozen
        if ok
          ui.ok(%(  "#{spec.name}" restored to #{entry["commit"][0, 12]}))
        else
          ui.err(%(  "#{spec.name}" restore fail))
        end
      end
    end

    # Verify-then-mutate. Every violation is named and *nothing* changes —
    # not the clones, not the lock, not the artifact — unless the whole lock
    # is satisfiable from local objects. Partial enforcement of a broken
    # lock is worse than no enforcement.
    def frozen_enforce(env, ui, clean:)
      violations = frozen_violations(env)
      unless violations.empty?
        ui.err("frozen: lockfile not satisfied")
        violations.each { |name, reason| ui.err(%(  "#{name}" #{reason})) }
        return 1
      end

      restore_locked(env, ui, frozen: true)
      clean_undeclared(env, ui) if clean # local-only, so frozen still runs it
      Generator.new(env).generate # the hot path must reflect enforced disk
      ui.exit_code
    end

    # The three ways a lock can fail to be satisfiable offline, at most one
    # line per declared plugin (duplicate specs collapse, like
    # Lockfile.write). A missing or unparseable lock reads as {}, so every
    # declared plugin lands in the second bucket — which is correct.
    def frozen_violations(env)
      lock = Lockfile.read(env.lockfile_path)
      seen = {}
      env.specs.each_with_object([]) do |spec, out|
        next if seen[spec.name]

        seen[spec.name] = true
        commit = lock.dig(spec.name, "commit")
        if !env.installed?(spec.name)
          out << [spec.name, "not installed"]
        elsif commit.nil?
          out << [spec.name, "not in the lockfile"]
        elsif !Git.commit_present?(env.plugin_dir(spec.name), commit)
          out << [spec.name, "locked commit #{commit[0, 12]} missing locally"]
        end
      end
    end

    def status_line(env, lock, spec)
      return "missing" unless env.installed?(spec.name)

      commit = Git.head_commit(env.plugin_dir(spec.name))
      locked = lock.dig(spec.name, "commit")
      state =
        if locked.nil? then "unlocked"
        elsif locked == commit then "locked"
        else "drifted from lock (locked #{locked[0, 12]})"
        end
      "installed at #{commit ? commit[0, 12] : "?"} (#{state})"
    end

    # Every mutating operation rewrites the lock and regenerates the
    # artifact so the hot path and the lockfile always reflect disk.
    def finalize(env)
      Lockfile.write(env)
      Generator.new(env).generate
    end
  end
end
