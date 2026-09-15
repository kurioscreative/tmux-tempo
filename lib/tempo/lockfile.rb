# frozen_string_literal: true

require "json"

module Tempo
  # tempo.lock (D5): JSON map of plugin name → {url, branch, commit},
  # written next to the primary config file and designed to be committed to
  # dotfiles. `install` enforces it; `update` moves it forward. Legacy
  # @tpm_plugins entries lock identically to @plugin entries — they are the
  # same after parsing.
  #
  # Two writers, because the two verbs mean different things (D33). `update`
  # snapshots disk: it moved the plugins on purpose, so what is on disk is
  # the new truth. `install` reconciles: the lock is its *input*, and a run
  # may add an entry for a plugin it cloned and drop one for a plugin no
  # longer declared, but never rewrites an entry for a plugin that is still
  # declared — a failed clone or a failed restore must leave the pin exactly
  # where it was, or the lock is a log of what happened rather than a lock.
  class Lockfile
    def self.read(path)
      return {} unless File.file?(path)

      JSON.parse(File.read(path)).fetch("plugins", {})
    rescue JSON::ParserError
      {}
    end

    # Snapshot from disk: for every declared+installed plugin record the
    # origin URL, the pinned branch (null when unpinned), and HEAD.
    def self.write(env)
      plugins = {}
      env.specs.each do |spec|
        next if plugins.key?(spec.name)

        entry = observe(env, spec)
        plugins[spec.name] = entry if entry
      end
      persist(env, plugins)
    end

    # Lock as input: keep the existing entry of every plugin still declared,
    # verbatim; observe only plugins the lock has never seen. A declared
    # plugin that is neither locked nor installed (its clone failed) gets no
    # entry, and the next successful install records it.
    def self.reconcile(env)
      locked = read(env.lockfile_path)
      plugins = {}
      env.specs.each do |spec|
        next if plugins.key?(spec.name)

        entry = locked[spec.name] || observe(env, spec)
        plugins[spec.name] = entry if entry
      end
      persist(env, plugins)
    end

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
