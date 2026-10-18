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

    # First-run guidance; shown by `install` and `update` when the config
    # declares nothing (the compat contract never exercises that case, so
    # this stays additive to the INTERFACE.md §1.2 output API).
    ZERO_PLUGIN_GUIDANCE = <<~TEXT
      No plugins declared.

      Declare plugins in your tmux config with:

        set -g @plugin 'tmux-plugins/tmux-sensible'

      then run this again, or press prefix + I inside tmux.
    TEXT

    module_function

    # install = clone what is missing + put installed plugins on their locked
    # commits + remove undeclared ones (D32). tpm's install could only ever do
    # the first of those because a directory's existence was the only desired
    # state it had; with a lockfile, enforcing it is what `install` means
    # everywhere else (npm, bundler, poetry), and a lock that the gesture
    # everyone uses never consults is a lock that does nothing.
    #
    # `--frozen` is the `cargo --locked` posture instead: prove the lock is
    # satisfiable from what is already on disk, enforce it offline, and never
    # write the lock back.
    def install(env, ui, frozen: false)
      specs = preflight(env)
      return frozen_enforce(env, ui) if frozen

      prepare_path(env, ui, verify_writable: true)
      if specs.empty?
        # Nothing declared nearly always means tmux read a different config
        # than the user edited (the case doctor's `configs:` line exists for;
        # an observer that *failed* raises instead, D34). Cleaning here would
        # delete every plugin over a typo, and writing the lock would erase
        # every pin the same way (D33): touch nothing. Explicit `tempo clean`
        # still does it; a keystroke must not.
        ui.ok(ZERO_PLUGIN_GUIDANCE)
        return ui.exit_code
      end

      install_missing(env, ui)
      restore_locked(env, ui)
      clean_undeclared(env, ui)
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

      # Same guard as install (D33): an empty observation carries no
      # information, and writing the lock from it would erase every pin.
      if preflight(env).empty?
        ui.ok(ZERO_PLUGIN_GUIDANCE)
        return ui.exit_code
      end

      prepare_path(env, ui, verify_writable: false)
      updated = update_named(env, ui, names)
      finalize(env, updated)
      ui.exit_code
    end

    def clean(env, ui)
      preflight(env)
      prepare_path(env, ui, verify_writable: false)
      clean_undeclared(env, ui)
      finalize(env)
      ui.exit_code
    end

    def generate(env, _ui = nil)
      Generator.new(env).generate
      0
    end

    # A report, not a check: an observer failure is one more fact to print
    # (D34), and an empty declared set gets the same pointer install gives,
    # because an empty list here reads as "tempo lost my plugins".
    def status(env, ui)
      ui.ok("plugins path: #{env.plugin_path}")
      ui.ok("lockfile:     #{env.lockfile_path}")
      ui.ok("")
      begin
        Git.preflight!
      rescue Git::Unavailable => e
        ui.warn("  #{e.message}; the installed state below is unreliable")
      end
      begin
        lock = Lockfile.read(env.lockfile_path)
      rescue Lockfile::Unparseable => e
        ui.warn("  #{e.message}")
        lock = {}
      end
      begin
        list_declared(env, ui, lock)
      rescue ObserverError => e
        ui.warn("  plugins could not be determined: #{e.message}")
      end
      0
    end

    def list_declared(env, ui, lock)
      if env.specs.empty?
        ui.ok("  no plugins declared — add `set -g @plugin '<owner/repo>'` lines to your tmux config, or run `tempo add <owner/repo>`")
        return
      end
      seen = {}
      env.specs.each do |spec|
        next if seen[spec.name]

        seen[spec.name] = true
        ui.ok("  #{spec.name}: #{status_line(env, lock, spec)}")
      end
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

    # The only place tempo clones a source it was not already managing —
    # `update` and `restore_locked` are guarded by `env.installed?` and can
    # only ever touch plugins this host already has.
    def install_missing(env, ui)
      env.specs.each do |spec|
        if env.installed?(spec.name)
          ui.ok(%(Already installed "#{spec.name}"))
          next
        end
        ui.ok(%(Installing "#{spec.name}"))
        if Git.clone_plugin(spec, env.plugin_dir(spec.name))
          ui.ok(%(  "#{spec.name}" download success))
        else
          ui.err(%(  "#{spec.name}" download fail))
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
      # Returns the names that actually moved: the only pins the lock may
      # re-derive from disk (D33).
      results = targets.map do |name|
        Thread.new do
          out, ok = Git.pull(env.plugin_dir(name))
          indented = out.split("\n").map { |l| "    | #{l}" }.join("\n")
          if ok
            ui.ok(%(  "#{name}" update success\n#{indented}))
          else
            ui.err(%(  "#{name}" update fail\n#{indented}))
          end
          [name, ok]
        end
      end.map(&:value)
      results.select { |_, ok| ok }.map(&:first)
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

        # The fetch retry is enforcement's only network touch, and frozen
        # drops it — preflight has already proven the object is here.
        ok = Git.checkout(dir, entry["commit"])
        ok ||= Git.fetch(dir) && Git.checkout(dir, entry["commit"]) unless frozen
        if ok
          ui.ok(%(  "#{spec.name}" restored to #{entry["commit"][0, 12]}))
        else
          # The pin stays (D33), so this recurs on every install until the
          # user moves it; say how.
          ui.err(%(  "#{spec.name}" restore fail: locked commit #{entry["commit"][0, 12]} unavailable ) +
                 %{(`tempo update #{spec.name}` moves the pin)})
        end
      end
    end

    # Verify-then-mutate. Every violation is named and *nothing* changes —
    # not the clones, not the lock, not the artifact — unless the whole lock
    # is satisfiable from local objects. Partial enforcement of a broken
    # lock is worse than no enforcement.
    def frozen_enforce(env, ui)
      # An empty declared set means a config tmux never read, not "nothing to
      # do": a CI gate that passes having verified nothing is worse than one
      # that fails, so unlike plain install this is an error.
      if env.specs.empty?
        ui.err("frozen: no plugins declared, nothing to enforce")
        return 1
      end

      violations = frozen_violations(env)
      unless violations.empty?
        ui.err("frozen: lockfile not satisfied")
        violations.each { |name, reason| ui.err(%(  "#{name}" #{reason})) }
        return 1
      end

      restore_locked(env, ui, frozen: true)
      clean_undeclared(env, ui) # local-only, so frozen still runs it
      Generator.new(env).generate # the hot path must reflect enforced disk
      ui.exit_code
    end

    # The three ways a lock can fail to be satisfiable offline, at most one
    # line per declared plugin (duplicate specs collapse, like
    # Lockfile.write). A missing lock reads as {}, so every declared plugin
    # lands in the second bucket — which is correct; an unparseable one never
    # gets here (preflight refused, D35).
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

    # Every mutating verb starts here (D34/D35), before it touches disk: git
    # must run, the lock must parse, the declared set must be observable.
    # Each raises; CLI refuses; nothing has moved yet. Returns the declared
    # set.
    def preflight(env)
      Git.preflight!
      Lockfile.read(env.lockfile_path)
      env.specs
    end

    # Every mutating operation writes the lock and regenerates the artifact,
    # so the hot path and the lockfile reflect the run. The lock is an input
    # to that write (D33): only the pins in `refresh` — what update moved on
    # purpose — are re-derived from disk.
    def finalize(env, refresh = [])
      Lockfile.write(env, refresh)
      Generator.new(env).generate
    end
  end
end
