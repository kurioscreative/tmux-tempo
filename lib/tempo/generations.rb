# frozen_string_literal: true

require "fileutils"
require "json"

module Tempo
  # Numbered generations (S2.2, D25). Every mutating operation snapshots the
  # pair that fully describes "which plugins are live": the lockfile bytes and
  # the plugin path's symlink set. `rollback` puts both back.
  #
  # This is only affordable because of the store (D24): a generation does not
  # copy plugins, it records which already-filed entry each name pointed at, so
  # filing one costs a few hundred bytes and rolling back costs a rename per
  # plugin. It is also what finally bounds the store — pruning and GC ride
  # every new generation, so superseded entries stop accumulating forever.
  #
  # Layout under `<data_dir>/generations/`:
  #
  #   current            the number the plugin path is on right now
  #   <N>/manifest.json  {version, op, time, links:{name=>entry}, unmanaged:[]}
  #   <N>/tempo.lock     a byte copy of the lockfile as it stood
  #
  # `manifest.json` is written last, so a crash mid-file leaves a directory
  # that `numbers` simply does not count.
  module Generations
    # Retention is a constant on purpose (see the contract's HARD RULES): a
    # knob here buys nothing a user would tune and costs a config surface,
    # a doc, and a migration story forever.
    KEEP = 10

    module_function

    def root(env)
      File.join(env.data_dir, "generations")
    end

    def dir(env, number)
      File.join(root(env), number.to_s)
    end

    # Existing generation numbers, ascending. A directory without a manifest
    # is a half-written generation and does not exist as far as anyone here
    # is concerned.
    def numbers(env)
      Dir.glob(File.join(root(env), "*")).filter_map do |path|
        base = File.basename(path)
        base.to_i if base.match?(/\A\d+\z/) && File.file?(File.join(path, "manifest.json"))
      end.sort
    end

    # The generation the plugin path is on. Falls back to the highest known
    # one when the marker is missing or names something pruned — the newest
    # generation is what a fresh install would have left.
    def current(env)
      known = numbers(env)
      return nil if known.empty?

      path = File.join(root(env), "current")
      marked = File.file?(path) ? File.read(path).to_i : 0
      known.include?(marked) ? marked : known.last
    end

    # Bare `tempo rollback`: the generation immediately below the current one.
    def previous(env)
      cur = current(env)
      return nil unless cur

      numbers(env).select { |n| n < cur }.last
    end

    def manifest(env, number)
      path = File.join(dir(env, number), "manifest.json")
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    # Snapshot the current state as the next number. Called after the lock is
    # settled, so the generation stores the lock exactly as it sits on disk —
    # restoring it later is a byte copy, never a re-serialization that could
    # drift as the writer evolves.
    def file(env, op)
      number = (numbers(env).max || 0) + 1
      gen = dir(env, number)
      FileUtils.mkdir_p(gen)
      lock = File.file?(env.lockfile_path) ? File.read(env.lockfile_path) : ""
      File.write(File.join(gen, "tempo.lock"), lock)
      links, unmanaged = snapshot(env)
      write_atomic(File.join(gen, "manifest.json"), "#{JSON.pretty_generate({
        "version" => 1,
        "op" => op,
        "time" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "links" => links,
        "unmanaged" => unmanaged,
      })}\n")
      set_current(env, number)
      prune(env)
      number
    end

    # Flip the plugin path back onto a generation's symlink set, restore that
    # generation's lockfile bytes, regenerate the artifact and move the marker.
    # Each flip is `Store.link!` — temp symlink + rename — so an interrupted
    # rollback leaves every plugin on either its old or its new entry and never
    # on a half-written link. Filing a generation is *not* part of rolling
    # back: the marker moves, history stays put, and rolling back twice walks
    # further down rather than ping-ponging.
    def rollback(env, ui, number)
      man = manifest(env, number)
      unless man
        ui.err("no such generation: #{number}")
        return 1
      end

      links = man.fetch("links", {})
      unmanaged = man.fetch("unmanaged", [])
      links.each { |name, target| flip(env, ui, name, target) }
      unmanaged.each do |name|
        ui.warn(%(  "#{name}" left alone: it was a plain directory in generation #{number}))
      end
      # Rollback never edits tmux.conf, so a plugin declared after this
      # generation has nothing to roll back to. Say so; the next install/sync
      # is what resolves it — inventing a lock entry for it would not.
      Store.each_declared(env) do |name|
        next if links.key?(name) || unmanaged.include?(name)

        ui.warn(%(  "#{name}" is declared but not in generation #{number}; run install or sync))
      end

      restore_lock(env, number)
      Generator.new(env).generate
      set_current(env, number)
      ui.ok("rolled back to generation #{number}")
      ui.exit_code
    end

    # --- internals --------------------------------------------------------

    def flip(env, ui, name, target)
      if !File.directory?(target)
        # GC never reclaims an entry a kept generation names, so this is a
        # store someone deleted by hand rather than a retention bug.
        ui.err(%(  "#{name}" rollback fail: its store entry is gone))
      elsif Store.link!(env, name, target)
        ui.ok(%(  "#{name}" rolled back))
      else
        ui.err(%(  "#{name}" rollback fail))
      end
    end

    def restore_lock(env, number)
      path = File.join(dir(env, number), "tempo.lock")
      return unless File.file?(path)

      write_atomic(env.lockfile_path, File.read(path))
    end

    # The declared set only: a generation is a statement about the plugins the
    # config asked for. Symlinks into the store are the flippable part; a
    # plugin still living as a real directory (adoption declined, D24) is
    # recorded as unmanaged and skipped on rollback, because there is no second
    # copy of it to flip to.
    def snapshot(env)
      links = {}
      unmanaged = []
      prefix = "#{Store.root(env)}/"
      Store.each_declared(env) do |name|
        path = env.plugin_dir(name)
        if File.symlink?(path)
          target = File.readlink(path)
          if target.start_with?(prefix)
            links[name] = target
          else
            unmanaged << name
          end
        elsif File.directory?(path)
          unmanaged << name
        end
      end
      [links, unmanaged]
    end

    def set_current(env, number)
      write_atomic(File.join(root(env), "current"), "#{number}\n")
    end

    # Keep the newest KEEP. Rolling back does not need a special case here:
    # `prune` only ever runs from `file`, which has just marked the newest
    # generation current, and that generation records the links the rollback
    # left in place — so the state survives even when the *number* you rolled
    # back to ages out.
    def prune(env)
      known = numbers(env)
      keep = known.last(KEEP)
      (known - keep).each { |n| FileUtils.rm_rf(dir(env, n)) }
      gc(env, keep)
    end

    # Delete only store entries that no kept generation references AND that no
    # live plugin-path symlink resolves into. Both halves matter: the first
    # keeps every rollback target alive, the second protects an entry that is
    # in use right now but older than the oldest kept generation.
    def gc(env, keep)
      live = keep.flat_map { |n| (manifest(env, n) || {}).fetch("links", {}).values }
      live.concat(live_links(env))
      Dir.glob(File.join(Store.root(env), "*", "*")).each do |entry|
        next unless File.directory?(entry)
        next if live.include?(entry)

        FileUtils.rm_rf(entry)
      end
    end

    # Every symlink in the plugin path, declared or not: `clean` has not
    # necessarily run, and an undeclared-but-still-linked plugin needs its
    # entry on disk until it does.
    def live_links(env)
      Dir.glob(File.join(env.plugin_path, "*")).filter_map do |path|
        File.readlink(path) if File.symlink?(path)
      end
    end

    def write_atomic(path, body)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp#{Process.pid}"
      File.write(tmp, body)
      File.rename(tmp, path)
    end
  end
end
