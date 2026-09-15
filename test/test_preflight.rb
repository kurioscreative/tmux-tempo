# frozen_string_literal: true

require "helper"
require "stringio"
require "json"

# D35: two more observers with the empty-on-failure shape. A git that cannot
# run made every clone "download fail" and every installed? false; a lock
# that does not parse read as {} and was re-snapshotted over the user's file
# at exit 0. Both now refuse before any verb touches disk, and `rollback`
# stays the way out of a conflicted lock.
class TestPreflight < Minitest::Test
  include TempoTest

  CONFLICTED_LOCK = <<~LOCK
    {
      "version": 1,
      "plugins": {
    <<<<<<< HEAD
        "tmux-example-plugin": { "url": "a", "branch": null, "commit": "aaaa" }
    =======
        "tmux-example-plugin": { "url": "a", "branch": null, "commit": "bbbb" }
    >>>>>>> laptop
      }
    }
  LOCK

  def setup
    @dir = Dir.mktmpdir("tempo-preflight")
    @fixtures = File.join(@dir, "fixtures")
    @plugins = "#{File.join(@dir, "plugins")}/"
    @repo = make_plugin_repo(@fixtures, "tmux-example-plugin")
    @conf = File.join(@dir, ".tmux.conf")
    File.write(@conf, "set -g @plugin '#{@repo}'\n")
    @old_path = ENV["PATH"]
    @old_env = ENV.to_h.slice("HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME")
  end

  def teardown
    ENV["PATH"] = @old_path
    %w[HOME XDG_DATA_HOME XDG_CONFIG_HOME].each { |k| @old_env.key?(k) ? ENV[k] = @old_env[k] : ENV.delete(k) }
    FileUtils.remove_entry(@dir)
  end

  def env_for(*specs) = build_env(@dir, specs: specs)
  def conf_env = build_env(@dir, specs: nil, candidate_config_files: [@conf], user_conf: @conf)
  def lock_path = File.join(@dir, "tempo.lock")
  def generation_count = Dir.glob(File.join(@dir, "data", "generations", "*", "manifest.json")).size
  def install(env = env_for(@repo)) = Tempo::Commands.install(env, capture_ui.first)

  # The real failure of 2026-09-15: Xcode's git refusing to run until its
  # license is accepted. Everything else on the box was fine.
  def with_broken_git
    shim = File.join(@dir, "broken-git-bin")
    FileUtils.mkdir_p(shim)
    File.write(File.join(shim, "git"), "#!/bin/sh\necho 'You have not agreed to the Xcode license agreements.' >&2\nexit 69\n")
    File.chmod(0o755, File.join(shim, "git"))
    ENV["PATH"] = "#{shim}:#{ENV["PATH"]}"
    yield
  ensure
    ENV["PATH"] = @old_path
  end

  def corrupt_lock
    File.write(lock_path, CONFLICTED_LOCK)
    CONFLICTED_LOCK
  end

  # --- git ------------------------------------------------------------------

  def test_install_refuses_when_git_cannot_run_and_names_git
    install
    lock_before = File.read(lock_path)
    env = env_for(@repo)
    File.write(env.artifact_path, "sentinel\n")

    err = with_broken_git { assert_raises(Tempo::Git::Unavailable) { install(env) } }

    assert_includes err.message, "Xcode license"
    assert_equal lock_before, File.read(lock_path)
    assert_equal "sentinel\n", File.read(env.artifact_path)
    assert_equal 1, generation_count
    assert File.directory?(File.join(@plugins, "tmux-example-plugin"))
  end

  # The replay: a fresh machine, broken git. The old code cloned nothing,
  # printed "download fail", wrote an empty lock and filed a generation.
  def test_a_fresh_machine_with_broken_git_records_nothing
    with_broken_git { assert_raises(Tempo::Git::Unavailable) { install } }

    refute File.exist?(lock_path)
    assert_equal 0, generation_count
  end

  def test_update_clean_and_frozen_refuse_when_git_cannot_run
    install
    with_broken_git do
      assert_raises(Tempo::Git::Unavailable) { Tempo::Commands.update(env_for(@repo), capture_ui.first, ["all"]) }
      assert_raises(Tempo::Git::Unavailable) { Tempo::Commands.clean(env_for(@repo), capture_ui.first) }
      assert_raises(Tempo::Git::Unavailable) { Tempo::Commands.install(env_for(@repo), capture_ui.first, frozen: true) }
    end
    assert_equal 1, generation_count
  end

  def test_add_leaves_the_config_alone_when_git_cannot_run
    conf_before = File.read(@conf)
    with_broken_git { assert_raises(Tempo::Git::Unavailable) { Tempo::ConfigEdit.add(conf_env, capture_ui.first, ["a/b"]) } }
    assert_equal conf_before, File.read(@conf)
    assert_empty Dir.glob("#{@conf}.bak-*")
  end

  def test_status_says_installed_state_is_unreliable_when_git_cannot_run
    install
    ui, _, err = capture_ui
    with_broken_git { assert_equal 0, Tempo::Commands.status(env_for(@repo), ui) }
    assert_includes err.string, "git is not usable"
  end

  def test_cli_names_git_as_the_cause
    ENV["HOME"] = @dir
    ENV["XDG_DATA_HOME"] = File.join(@dir, "data")
    ENV.delete("XDG_CONFIG_HOME")
    plugins = @plugins
    originals = { option: Tempo::Tmux.method(:option), global_env: Tempo::Tmux.method(:global_env) }
    Tempo::Tmux.define_singleton_method(:option) { |*_| "" }
    Tempo::Tmux.define_singleton_method(:global_env) { |*_| plugins }
    err = StringIO.new
    code = nil
    with_broken_git do
      $stderr = err
      begin
        code = Tempo::CLI.run(["install"])
      ensure
        $stderr = STDERR
      end
    end

    assert_equal 1, code
    assert_includes err.string, "tempo: git is not usable: You have not agreed to the Xcode license"
    assert_includes err.string, "nothing was changed"
    refute File.exist?(lock_path)
  ensure
    originals&.each { |name, m| Tempo::Tmux.define_singleton_method(name, m) }
  end

  # --- lock ------------------------------------------------------------------

  def test_a_conflicted_lock_is_a_refusal_not_a_fresh_snapshot
    install
    other = make_plugin_repo(@fixtures, "tmux-other-plugin")
    bytes = corrupt_lock

    err = assert_raises(Tempo::Lockfile::Unparseable) { install(env_for(@repo, other)) }

    assert_includes err.message, "cannot be parsed"
    assert_includes err.message, "tempo rollback"
    assert_equal bytes, File.read(lock_path)
    assert_equal 1, generation_count
    refute File.exist?(File.join(@plugins, "tmux-other-plugin")), "nothing may be cloned before the lock parses"
  end

  def test_update_clean_frozen_and_add_refuse_on_a_conflicted_lock
    install
    bytes = corrupt_lock
    conf_before = File.read(@conf)

    assert_raises(Tempo::Lockfile::Unparseable) { Tempo::Commands.update(env_for(@repo), capture_ui.first, ["all"]) }
    assert_raises(Tempo::Lockfile::Unparseable) { Tempo::Commands.clean(env_for(@repo), capture_ui.first) }
    assert_raises(Tempo::Lockfile::Unparseable) { Tempo::Commands.install(env_for(@repo), capture_ui.first, frozen: true) }
    assert_raises(Tempo::Lockfile::Unparseable) { Tempo::ConfigEdit.add(conf_env, capture_ui.first, ["a/b"]) }

    assert_equal bytes, File.read(lock_path)
    assert_equal conf_before, File.read(@conf)
    assert_equal 1, generation_count
  end

  # The remedy the message names: rollback restores recorded bytes and never
  # parses the live lock, so it is reachable from the conflicted state.
  def test_rollback_is_the_way_out_of_a_conflicted_lock
    install
    Tempo::Commands.clean(env_for(@repo), capture_ui.first) # generation 2
    recorded = File.read(lock_path)
    corrupt_lock

    ui, = capture_ui
    assert_equal 0, Tempo::Commands.rollback(env_for(@repo), ui, [])

    assert_equal recorded, File.read(lock_path)
    assert_equal 0, install, "install works again once the lock parses"
  end

  def test_status_reports_a_conflicted_lock_and_exits_0
    install
    corrupt_lock
    ui, out, err = capture_ui
    assert_equal 0, Tempo::Commands.status(env_for(@repo), ui)
    assert_includes err.string, "cannot be parsed"
    assert_includes out.string, "tmux-example-plugin"
  end
end
