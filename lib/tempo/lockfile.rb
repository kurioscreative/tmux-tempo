# frozen_string_literal: true

require "json"

module Tempo
  # tempo.lock (D5): JSON map of plugin name → {url, branch, commit},
  # written next to the primary config file and designed to be committed to
  # dotfiles. `install` enforces it; `update` moves it forward. Legacy
  # @tpm_plugins entries lock identically to @plugin entries — they are the
  # same after parsing.
  #
  # The lock is an input, never a snapshot (D33). A run carries every entry
  # for a still-declared plugin over verbatim, observes an entry only for a
  # declared plugin the lock has never seen, and drops the entries of plugins
  # no longer declared (the same run just cleaned them). The one way a pin
  # moves is `refresh`: the plugins `update` actually updated, which the run
  # moved on purpose. Anything else — a failed clone, a failed restore, a
  # plugin the observer could not see — leaves the pin exactly where it was,
  # or the lock is a log of what happened rather than a lock.
  class Lockfile
    # The lock exists but does not parse — merge-conflict markers after a
    # dotfiles pull are the realistic case. Reading it as {} would make every
    # declared plugin "never seen" and re-snapshot disk over the user's file
    # at exit 0 (D35): the third observer with the empty-on-failure shape.
    class Unparseable < StandardError; end

    REMEDY = "resolve it by hand, or restore it from your dotfiles history"

    def self.read(path)
      return {} unless File.file?(path)

      doc = JSON.parse(File.read(path))
      plugins = doc.is_a?(Hash) ? doc.fetch("plugins", {}) : nil
      # Valid JSON in the wrong shape would otherwise surface as a TypeError
      # backtrace out of restore_locked — a crash, not a refusal.
      unless plugins.is_a?(Hash) && plugins.values.all?(Hash)
        raise Unparseable, "#{path} is not a tempo lockfile (expected {\"plugins\": {name: {url, branch, commit}}}); #{REMEDY}"
      end

      plugins
    rescue JSON::ParserError => e
      raise Unparseable, "#{path} cannot be parsed (#{e.message.lines.first.to_s.strip[0, 80]}); #{REMEDY}"
    end

    # `refresh` names the plugins whose pin this run moved on purpose. A
    # declared plugin that is neither locked nor installed (its clone failed)
    # gets no entry, and the next successful install records it.
    def self.write(env, refresh = [])
      locked = read(env.lockfile_path)
      plugins = {}
      env.specs.each do |spec|
        next if plugins.key?(spec.name)

        entry = locked[spec.name]
        entry = observe(env, spec) if entry.nil? || refresh.include?(spec.name)
        plugins[spec.name] = entry if entry
      end
      persist(env, plugins)
    end

    # What disk says about one plugin: origin URL, the declared branch (null
    # when unpinned), and HEAD. Nil when there is nothing to record.
    def self.observe(env, spec)
      return nil unless env.installed?(spec.name)

      dir = env.plugin_dir(spec.name)
      commit = Git.head_commit(dir)
      return nil unless commit

      {
        "url" => Git.remote_url(dir) || spec.url,
        "branch" => spec.branch,
        "commit" => commit,
      }
    end

    def self.persist(env, plugins)
      body = "#{JSON.pretty_generate({ "version" => 1, "plugins" => plugins })}\n"
      tmp = "#{env.lockfile_path}.tmp#{Process.pid}"
      File.write(tmp, body)
      File.rename(tmp, env.lockfile_path)
      plugins
    end
  end
end
