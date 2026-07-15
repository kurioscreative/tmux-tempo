# frozen_string_literal: true

require "helper"
require "stringio"

class TestLockfile < Minitest::Test
  include TempoTest

  def setup
    @dir = Dir.mktmpdir("tempo-lock")
    @fixtures = File.join(@dir, "fixtures")
    @plugins = "#{File.join(@dir, "plugins")}/"
    @repo = make_plugin_repo(@fixtures, "tmux-example-plugin")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def env_for(*specs)
    build_env(@dir, specs: specs)
  end

  def install(env)
    Tempo::Commands.install(env, capture_ui.first)
  end

  def test_lock_written_on_install_with_url_branch_commit
    install(env_for("#{@repo}#dev"))
    lock = Tempo::Lockfile.read(File.join(@dir, "tempo.lock"))

    entry = lock.fetch("tmux-example-plugin")
    assert_equal @repo, entry["url"]
    assert_equal "dev", entry["branch"]
    dir = File.join(@plugins, "tmux-example-plugin")
    assert_equal git(dir, "rev-parse", "HEAD").strip, entry["commit"]
  end

  def test_update_moves_lock_forward
    install(env_for(@repo))
    before = Tempo::Lockfile.read(File.join(@dir, "tempo.lock"))
    add_upstream_commit(@repo)
    Tempo::Commands.update(env_for(@repo), capture_ui.first, ["all"])
    after = Tempo::Lockfile.read(File.join(@dir, "tempo.lock"))

    refute_equal before.dig("tmux-example-plugin", "commit"),
                 after.dig("tmux-example-plugin", "commit")
  end

  def test_restore_checks_out_locked_commit_detached
    install(env_for(@repo))
    locked = Tempo::Lockfile.read(File.join(@dir, "tempo.lock"))
                            .dig("tmux-example-plugin", "commit")

    # drift: upstream moves and the clone follows, without touching the lock
    add_upstream_commit(@repo)
    dir = File.join(@plugins, "tmux-example-plugin")
    git(dir, "pull", "-q")
    refute_equal locked, git(dir, "rev-parse", "HEAD").strip

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.restore(env_for(@repo), ui)
    assert_equal locked, git(dir, "rev-parse", "HEAD").strip
    assert_equal "HEAD", git(dir, "rev-parse", "--abbrev-ref", "HEAD").strip,
                 "restore leaves a detached HEAD by design"
    assert_includes out.string, %("tmux-example-plugin" restored to #{locked[0, 12]})
  end

  def test_sync_installs_missing_restores_and_cleans
    install(env_for(@repo))
    lock_path = File.join(@dir, "tempo.lock")
    locked = Tempo::Lockfile.read(lock_path).dig("tmux-example-plugin", "commit")

    # wipe the clone, drop an orphan, move upstream: sync must fix all three
    FileUtils.rm_rf(File.join(@plugins, "tmux-example-plugin"))
    FileUtils.mkdir_p(File.join(@plugins, "tmux-orphan"))
    add_upstream_commit(@repo)

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.sync(env_for(@repo), ui)
    dir = File.join(@plugins, "tmux-example-plugin")
    assert_equal locked, git(dir, "rev-parse", "HEAD").strip,
                 "sync must check out the locked commit, not upstream HEAD"
    refute File.directory?(File.join(@plugins, "tmux-orphan"))
    assert_includes out.string, %("tmux-example-plugin" download success)

    # the lock still points at the enforced commit
    assert_equal locked, Tempo::Lockfile.read(lock_path).dig("tmux-example-plugin", "commit")
  end

  def test_unparseable_lock_is_ignored
    File.write(File.join(@dir, "tempo.lock"), "not json{")
    assert_equal({}, Tempo::Lockfile.read(File.join(@dir, "tempo.lock")))
  end
end
