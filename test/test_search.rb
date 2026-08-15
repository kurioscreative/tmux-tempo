# frozen_string_literal: true

require "helper"

# `tempo search`: the index cache state machine (fresh / stale / offline /
# absent / malformed) and the matcher + canonical-line output.
#
# The network is exercised through the TEMPO_INDEX_URL seam pointed at
# `file://` fixtures, so these tests never open a socket: a URL pointing at a
# path that does not exist IS the network-failure case, and a fresh cache
# paired with an unreachable URL proves no fetch happened.
class TestSearch < Minitest::Test
  include TempoTest

  INDEX = {
    "version" => 1,
    "plugins" => [
      { "name" => "tmux-sensible", "repo" => "tmux-plugins/tmux-sensible",
        "description" => "A set of tmux options that should be acceptable to everyone",
        "tags" => ["defaults", "Starter"] },
      { "name" => "tmux-resurrect", "repo" => "tmux-plugins/tmux-resurrect",
        "description" => "Persists tmux environment across system restarts",
        "tags" => ["sessions"] },
      { "name" => "catppuccin", "repo" => "catppuccin/tmux",
        "description" => "Soothing pastel theme for tmux",
        "tags" => ["theme"] },
    ],
  }.freeze

  def setup
    @dir = Dir.mktmpdir("tempo-search")
    @env = build_env(@dir, specs: [])
    @saved_url = ENV["TEMPO_INDEX_URL"]
    # A developer's XDG_DATA_HOME must not leak into the sandboxed data dir.
    @saved_xdg = ENV.delete("XDG_DATA_HOME")
    @remote = File.join(@dir, "remote-index.json")
    write_index(@remote, INDEX)
    point_at(@remote)
  end

  def teardown
    ENV["TEMPO_INDEX_URL"] = @saved_url
    ENV["XDG_DATA_HOME"] = @saved_xdg
    FileUtils.remove_entry(@dir)
  end

  # --- matching ------------------------------------------------------------

  def test_matches_name_case_insensitively_and_prints_the_canonical_line
    code, out, = search("SENSIBLE")

    assert_equal 0, code
    assert_includes out, "set -g @plugin 'tmux-plugins/tmux-sensible'"
    refute_includes out, "tmux-resurrect"
  end

  def test_matches_description_substring
    code, out, = search("restarts")

    assert_equal 0, code
    assert_includes out, "set -g @plugin 'tmux-plugins/tmux-resurrect'"
  end

  def test_matches_tags_case_insensitively
    code, out, = search("starter")

    assert_equal 0, code
    assert_includes out, "set -g @plugin 'tmux-plugins/tmux-sensible'"
  end

  def test_every_match_gets_its_own_canonical_line
    code, out, = search("tmux")

    assert_equal 0, code
    assert_includes out, "set -g @plugin 'tmux-plugins/tmux-sensible'"
    assert_includes out, "set -g @plugin 'tmux-plugins/tmux-resurrect'"
    assert_includes out, "set -g @plugin 'catppuccin/tmux'"
  end

  def test_no_match_exits_1_and_prints_nothing_on_stdout
    code, out, err = search("no-such-plugin-anywhere")

    assert_equal 1, code
    assert_empty out.strip
    assert_includes err, "no plugins in the index match"
  end

  def test_missing_query_is_a_usage_error
    code, _, err = search

    assert_equal 1, code
    assert_includes err, "usage: tempo search"
  end

  # --- cache state machine -------------------------------------------------

  def test_fresh_cache_is_served_without_any_fetch
    write_index(@env.index_cache_path, INDEX)
    point_at(File.join(@dir, "gone.json")) # any fetch would fail outright

    code, out, err = search("sensible")

    assert_equal 0, code
    assert_includes out, "set -g @plugin 'tmux-plugins/tmux-sensible'"
    assert_empty err
  end

  def test_stale_cache_is_refetched
    write_index(@env.index_cache_path, { "version" => 1, "plugins" => [] })
    make_stale(@env.index_cache_path)

    code, out, = search("sensible")

    assert_equal 0, code
    assert_includes out, "set -g @plugin 'tmux-plugins/tmux-sensible'",
                    "a stale cache must be replaced by the fetched index"
    assert_includes File.read(@env.index_cache_path), "tmux-sensible",
                    "the refetched index must be written back to the cache"
  end

  def test_network_failure_falls_back_to_the_stale_cache_with_a_notice
    write_index(@env.index_cache_path, INDEX)
    make_stale(@env.index_cache_path)
    point_at(File.join(@dir, "gone.json"))

    code, out, err = search("sensible")

    assert_equal 0, code
    assert_includes out, "set -g @plugin 'tmux-plugins/tmux-sensible'"
    assert_equal 1, err.strip.lines.size, "the offline fallback notice is one line"
    assert_includes err, "cached copy"
  end

  def test_no_cache_and_no_network_is_a_clear_error
    point_at(File.join(@dir, "gone.json"))

    code, out, err = search("sensible")

    assert_equal 1, code
    assert_empty out.strip
    assert_includes err, "cannot fetch the plugin index"
    assert_includes err, @env.index_cache_path
  end

  # --- malformed input -----------------------------------------------------

  def test_malformed_fetched_index_is_a_clear_error_not_a_stack_trace
    File.write(@remote, "{ this is not json")

    code, _, err = search("sensible")

    assert_equal 1, code
    assert_includes err, "is not usable"
    refute_includes err, "search.rb:"
  end

  def test_index_without_a_plugins_array_is_a_clear_error
    File.write(@remote, JSON.generate({ "version" => 1 }))

    code, _, err = search("sensible")

    assert_equal 1, code
    assert_includes err, 'no "plugins" array'
  end

  def test_malformed_cached_index_is_a_clear_error
    FileUtils.mkdir_p(File.dirname(@env.index_cache_path))
    File.write(@env.index_cache_path, "not json either")

    code, _, err = search("sensible")

    assert_equal 1, code
    assert_includes err, "is not usable"
  end

  private

  def search(*args)
    ui, out, err = capture_ui
    code = Tempo::Search.run(@env, ui, args)
    [code, out.string, err.string]
  end

  def point_at(path)
    ENV["TEMPO_INDEX_URL"] = "file://#{path}"
  end

  def write_index(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  def make_stale(path)
    old = Time.now - Tempo::Search::CACHE_TTL - 60
    File.utime(old, old, path)
  end
end
