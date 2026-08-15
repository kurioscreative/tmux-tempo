# frozen_string_literal: true

module Tempo
  # Scrapes @plugin declarations from config file text — never from live
  # options (the legacy @tpm_plugins option is read live by Env, matching
  # the original). Follows source/source-file includes recursively (a
  # strict superset of tpm's one-level scan) and records a fingerprint
  # entry for every path consulted — existing or not — so the sh hot path
  # can detect staleness without Ruby.
  class Scraper
    Result = Struct.new(:plugin_specs, :entries, keyword_init: true)
    FileEntry = Struct.new(:path, :exists, :mtime, :size, keyword_init: true)

    # Anchored exactly like the original awk matcher; field 4 of the
    # quote-stripped line is the spec. Deliberately no word boundary after
    # @plugin: the original matches prefixes like `@plugins` too, and
    # accepting less than the original is the only real breakage.
    PLUGIN_LINE = /^[ \t]*set(-option)?[ \t]+-g[ \t]+@plugin/
    SOURCE_LINE = /^[ \t]*source(-file)?[ \t]+((?:-\w+[ \t]+)*)(.+)$/

    def initialize(candidate_files, home: Dir.home)
      @candidates = candidate_files
      @home = home
      @specs = []
      @entries = []
      @visited = {}
    end

    def scan
      @specs = []
      @entries = []
      @visited = {}
      @candidates.each { |path| scan_file(path) }
      Result.new(plugin_specs: @specs, entries: @entries)
    end

    # Public because ConfigEdit walks the same include graph to cite a
    # declaration's file:line, and include resolution must have exactly one
    # dialect (quoting, ~/$VAR expansion, globs) — the same rule the plugin
    # matcher follows.
    def resolve_sourced(rest)
      path =
        case rest[0]
        when "'" then rest[1..].split("'", 2)[0]
        when '"' then rest[1..].split('"', 2)[0]
        else rest.split(/[ \t]+/).first
        end
      return [] if path.nil? || path.empty?

      expanded = expand(path)
      if expanded.match?(/[*?\[]/)
        record_dir(File.dirname(expanded))
        Dir.glob(expanded).sort
      else
        [expanded]
      end
    end

    private

    def scan_file(path)
      abs = File.expand_path(path)
      return if @visited[abs]

      @visited[abs] = true
      record(abs)
      return unless File.file?(abs)

      File.foreach(abs) do |line|
        if PLUGIN_LINE.match?(line)
          # awk: gsub quotes away, take $4
          spec = line.delete(%('")).split[3]
          @specs << spec if spec && !spec.empty?
        elsif (m = SOURCE_LINE.match(line))
          resolve_sourced(m[3].strip).each { |p| scan_file(p) }
        end
      end
    rescue SystemCallError, ArgumentError # unreadable file / invalid bytes
      nil
    end

    def record(abs)
      if File.file?(abs)
        st = File.stat(abs)
        @entries << FileEntry.new(path: abs, exists: true, mtime: st.mtime.to_i, size: st.size)
      else
        @entries << FileEntry.new(path: abs, exists: false)
      end
    end

    # A sourced glob can gain matches without any scanned file changing, so
    # the pattern's parent dir is fingerprinted too (its mtime moves when
    # entries are added/removed).
    def record_dir(dir)
      abs = File.expand_path(dir)
      return if @visited["dir:#{abs}"]

      @visited["dir:#{abs}"] = true
      if File.directory?(abs)
        st = File.stat(abs)
        @entries << FileEntry.new(path: abs, exists: true, mtime: st.mtime.to_i, size: st.size)
      else
        @entries << FileEntry.new(path: abs, exists: false)
      end
    end

    # tmux expands ~ and environment variables in source-file paths; the
    # original tpm handled only ~ and literal $HOME. Superset.
    def expand(path)
      path.sub(%r{\A~(?=/|\z)}, @home)
          .gsub(/\$\{?([A-Za-z_]\w*)\}?/) { ENV[Regexp.last_match(1)] || "" }
    end
  end
end
