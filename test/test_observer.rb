# frozen_string_literal: true

require "helper"
require "stringio"
require "json"

# D34: the declared plugin set is an *observation* (a live tmux option plus
# scraped files), and an observation that fails must never read as "nothing
# declared" — every mutating verb acts on that. These tests drive the two
# failure classes (tmux will not answer; a config file cannot be read) through
# the commands and check that nothing on disk moves.
class TestObserver < Minitest::Test
  include TempoTest

  def setup
    @dir = Dir.mktmpdir("tempo-observer")
    @fixtures = File.join(@dir, "fixtures")
    @plugins = "#{File.join(@dir, "plugins")}/"
    @repo = make_plugin_repo(@fixtures, "tmux-example-plugin")
    @conf = File.join(@dir, ".tmux.conf")
    File.write(@conf, "set -g @plugin '#{@repo}'\n")
    @old_env = ENV.to_h.slice("HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME")
  end

  def teardown
    %w[HOME XDG_DATA_HOME XDG_CONFIG_HOME].each { |k| @old_env.key?(k) ? ENV[k] = @old_env[k] : ENV.delete(k) }
    FileUtils.chmod_R("u+rw", @dir)
    FileUtils.remove_entry(@dir)
  end

  # The usual test Env answers the legacy-option question itself. This one
  # leaves it to Tmux.option, which the tests stub to "no answer".
  def live_env
    build_env(@dir, specs: nil, tpm_plugins_option: nil,
                    candidate_config_files: [@conf], user_conf: @conf)
  end

  def healthy_env
    build_env(@dir, specs: nil, candidate_config_files: [@conf], user_conf: @conf)
  end

  def lock_path = File.join(@dir, "tempo.lock")
  def generation_count = Dir.glob(File.join(@dir, "data", "generations", "*", "manifest.json")).size

  # Swap a Tmux module function for the duration of the block. Tmux uses
  # module_function, so its singleton methods are the call surface.
  def stubbing(name, value)
    original = Tempo::Tmux.method(name)
    Tempo::Tmux.define_singleton_method(name) { |*_args| value }
    yield
  ensure
    Tempo::Tmux.define_singleton_method(name, original)
  end

  def with_mute_tmux(&block)
    stubbing(:option, nil, &block)
  end

  def test_an_unanswered_tmux_query_is_an_observer_error_not_an_empty_set
    with_mute_tmux do
      err = assert_raises(Tempo::ObserverError) { live_env.specs }
      assert_includes err.message, "@tpm_plugins"
    end
  end

  def test_install_changes_nothing_when_the_observer_fails
    Tempo::Commands.install(healthy_env, capture_ui.first)
    env = live_env
    lock_before = File.read(lock_path)
    File.write(env.artifact_path, "sentinel\n")

    with_mute_tmux { assert_raises(Tempo::ObserverError) { Tempo::Commands.install(env, capture_ui.first) } }

    assert_equal lock_before, File.read(lock_path)
    assert_equal "sentinel\n", File.read(env.artifact_path)
    assert_equal 1, generation_count
    assert File.directory?(File.join(@plugins, "tmux-example-plugin"))
  end

  # The hot path calls generate when the fingerprint is stale; a refusal
  # leaves the previous, working artifact (D1: stale beats empty).
  def test_generate_keeps_the_previous_artifact_when_the_observer_fails
    env = live_env
    FileUtils.mkdir_p(File.dirname(env.artifact_path))
    File.write(env.artifact_path, "sentinel\n")

    with_mute_tmux { assert_raises(Tempo::ObserverError) { Tempo::Commands.generate(env) } }

    assert_equal "sentinel\n", File.read(env.artifact_path)
  end

  # The CLI is the one place the error is caught; it must say so and exit 1.
  def test_cli_reports_the_failure_once_and_exits_1
    ENV["HOME"] = @dir
    ENV["XDG_DATA_HOME"] = File.join(@dir, "data")
    ENV.delete("XDG_CONFIG_HOME")
    err = StringIO.new
    code = nil
    stubbing(:global_env, @plugins) do
      with_mute_tmux do
        $stderr = err
        begin
          code = Tempo::CLI.run(["install"])
        ensure
          $stderr = STDERR
        end
      end
    end

    assert_equal 1, code
    assert_includes err.string, "cannot determine the declared plugin set"
    assert_includes err.string, "nothing was changed"
    refute File.exist?(lock_path)
  end

  def test_an_unreadable_config_file_is_an_observer_error
    skip "root reads everything" if Process.uid.zero?
    File.chmod(0o000, @conf)

    err = assert_raises(Tempo::ObserverError) { Tempo::Scraper.new([@conf], home: @dir).scan }
    assert_includes err.message, @conf
  end

  # tmux tolerates a stray non-UTF-8 byte; so must the scraper, or a comment
  # in someone's native language hides every declaration after it.
  def test_invalid_bytes_do_not_hide_declarations
    File.binwrite(@conf, "# caf\xE9\nset -g @plugin '#{@repo}'\n")

    assert_equal [@repo], Tempo::Scraper.new([@conf], home: @dir).scan.plugin_specs
  end

  def test_status_reports_the_failure_and_still_exits_0
    ui, out, err = capture_ui
    with_mute_tmux { assert_equal 0, Tempo::Commands.status(live_env, ui) }

    assert_includes err.string, "plugins could not be determined"
    assert_includes out.string, "lockfile:"
  end

  # Friction log #1: an empty list after init reads as data loss.
  def test_status_with_nothing_declared_points_at_the_fix
    File.write(@conf, "")
    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.status(healthy_env, ui)
    assert_includes out.string, "no plugins declared"
    assert_includes out.string, "tempo add"

    File.write(@conf, "set -g @plugin '#{@repo}'\n")
    ui, out, = capture_ui
    Tempo::Commands.status(healthy_env, ui)
    refute_includes out.string, "no plugins declared"
  end

  def test_doctor_fails_when_the_observer_fails
    ui, _, err = capture_ui
    with_mute_tmux { assert_equal 1, Tempo::Doctor.run(live_env, ui) }
    assert_includes err.string, "plugins:"
    assert_includes err.string, "FAIL"
  end
end
