# frozen_string_literal: true

require "fileutils"

module Tempo
  # First-install consent (D23). Cloning a source this host has never seen is
  # the moment a user decides to run someone else's code as themselves on
  # every tmux start, so the tempo CLI asks — once per resolved URL, per host.
  #
  # The scope is deliberately narrow (D23 as amended, compat-forced): only the
  # tempo CLI gates. The compat bins and the prefix+I/U bindings export a
  # marker env var and are handed *no gate object at all* — `gate` returns nil
  # and `install_missing` skips the check entirely. Making the bypass the
  # absence of the collaborator, rather than a quiet mode inside it, is what
  # keeps contract-mode output byte-identical by construction: there is no
  # branch in here that could ever print on that path.
  class Trust
    # Either marker means "this invocation is impersonating tpm".
    # TEMPO_TMUX_ECHO is already exported by bindings/install_plugins.
    MARKERS = %w[TEMPO_CONTRACT TEMPO_TMUX_ECHO].freeze

    HEADER = <<~TEXT
      # tempo trusted sources: one URL per line, '#' starts a comment.
      # Written by the install/sync trust prompt and by `tempo trust`.
      # Delete a line to be asked about that source again.
    TEXT

    # nil = ungated.
    def self.gate(env, yes: false)
      return nil if MARKERS.any? { |m| !ENV[m].to_s.empty? }

      new(env, yes: yes)
    end

    # `tempo trust <name-or-url>...` — record without installing anything.
    def self.run(env, ui, args)
      targets = args.reject { |a| a.start_with?("-") }
      if targets.empty?
        ui.err("usage: tempo trust <name-or-url>...")
        return 1
      end

      trust = new(env)
      targets.each do |target|
        urls = trust.urls_for(target)
        if urls.empty?
          ui.err(%(no declared plugin named "#{target}"))
        else
          trust.record(urls)
          urls.each { |u| ui.ok("trusted #{u}") }
        end
      end
      ui.exit_code
    end

    def initialize(env, yes: false, tty: $stdin.tty?)
      @env = env
      @yes = yes
      @tty = tty
      @decided = {} # one answer per URL per run; duplicate specs must not re-ask
    end

    def path
      File.join(@env.data_dir, "trusted_urls")
    end

    def trusted
      File.readlines(path, chomp: true).map { |l| l.sub(/#.*/, "").strip }.reject(&:empty?)
    rescue Errno::ENOENT
      []
    end

    def trusted?(url)
      trusted.include?(url)
    end

    # Whole-file rewrite through a temp file + rename. An interrupted append
    # must never leave a half-written line in a file the user is invited to
    # read and edit by hand.
    def record(urls)
      missing = urls - trusted
      return if missing.empty?

      FileUtils.mkdir_p(File.dirname(path))
      body = File.exist?(path) ? File.read(path) : HEADER
      body += "\n" unless body.empty? || body.end_with?("\n")
      tmp = "#{path}.#{Process.pid}"
      File.write(tmp, body + missing.join("\n") + "\n")
      File.rename(tmp, path)
    end

    # The gate itself: true means "go ahead and clone". Every message rides
    # `ui`, so the failure accounting (and therefore the exit code) is the
    # same one every other per-plugin failure uses.
    def allow?(spec, ui)
      urls = candidate_urls(spec)
      return true if urls.any? { |u| trusted?(u) }
      return @decided[urls.first] if @decided.key?(urls.first)

      @decided[urls.first] = decide(spec, urls, ui)
    end

    # What the user must see, because it is what git will actually be handed:
    # the verbatim URL, plus the GitHub expansion Git.clone_plugin falls back
    # to. Approving records both forms, so a shorthand spec cannot prompt
    # again on the run where the fallback is the arm that succeeds.
    def candidate_urls(spec)
      return [spec.url] unless shorthand?(spec.url)

      [spec.url, spec.github_shorthand_url]
    end

    # "user/repo" and nothing else — exactly the shape the GitHub expansion
    # is meaningful for. Anything with a scheme, a host or a path is verbatim.
    def shorthand?(url)
      url.match?(%r{\A[\w.-]+/[\w.-]+\z})
    end

    # A declaration (anything with a `/` or `:`) is trusted as written; a bare
    # word is looked up among the declared plugins by name. Only the bare-word
    # case reads the config, so `tempo trust <url>` needs no tmux at all.
    def urls_for(target)
      return candidate_urls(Spec.parse(target)) if target.include?("/") || target.include?(":")

      spec = @env.specs.find { |s| s.name == target }
      spec ? candidate_urls(spec) : []
    end

    private

    def decide(spec, urls, ui)
      if @yes
        record(urls)
        return true
      end
      return skip(spec, urls, ui) unless @tty

      ui.ok(preamble(urls))
      $stdout.print(%(Trust this source and install "#{spec.name}"? [y/N] ))
      $stdout.flush
      return declined(spec, ui) unless $stdin.gets.to_s.strip.match?(/\Ay(es)?\z/i)

      record(urls)
      true
    end

    def preamble(urls)
      (["", "tempo has never installed from this source on this host:", ""] +
        urls.map { |u| "  #{u}" } +
        ["", "A tmux plugin runs as you, with your files and your network,", "every time tmux starts."]).join("\n")
    end

    def declined(spec, ui)
      ui.err(%(  "#{spec.name}" skipped: source not trusted))
      false
    end

    # No terminal to ask at: say what was skipped, show the URL anyway, and
    # name both ways forward. This is an `err`, so the run exits non-zero.
    def skip(spec, urls, ui)
      lines = [%(  "#{spec.name}" skipped: source not trusted on this host)]
      lines += urls.map { |u| "      #{u}" }
      lines << "      approve it with `tempo trust #{spec.name}`, or re-run with --yes"
      ui.err(lines.join("\n"))
      false
    end
  end
end
