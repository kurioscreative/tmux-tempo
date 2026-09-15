# frozen_string_literal: true

require "open3"
require "json"

module Tempo
  # `tempo doctor`: one line per fact a first-run problem report needs.
  # Hard requirements (tmux >= 1.9 present, git present) report through
  # ui.err so a failure exits 1; everything else is informational and
  # reports through ui.ok regardless of state.
  class Doctor
    def self.run(env, ui)
      new(env, ui).run
    end

    def initialize(env, ui)
      @env = env
      @ui = ui
    end

    def run
      check_tmux
      check_ruby
      check_git
      report_plugin_path
      report_configs
      report_plugins
      report_artifact
      report_lockfile
      @ui.exit_code
    end

    private

    def check_tmux
      out, ok = Tmux.run("-V")
      unless ok
        @ui.err("tmux:        not found in PATH — FAIL (tempo requires tmux >= 1.9)")
        return
      end
      version = out.strip.sub(/\Atmux\s*/, "")
      if tmux_supported?(version)
        @ui.ok("tmux:        #{version} — OK (>= 1.9 required)")
      else
        @ui.err("tmux:        #{version} — FAIL (>= 1.9 required)")
      end
    end

    # Same outcome as tmux_version_supported in scripts/helpers.sh:
    # unparseable versions ("master", "next-3.6") count as supported.
    def tmux_supported?(version)
      m = version.match(/(\d+)(?:\.(\d+))?/)
      return true unless m

      major = m[1].to_i
      minor = m[2].to_i
      major > 1 || (major == 1 && minor >= 9)
    end

    def check_ruby
      verdict = RUBY_VERSION.split(".").first.to_i >= 3 ? "OK" : "FAIL"
      @ui.ok("ruby:        #{RUBY_VERSION} — #{verdict} (>= 3.0 required)")
    end

    def check_git
      out, status = Open3.capture2e("git", "--version")
      if status.success?
        @ui.ok("git:         #{out.strip} — OK")
      else
        @ui.err("git:         found but not working — FAIL")
      end
    rescue Errno::ENOENT
      @ui.err("git:         not found in PATH — FAIL (install/update/clean need git)")
    end

    def report_plugin_path
      path = @env.plugin_path
      state =
        if !File.directory?(path) then "will be created on first install"
        elsif File.writable?(path) then "exists, writable"
        else "exists, NOT writable"
        end
      @ui.ok("plugin path: #{path} (#{state})")
    end

    def report_configs
      found, missing = @env.candidate_config_files.partition { |f| File.file?(f) }
      if found.empty?
        @ui.ok("configs:     none found (checked #{missing.size} locations)")
      else
        @ui.ok("configs:     #{found.join(", ")}")
      end
    end

    # Hard fail (D34): if the declared set cannot be observed, no management
    # operation can work, which is what doctor's exit code means.
    def report_plugins
      names = @env.specs.map(&:name).uniq
      installed = names.count { |n| @env.installed?(n) }
      @ui.ok("plugins:     #{names.size} declared, #{installed} installed")
    rescue ObserverError => e
      @ui.err("plugins:     cannot be determined — #{e.message} — FAIL")
    end

    def report_artifact
      state =
        if !File.file?(@env.artifact_path) || !File.file?(@env.fingerprint_path)
          "not yet generated (created on first install, or run: tempo generate)"
        elsif File.read(@env.fingerprint_path) == Generator.new(@env).fingerprint_body
          "fresh"
        else
          "stale (regenerates on next tmux start or install/update/clean)"
        end
      @ui.ok("artifact:    #{@env.artifact_path} — #{state}")
    rescue ObserverError
      # report_plugins already failed the run for this; the report goes on.
      @ui.ok("artifact:    #{@env.artifact_path} — freshness unknown (the declared set could not be observed)")
    end

    def report_lockfile
      path = @env.lockfile_path
      state =
        if File.file?(path)
          begin
            JSON.parse(File.read(path))
            "OK (#{Lockfile.read(path).size} plugins locked)"
          rescue JSON::ParserError
            "UNPARSEABLE (treated as empty)"
          end
        else
          "not yet written (created by the first install with a plugin to record)"
        end
      @ui.ok("lockfile:    #{path} — #{state}")
    end
  end
end
