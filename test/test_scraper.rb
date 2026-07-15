# frozen_string_literal: true

require "helper"

class TestScraper < Minitest::Test
  def scan(files, home: @dir)
    Tempo::Scraper.new(files, home: home).scan
  end

  def conf(name, content)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def setup
    @dir = Dir.mktmpdir("tempo-scraper")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_quoting_and_whitespace_variants
    path = conf("tmux.conf", <<~CONF)
      set -g mode-keys vi
         set  -g    @plugin 'single/quoted'
      set-option -g @plugin "double/quoted"
      set -g @plugin bare/spec
      	set	-g	@plugin tabbed/spec
      # set -g @plugin 'commented/out'
    CONF
    specs = scan([path]).plugin_specs
    assert_equal %w[single/quoted double/quoted bare/spec tabbed/spec], specs
  end

  def test_prefix_match_like_original_awk
    # The original awk pattern matches `@plugins`/`@plugin_x` lines too and
    # takes field 4; accepting less than the original is the only breakage.
    path = conf("tmux.conf", %(set -g @plugins 'user/repo'\n))
    assert_equal %w[user/repo], scan([path]).plugin_specs
  end

  def test_sourced_files_followed_recursively
    inner = conf("inner.conf", "set -g @plugin 'from/inner'\n")
    middle = conf("middle.conf", <<~CONF)
      set -g @plugin 'from/middle'
      source-file '#{inner}'
    CONF
    top = conf("tmux.conf", <<~CONF)
      source #{middle}
      set -g @plugin 'from/top'
    CONF
    specs = scan([top]).plugin_specs
    assert_equal %w[from/middle from/inner from/top], specs
  end

  def test_source_cycle_terminates
    a = File.join(@dir, "a.conf")
    b = File.join(@dir, "b.conf")
    File.write(a, "source '#{b}'\nset -g @plugin 'from/a'\n")
    File.write(b, "source '#{a}'\nset -g @plugin 'from/b'\n")
    assert_equal %w[from/b from/a], scan([a]).plugin_specs
  end

  def test_source_with_flags_quotes_and_tilde
    inner = conf("sub/inner.conf", "set -g @plugin 'from/tilde'\n")
    rel = inner.sub(@dir, "~")
    top = conf("tmux.conf", %(source-file -q "#{rel}"\n))
    assert_equal %w[from/tilde], scan([top]).plugin_specs
  end

  def test_source_glob_expands_and_fingerprints_parent_dir
    conf("conf.d/one.conf", "set -g @plugin 'glob/one'\n")
    conf("conf.d/two.conf", "set -g @plugin 'glob/two'\n")
    top = conf("tmux.conf", "source-file #{@dir}/conf.d/*.conf\n")
    result = scan([top])
    assert_equal %w[glob/one glob/two], result.plugin_specs
    assert result.entries.any? { |e| e.path == File.join(@dir, "conf.d") },
           "glob parent dir must be fingerprinted"
  end

  def test_fingerprint_records_missing_and_existing_files
    existing = conf("tmux.conf", "set -g @plugin 'a/b'\nsource '#{@dir}/nope.conf'\n")
    result = scan([existing, File.join(@dir, "ghost.conf")])
    by_path = result.entries.to_h { |e| [e.path, e] }

    assert by_path[existing].exists
    assert_equal File.size(existing), by_path[existing].size
    refute by_path[File.join(@dir, "nope.conf")].exists
    refute by_path[File.join(@dir, "ghost.conf")].exists
  end
end
