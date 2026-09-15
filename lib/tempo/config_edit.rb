# frozen_string_literal: true

require "fileutils"

module Tempo
  # `tempo add` / `tempo remove` (D22). There is no manifest: the tmux config
  # *is* the plugin list, so these two commands edit it — and only in ways
  # that can be stated exactly.
  #
  # `add` appends one canonical line (Spec.plugin_line) and installs.
  # `remove` deletes a declaration only when it can fully parse it, and
  # refuses everything else loudly, with the `file:line` it refused and an
  # instruction to remove it by hand. Nothing here rewrites a line it did not
  # write: a hand-tuned config is the user's file, and a wrong edit in it is
  # unrecoverable trust.
  class ConfigEdit
    # The parser half of the scraper's detector. Scraper::PLUGIN_LINE finds
    # *candidates* deliberately loosely (it matches `@plugins` prefixes and
    # ignores everything after field 4, exactly like the original awk); this
    # must consume a whole line or admit that it cannot. A line the detector
    # finds and this does not fully parse is a refusal, never a guess.
    DECLARATION = /
      \A[ \t]*set(?:-option)?[ \t]+-g[ \t]+@plugin[ \t]+
      (?:'([^']*)'|"([^"]*)"|([^\s'"\#]+))[ \t]*\z
    /x

    # The legacy option is never edited (D22) — it is only ever *found*, so
    # the refusal can cite the line the user has to edit themselves.
    LEGACY_LINE = /\A[ \t]*set(?:-option)?[ \t]+-g[ \t]+@tpm_plugins[ \t]+(.*)\z/

    # tmux conditionals are tracked for depth only, never evaluated: the
    # single question is "is this match inside one?", and the answer is
    # always a refusal.
    CONDITIONAL_OPEN = /\A[ \t]*%if\b/
    CONDITIONAL_CLOSE = /\A[ \t]*%endif\b/

    BY_HAND = "remove it by hand"

    # One declaration found in one file. `kind` is what the line is, not what
    # the user asked for: :plugin (fully parsed), :legacy (@tpm_plugins
    # membership) or :unparseable (looks like a declaration, isn't one this
    # code will touch).
    Decl = Struct.new(:file, :line, :text, :raw, :kind, :conditional, keyword_init: true) do
      def cite
        "#{file}:#{line}"
      end

      # Every spec this line declares, counted the way the scraper counts
      # them: the parsed value for a plain @plugin line, the whole word list
      # for @tpm_plugins, and the original awk's field-4 fallback for a line
      # tempo cannot fully parse — it still declares something, which is
      # precisely why removing it must be refused rather than ignored.
      def raw_specs
        case kind
        when :plugin then [raw]
        when :legacy then raw.split(/\s+/).reject(&:empty?)
        else [text.delete(%('")).split[3]].compact
        end
      end

      # Name or verbatim spec, both accepted: users type whichever they have
      # in front of them.
      def matches?(target)
        raw_specs.any? { |r| r == target || Spec.parse(r).name == target }
      end
    end

    def self.add(env, ui, args)
      new(env, ui).add(args)
    end

    def self.remove(env, ui, args)
      new(env, ui).remove(args)
    end

    def initialize(env, ui)
      @env = env
      @ui = ui
    end

    # --- add ---------------------------------------------------------------

    def add(args)
      raws = args.reject { |a| a.start_with?("-") }
      if raws.empty?
        @ui.err("usage: tempo add <owner/repo|url|path>[#branch]...")
        return 1
      end

      # One backup per invocation, taken before the first edit. Backing up
      # inside the per-spec append gave `add a b` two copies with the same
      # per-second timestamp: the second overwrote the first, and the
      # survivor already contained `a`. A backup is the pre-invocation
      # state or it is not a backup.
      conf = @env.user_conf
      backup = back_up(conf) if raws.any? { |raw| declaration_for(raw).nil? }

      # A list: the spec grammar is uniform, and silently dropping every
      # argument but the first is not a thing a CLI may do.
      raws.each do |raw|
        existing = declaration_for(raw)
        if existing
          @ui.ok(%(Already declared "#{raw}" (#{existing.cite})))
        else
          append(raw)
        end
      end
      @ui.ok("Backed up #{conf} -> #{backup}") if backup
      # The scan behind `specs` is memoized per Env, so the install must run
      # against a fresh one or it would not see the line just written.
      Commands.install(@env.reload, @ui)
    end

    # --- remove ------------------------------------------------------------

    def remove(args)
      target = args.find { |a| !a.start_with?("-") }
      unless target
        @ui.err("usage: tempo remove <name-or-spec>")
        return 1
      end

      matches = declarations.select { |d| d.matches?(target) }
      return undeclared(target) if matches.empty?

      refusals = matches.reject { |d| removable?(d) }
      return refuse(refusals) unless refusals.empty?

      delete_lines(matches)
    end

    private

    # --- the scan ----------------------------------------------------------

    # Every declaration in every file tmux would read, in file order,
    # following `source-file` includes exactly as the fingerprint scan does.
    # The candidate set is the *search* scope (so a declaration in
    # /etc/tmux.conf can be cited); only `user_conf` is ever written.
    def declarations
      @declarations ||= begin
        @resolver = Scraper.new([], home: @env.home)
        @visited = {}
        @found = []
        @env.candidate_config_files.each { |f| scan_file(f) }
        @found
      end
    end

    def scan_file(path)
      abs = File.expand_path(path)
      return if @visited[abs]

      @visited[abs] = true
      return unless File.file?(abs)

      depth = 0
      File.foreach(abs).with_index(1) do |line, number|
        if CONDITIONAL_OPEN.match?(line)
          depth += 1
        elsif CONDITIONAL_CLOSE.match?(line)
          depth -= 1 if depth.positive?
        elsif Scraper::PLUGIN_LINE.match?(line)
          @found << plugin_decl(abs, number, line, depth)
        elsif (m = LEGACY_LINE.match(line.chomp))
          @found << Decl.new(file: abs, line: number, text: line.chomp, raw: m[1].delete(%('")).strip,
                             kind: :legacy, conditional: depth.positive?)
        elsif (m = Scraper::SOURCE_LINE.match(line))
          @resolver.resolve_sourced(m[3].strip).each { |p| scan_file(p) }
        end
      end
    rescue SystemCallError, ArgumentError # unreadable file / invalid bytes
      nil
    end

    def plugin_decl(abs, number, line, depth)
      m = DECLARATION.match(line.chomp)
      raw = m && (m[1] || m[2] || m[3])
      Decl.new(file: abs, line: number, text: line.chomp, raw: raw.to_s,
               kind: raw.to_s.empty? ? :unparseable : :plugin, conditional: depth.positive?)
    end

    # --- add helpers -------------------------------------------------------

    def declaration_for(raw)
      declarations.find { |d| d.raw_specs.include?(raw) }
    end

    # tpm convention — and init's own "keep this at the very bottom of the
    # config" comment — put the manager's run line last, so a plain EOF
    # append lands the declaration *below* the line that loads it. That is
    # harmless to tempo (the scraper reads the whole file) and reads as a
    # mistake to anyone tpm-literate, so the declaration goes immediately
    # above the last run line that loads the manager. A config with no such
    # line (a sourced snippet, a conf tempo has never wired) still appends.
    def append(raw)
      conf = @env.user_conf
      FileUtils.mkdir_p(File.dirname(conf))
      decl = Spec.plugin_line(raw)
      lines = File.file?(conf) ? File.readlines(conf) : []
      at = lines.rindex { |l| Init.manager_run_line?(l.chomp) }
      if at
        lines.insert(at, "#{decl}\n")
        # Truncating in place writes through a symlinked conf; replacing the
        # file would replace the link (D11/D14).
        File.open(conf, "w") { |f| f.write(lines.join) }
      else
        # Append mode follows a symlinked conf to the real file and writes
        # there; the link itself is never replaced (D11/D14).
        File.open(conf, "a") do |f|
          f.puts("") if needs_leading_newline?(conf)
          f.puts(decl)
        end
      end
      @ui.ok("Added to #{conf}: #{decl}")
      @declarations = nil # a second spec in the same run must see this one
    end

    # A config whose last byte is not a newline would otherwise get the
    # declaration glued onto the user's last line.
    def needs_leading_newline?(conf)
      File.size?(conf) && !File.read(conf).end_with?("\n")
    end

    # --- remove helpers ----------------------------------------------------

    def removable?(decl)
      decl.kind == :plugin && !decl.conditional && same_file?(decl.file, @env.user_conf)
    end

    def undeclared(target)
      @ui.err(%(no @plugin declaration for "#{target}" in #{@env.user_conf} or any file it sources))
      1
    end

    def refuse(refusals)
      @ui.err("tempo remove: refusing to edit this declaration")
      refusals.each do |d|
        @ui.err("  #{d.cite}: #{d.text.strip}")
        @ui.err("      #{reason(d)} — #{BY_HAND}.")
      end
      1
    end

    def reason(decl)
      if decl.kind == :legacy
        "the legacy @tpm_plugins list is never edited by tempo"
      elsif decl.conditional
        "it is inside a %if block, which tempo does not evaluate"
      elsif !same_file?(decl.file, @env.user_conf)
        "it is not in your primary config (#{@env.user_conf})"
      else
        "tempo cannot fully parse it as a plain @plugin declaration"
      end
    end

    # Whole lines only, by line number, so a comment that happens to mention
    # the plugin is untouched.
    def delete_lines(matches)
      conf = @env.user_conf
      doomed = matches.map(&:line)
      lines = File.readlines(conf)
      backup = back_up(conf)
      # Truncating in place writes through a symlinked conf; replacing the
      # file would replace the link.
      File.open(conf, "w") do |f|
        lines.each_with_index { |line, i| f.write(line) unless doomed.include?(i + 1) }
      end
      matches.each { |d| @ui.ok("Removed #{d.cite}: #{d.text.strip}") }
      @ui.ok("Backed up #{conf} -> #{backup}") if backup
      @ui.ok("Its files are still installed — run `tempo clean` to delete them.")
      0
    end

    # --- shared ------------------------------------------------------------

    # init's scheme (D14): a timestamped *copy*, because a symlinked conf must
    # stay a symlink. Returns the backup path, or nil when there was no file
    # to back up yet.
    def back_up(conf)
      return nil unless File.file?(conf)

      backup = "#{conf}.bak-#{Time.now.strftime("%Y%m%d-%H%M%S")}"
      FileUtils.cp(conf, backup)
      backup
    end

    def same_file?(a, b)
      File.realpath(a) == File.realpath(b)
    rescue SystemCallError
      File.expand_path(a) == File.expand_path(b)
    end
  end
end
