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
  #
  # Consent before mutation: the full plan — every rename, symlink and
  # config write, with final paths — is printed before anything happens,
  # and on a TTY init asks before executing (--yes skips; non-interactive
  # runs proceed). Each plan step pairs its printed description with the
  # action that performs it, so what is shown and what runs cannot drift.
  class Init
    # The basenames a plugin manager's entry script can have — tpm's own and
    # tempo's alias (D14). Everything else under a plugins directory is a
    # plugin someone is loading by hand.
    ENTRY_NAMES = %w[tpm tempo].freeze

    # A hand-written plugin load: a file two levels below a `plugins`
    # directory, i.e. `<plugin-path>/<name>/<entry>`.
    MANUAL_PLUGIN_RUN = %r{/plugins/[^/]+/}

    def self.run(env, ui, yes: false)
      new(env, ui).run(yes: yes)
    end

    def initialize(env, ui)
      @env = env
      @ui = ui
      @root = File.expand_path("../..", __dir__)
    end

    def run(yes: false)
      targets = run_line_targets
      if targets.any? { |t| resolves_into_checkout?(t) }
        @ui.ok("Already set up: a run line in your tmux config points at this checkout. Nothing to do.")
        return 0
      end

      tpm_target = targets.find { |t| t.end_with?("/tpm/tpm") }
      plan = tpm_target ? drop_in_plan(File.dirname(tpm_target)) : fresh_plan
      return 1 unless plan # refusal already reported

      steps, epilogue = plan
      @ui.ok("tempo init will:")
      steps.each { |desc, _action| @ui.ok("  - #{desc}") }
      migration_hint(targets)
      unless yes || confirmed?
        @ui.ok("Aborted: nothing was changed.")
        return 1
      end

      steps.each { |_desc, action| action.call }
      @ui.ok("")
      epilogue.each { |line| @ui.ok(line) }
      0
    end

    private

    # The config already runs `.../tpm/tpm`: take over that path. The
    # config file is not touched; whatever occupies the path is renamed
    # aside — backed up regardless of content, it's reversible. The no-op
    # last step exists so the plan states the config promise explicitly.
    def drop_in_plan(tpm_dir)
      steps = []
      if File.exist?(tpm_dir) || File.symlink?(tpm_dir)
        backup = "#{tpm_dir}.orig-#{timestamp}"
        steps << ["rename #{tpm_dir} -> #{backup} (backup, kept)",
                  -> { File.rename(tpm_dir, backup) }]
      end
      steps << ["symlink #{tpm_dir} -> #{@root}", lambda do
        FileUtils.mkdir_p(File.dirname(tpm_dir))
        File.symlink(@root, tpm_dir)
      end]
      steps << ["not modify your tmux config", -> {}]
      [steps, [
        "Done (drop-in mode): your tmux config was not changed.",
        "Reload tmux, then press prefix + I to install plugins.",
      ]]
    end

    # Fresh mode's canonical location. Present-but-foreign contents are a
    # refusal (nil), not a repair: exit 1 and touch nothing — the user
    # parked something there on purpose.
    def fresh_plan
      link = File.join(@env.default_plugin_path, "tempo")
      steps = []
      if File.symlink?(link)
        unless resolves_into_checkout?(link)
          @ui.err("#{link} is a symlink to something else. Move it aside and re-run init.")
          return nil
        end
      elsif File.exist?(link)
        @ui.err("#{link} already exists and is not this checkout. Move it aside and re-run init.")
        return nil
      else
        steps << ["symlink #{link} -> #{@root}", lambda do
          FileUtils.mkdir_p(File.dirname(link))
          File.symlink(@root, link)
        end]
      end

      conf = @env.user_conf
      line = "run '#{shorten_home(File.join(link, "tempo"))}'"
      if !File.file?(conf)
        steps << ["create #{conf} containing: #{line}",
                  -> { write_minimal_conf(conf, line) }]
      elsif !File.read(conf).include?(line)
        backup = "#{conf}.bak-#{timestamp}"
        # cp, not rename: a symlinked conf must stay a symlink
        steps << ["copy #{conf} -> #{backup} (backup, kept)",
                  -> { FileUtils.cp(conf, backup) }]
        steps << ["append to #{conf}: #{line}",
                  -> { append_run_line(conf, line) }]
      end
      [steps, [
        "Done. Reload tmux (tmux source-file #{conf}), then press prefix + I to install plugins.",
      ]]
    end

    # Run lines that load a plugin by hand are the shape tempo replaces with
    # `@plugin` declarations, and a user who migrates without noticing them
    # sees an empty plugin list afterwards and concludes tempo lost their
    # plugins (friction log #2). So the plan names them — and stops there:
    # init edits no run line it did not write, which is why this prints
    # alongside the plan rather than becoming a step. A target resolving into
    # this checkout cannot reach here; `run` has already returned on those.
    def migration_hint(targets)
      manual = targets.select do |t|
        MANUAL_PLUGIN_RUN.match?(t) && !ENTRY_NAMES.include?(File.basename(t))
      end
      return if manual.empty?

      @ui.ok("")
      @ui.ok("These look like manually loaded plugins (init leaves them exactly as they are):")
      manual.each { |t| @ui.ok("  - #{shorten_home(t)}") }
      @ui.ok("After init, declare each one — set -g @plugin '<owner/repo>', or `tempo add <owner/repo>` —")
      @ui.ok("and delete its run line.")
    end

    # TTY-gated consent: scripts and CI (no TTY) proceed, matching the
    # pre-prompt behavior the flows and acceptance gates pin.
    def confirmed?
      return true unless $stdin.tty?

      $stdout.print("Proceed? [y/N] ")
      $stdout.flush
      $stdin.gets.to_s.strip.match?(/\Ay(es)?\z/i)
    end

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

    def append_run_line(conf, line)
      File.open(conf, "a") do |f| # appending writes through a symlinked conf
        f.puts("")
        f.puts("# Initialize the plugin manager (keep this at the very bottom of the config).")
        f.puts(line)
      end
    end

    def write_minimal_conf(conf, line)
      FileUtils.mkdir_p(File.dirname(conf))
      File.write(conf, <<~CONF)
        # Created by `tempo init`. Declare plugins, then press prefix + I:
        #
        #   set -g @plugin 'tmux-plugins/tmux-sensible'

        # Initialize the plugin manager (keep this at the very bottom of the config).
        #{line}
      CONF
    end

    def shorten_home(path)
      path.start_with?("#{@env.home}/") ? path.sub(@env.home, "~") : path
    end

    def timestamp
      Time.now.strftime("%Y%m%d-%H%M%S")
    end
  end
end
