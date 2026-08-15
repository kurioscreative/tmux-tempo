# frozen_string_literal: true

require "fileutils"

module Tempo
  # `tempo init`: wire this checkout into the user's tmux setup — no
  # installing, no network, no running tmux (file inspection only).
  #
  # Mode detection scans the candidate config files' run lines:
  # - a run line already resolving into this checkout -> nothing to do;
  # - a `run .../tpm/tpm` line -> drop-in: back up whatever occupies the
  #   tpm path and symlink this checkout there, config untouched;
  # - otherwise -> fresh: symlink <plugin-path>/tempo at this checkout and
  #   append the matching run line (creating a minimal config when none
  #   exists, backing up an existing one first).
  class Init
    def self.run(env, ui)
      new(env, ui).run
    end

    def initialize(env, ui)
      @env = env
      @ui = ui
      @root = File.expand_path("../..", __dir__)
    end

    def run
      targets = run_line_targets
      if targets.any? { |t| resolves_into_checkout?(t) }
        @ui.ok("Already set up: a run line in your tmux config points at this checkout. Nothing to do.")
        return 0
      end

      tpm_target = targets.find { |t| t.end_with?("/tpm/tpm") }
      tpm_target ? drop_in(File.dirname(tpm_target)) : fresh
    end

    private

    # Every run/run-shell target in the config files, quotes stripped and
    # `~`/$HOME expanded. This parsing is init-only surface: the
    # fingerprint scan (Scraper) intentionally knows nothing about run
    # lines.
    def run_line_targets
      @env.candidate_config_files.select { |f| File.file?(f) }.flat_map do |f|
        File.readlines(f).filter_map do |line|
          m = line.match(/\A\s*run(?:-shell)?\s+(?:-b\s+)?(.+?)\s*\z/)
          m && expand_home(m[1].sub(/\A(['"])(.*)\1\z/, '\2'))
        end
      end
    end

    # Same rule as Env: only a leading `~` or literal `$HOME`.
    def expand_home(path)
      path.sub(%r{\A~(?=/|\z)}, @env.home).sub(%r{\A\$HOME(?=/|\z)}, @env.home)
    end

    def resolves_into_checkout?(path)
      return false unless File.exist?(path)

      real = File.realpath(path)
      root = File.realpath(@root)
      real == root || real.start_with?("#{root}/")
    rescue Errno::ENOENT
      false
    end

    # The config already runs `.../tpm/tpm`: take over that path. The
    # config file is not touched; whatever occupies the path is renamed
    # aside — backed up regardless of content, it's reversible.
    def drop_in(tpm_dir)
      if File.exist?(tpm_dir) || File.symlink?(tpm_dir)
        backup = "#{tpm_dir}.orig-#{timestamp}"
        File.rename(tpm_dir, backup)
        @ui.ok("Backed up #{tpm_dir} -> #{backup}")
      end
      FileUtils.mkdir_p(File.dirname(tpm_dir))
      File.symlink(@root, tpm_dir)
      @ui.ok("Linked #{tpm_dir} -> #{@root}")
      @ui.ok("")
      @ui.ok("Done (drop-in mode): your tmux config was not changed.")
      @ui.ok("Reload tmux, then press prefix + I to install plugins.")
      0
    end

    def fresh
      link = File.join(@env.default_plugin_path, "tempo")
      return 1 unless ensure_link(link)

      write_run_line(link)
      @ui.ok("")
      @ui.ok("Done. Reload tmux (tmux source-file #{@env.user_conf}), then press prefix + I to install plugins.")
      0
    end

    # Fresh mode's canonical location. Present-but-foreign contents are a
    # refusal, not a repair: exit 1 and touch nothing — the user parked
    # something there on purpose.
    def ensure_link(link)
      if File.symlink?(link)
        return true if resolves_into_checkout?(link)

        @ui.err("#{link} is a symlink to something else. Move it aside and re-run init.")
        false
      elsif File.exist?(link)
        @ui.err("#{link} already exists and is not this checkout. Move it aside and re-run init.")
        false
      else
        FileUtils.mkdir_p(File.dirname(link))
        File.symlink(@root, link)
        @ui.ok("Linked #{link} -> #{@root}")
        true
      end
    end

    def write_run_line(link)
      conf = @env.user_conf
      line = "run '#{shorten_home(File.join(link, "tempo"))}'"
      if File.file?(conf)
        return @ui.ok("#{conf} already contains the run line.") if File.read(conf).include?(line)

        backup = "#{conf}.bak-#{timestamp}"
        FileUtils.cp(conf, backup) # cp, not rename: a symlinked conf must stay a symlink
        @ui.ok("Backed up #{conf} -> #{backup}")
        File.open(conf, "a") do |f| # appending writes through a symlinked conf
          f.puts("")
          f.puts("# Initialize the plugin manager (keep this at the very bottom of the config).")
          f.puts(line)
        end
      else
        FileUtils.mkdir_p(File.dirname(conf))
        File.write(conf, <<~CONF)
          # Created by `tempo init`. Declare plugins, then press prefix + I:
          #
          #   set -g @plugin 'tmux-plugins/tmux-sensible'

          # Initialize the plugin manager (keep this at the very bottom of the config).
          #{line}
        CONF
      end
      @ui.ok("Wrote #{line} to #{conf}")
    end

    def shorten_home(path)
      path.start_with?("#{@env.home}/") ? path.sub(@env.home, "~") : path
    end

    def timestamp
      Time.now.strftime("%Y%m%d-%H%M%S")
    end
  end
end
