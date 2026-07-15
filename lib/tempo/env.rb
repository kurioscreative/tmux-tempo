# frozen_string_literal: true

module Tempo
  # Resolves every piece of machine state the commands need (paths, the
  # live @tpm_plugins option, the declared plugin list). Memoized, and every
  # value is overridable via the constructor so tests never need tmux.
  class Env
    ENV_VAR = "TMUX_PLUGIN_MANAGER_PATH"

    def initialize(**overrides)
      @overrides = overrides
    end

    def home
      @overrides[:home] || Dir.home
    end

    def xdg_conf
      base = ENV["XDG_CONFIG_HOME"].to_s.empty? ? File.join(home, ".config") : ENV["XDG_CONFIG_HOME"]
      File.join(base, "tmux", "tmux.conf")
    end

    # tpm's rule: the XDG config if it exists, else ~/.tmux.conf. Used for
    # live reloads and as the lockfile anchor ("primary config file").
    def user_conf
      @overrides[:user_conf] || (File.file?(xdg_conf) ? xdg_conf : File.join(home, ".tmux.conf"))
    end

    def default_plugin_path
      if File.file?(xdg_conf)
        "#{File.join(File.dirname(xdg_conf), "plugins")}/"
      else
        "#{File.join(home, ".tmux", "plugins")}/"
      end
    end

    # TMUX_PLUGIN_MANAGER_PATH as a tmux global environment variable,
    # forced trailing slash on use; the stored value round-trips unmodified.
    # When unset the CLI falls back to the bootstrap default instead of
    # fatal-aborting (intentional divergence 2 — this is what makes the
    # verbatim auto-install snippet finally work).
    def plugin_path
      @plugin_path ||= @overrides[:plugin_path] || resolve_plugin_path
    end

    def tpm_plugins_option
      @tpm_plugins_option ||= @overrides[:tpm_plugins_option] || Tmux.option("@tpm_plugins")
    end

    def candidate_config_files
      @overrides[:candidate_config_files] || default_candidate_config_files
    end

    def scan
      @scan ||= Scraper.new(candidate_config_files, home: home).scan
    end

    # Ordered spec list: legacy @tpm_plugins first, then scraped @plugin
    # lines — the original's order, duplicates and all.
    def specs
      @specs ||= begin
        raw = @overrides[:specs] ||
              (tpm_plugins_option.split(/\s+/).reject(&:empty?) + scan.plugin_specs)
        raw.map { |r| Spec.parse(r) }.reject { |s| s.url.empty? }
      end
    end

    def plugin_dir(name)
      File.join(plugin_path, name)
    end

    # Same test as the original: the directory exists and answers to git.
    def installed?(name)
      dir = plugin_dir(name)
      File.directory?(dir) &&
        system("git", "-C", dir, "remote", out: File::NULL, err: File::NULL)
    end

    def data_dir
      @overrides[:data_dir] || begin
        base = ENV["XDG_DATA_HOME"].to_s.empty? ? File.join(home, ".local", "share") : ENV["XDG_DATA_HOME"]
        File.join(base, "tempo")
      end
    end

    def artifact_path
      File.join(data_dir, "load.sh")
    end

    def fingerprint_path
      File.join(data_dir, "fingerprint")
    end

    def lockfile_path
      @overrides[:lockfile_path] || File.join(File.dirname(user_conf), "tempo.lock")
    end

    private

    def resolve_plugin_path
      raw = Tmux.global_env(ENV_VAR)
      if raw.nil? || raw.empty?
        default = default_plugin_path
        Tmux.set_global_env(ENV_VAR, default) # only-if-unset, like the bootstrap
        default
      else
        expanded = expand_home(raw)
        expanded.end_with?("/") ? expanded : "#{expanded}/"
      end
    end

    # The original expands only a leading `~` or literal `$HOME`.
    def expand_home(path)
      path.sub(%r{\A~(?=/|\z)}, home).sub(%r{\A\$HOME(?=/|\z)}, home)
    end

    # The full default-config list tmux itself loads (system conf variants,
    # ~/.tmux.conf, XDG) — a strict superset of tpm's either/or rule; see
    # docs/tmux/00-overview.md §3.
    def default_candidate_config_files
      list = [
        "/etc/tmux.conf",
        "/opt/homebrew/etc/tmux.conf",
        "/usr/local/etc/tmux.conf",
        File.join(home, ".tmux.conf"),
      ]
      list << File.join(ENV["XDG_CONFIG_HOME"], "tmux", "tmux.conf") unless ENV["XDG_CONFIG_HOME"].to_s.empty?
      list << File.join(home, ".config", "tmux", "tmux.conf")
      list.uniq
    end
  end
end
