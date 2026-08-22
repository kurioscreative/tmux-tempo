# frozen_string_literal: true

require "json"

module Tempo
  # tempo.lock (D5): JSON map of plugin name → {url, branch, commit},
  # written next to the primary config file on every mutating operation and
  # designed to be committed to dotfiles. `install` enforces it; `update`
  # moves it forward. Legacy @tpm_plugins entries lock identically
  # to @plugin entries — they are the same after parsing.
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
        next unless env.installed?(spec.name)

        dir = env.plugin_dir(spec.name)
        commit = Git.head_commit(dir)
        next unless commit

        plugins[spec.name] = {
          "url" => Git.remote_url(dir) || spec.url,
          "branch" => spec.branch,
          "commit" => commit,
        }
      end
      body = "#{JSON.pretty_generate({ "version" => 1, "plugins" => plugins })}\n"
      tmp = "#{env.lockfile_path}.tmp#{Process.pid}"
      File.write(tmp, body)
      File.rename(tmp, env.lockfile_path)
      plugins
    end
  end
end
