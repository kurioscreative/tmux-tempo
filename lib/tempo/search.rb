# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "fileutils"

module Tempo
  # `tempo search <query>`: case-insensitive substring match over a curated
  # JSON index that lives in its own repo (D26).
  #
  # This is the only code in tempo that touches the network, and it is
  # reachable only from an explicit `search`. Nothing under `scripts/`, the
  # `tpm` entry script or the generator may require it — PRD §5's
  # never-block-startup rule is enforced structurally by TASK-007's
  # criterion 5, not by convention.
  class Search
    # The public index repo (D21/D26). Its `main` branch is served raw, so a
    # curated entry is live the moment it is merged there.
    #
    # TEMPO_INDEX_URL overrides it. That variable is a *test seam* — not a
    # user-facing option — which is why it is documented here and deliberately
    # absent from the README.
    DEFAULT_INDEX_URL = "https://raw.githubusercontent.com/kurioscreative/tmux-tempo-index/main/index.json"

    # A constant, not an option (contract: cache TTL is a constant). A day is
    # long enough that a session's worth of searches never hits the network,
    # short enough that a newly curated plugin shows up the next day.
    CACHE_TTL = 24 * 60 * 60

    FetchError = Class.new(StandardError)

    def self.run(env, ui, args)
      new(env, ui).run(args)
    end

    def initialize(env, ui)
      @env = env
      @ui = ui
    end

    def run(args)
      query = args.reject { |a| a.start_with?("-") }.join(" ").strip
      if query.empty?
        @ui.err("usage: tempo search <query>")
        return @ui.exit_code
      end

      plugins = load_index
      return @ui.exit_code if plugins.nil?

      matches = plugins.select { |p| match?(p, query.downcase) }
      if matches.empty?
        @ui.err("no plugins in the index match #{query.inspect}")
        return @ui.exit_code
      end

      report(matches, numbered: picker?)
      return @ui.exit_code unless picker?

      pick(matches)
    end

    private

    # Substring over name, description and tags — no ranking, no fuzziness.
    # An index of a few dozen curated entries does not need either, and a
    # scoring function is a thing users would have to learn.
    def match?(plugin, needle)
      haystack = [plugin["name"], plugin["description"], *Array(plugin["tags"])]
      haystack.compact.any? { |field| field.to_s.downcase.include?(needle) }
    end

    def report(matches, numbered: false)
      matches.each_with_index do |plugin, i|
        @ui.ok("") unless i.zero?
        prefix = numbered ? "#{i + 1}. " : ""
        @ui.ok("#{prefix}#{plugin["name"]} — #{plugin["description"]}")
        @ui.ok("  #{Spec.plugin_line(plugin["repo"])}")
      end
    end

    # No TTY, no picker: `search` in a script or a pipe stays exactly the
    # read-only report it has always been, numbering included — the numbers
    # only mean something when there is somebody to type one.
    def picker?
      $stdin.tty?
    end

    # Deliberately teletype-simple: a numbered list and one line of stdin. No
    # TUI, no cursor keys, no alternate screen — this runs inside whatever
    # terminal the user already has, and Enter is always the safe answer.
    # The prompt goes straight to the terminal, like the trust prompt, since
    # `ui` may be routing output through tmux.
    def pick(matches)
      $stdout.print("Install which? [1-#{matches.size}, Enter to skip] ")
      $stdout.flush
      answer = $stdin.gets.to_s.strip
      return @ui.exit_code if answer.empty?

      unless answer.match?(/\A\d+\z/) && (1..matches.size).cover?(answer.to_i)
        @ui.err("not a choice between 1 and #{matches.size}: #{answer}")
        return @ui.exit_code
      end

      ConfigEdit.add(@env, @ui, [matches[answer.to_i - 1]["repo"]], trust: Trust.gate(@env))
    end

    # Cache-first: a fresh cache is served without any network call at all.
    # A stale (or missing) cache refetches, and a failed refetch falls back
    # to whatever is cached with a one-line notice — a day-old index beats
    # no answer. Only "no cache and no network" is an error.
    def load_index
      path = @env.index_cache_path
      return parse(File.read(path), path) if fresh?(path)

      begin
        body = fetch(index_url)
      rescue FetchError => e
        unless File.file?(path)
          @ui.err("tempo: cannot fetch the plugin index (#{e.message})")
          @ui.err("       and there is no cached copy at #{path}")
          return nil
        end
        @ui.warn("index: offline (#{e.message}) — using the cached copy from #{cached_at(path)}")
        return parse(File.read(path), path)
      end

      write_cache(path, body)
      parse(body, index_url)
    end

    def fresh?(path)
      File.file?(path) && (Time.now - File.mtime(path)) < CACHE_TTL
    end

    def cached_at(path)
      File.mtime(path).strftime("%Y-%m-%d %H:%M")
    end

    def parse(body, source)
      data =
        begin
          JSON.parse(body)
        rescue JSON::ParserError => e
          return unusable(source, e.message.lines.first.to_s.strip)
        end
      return unusable(source, 'no "plugins" array') unless data.is_a?(Hash) && data["plugins"].is_a?(Array)

      data["plugins"]
    end

    def unusable(source, reason)
      @ui.err("tempo: the plugin index at #{source} is not usable (#{reason})")
      nil
    end

    def index_url
      from_env = ENV["TEMPO_INDEX_URL"].to_s
      from_env.empty? ? DEFAULT_INDEX_URL : from_env
    end

    def fetch(url)
      uri = URI.parse(url)
      case uri.scheme
      when "http", "https" then http_get(uri)
      when "file" then File.read(uri.path)
      when nil then File.read(url) # a bare path, for local index work
      else raise FetchError, "unsupported URL scheme: #{uri.scheme}"
      end
    rescue FetchError
      raise
    rescue StandardError => e
      # DNS, TLS, timeouts, refused connections, a missing file behind the
      # test seam: every one of them means the same thing to the caller —
      # "no fresh index right now" — so they collapse to one error type with
      # exactly one degradation path.
      raise FetchError, "#{e.class}: #{e.message}"
    end

    def http_get(uri)
      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10
      ) { |http| http.get(uri.request_uri) }
      raise FetchError, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    # Best effort: an unwritable data dir costs a cache, never the answer.
    def write_cache(path, body)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, body)
      File.rename(tmp, path)
    rescue SystemCallError
      nil
    end
  end
end
