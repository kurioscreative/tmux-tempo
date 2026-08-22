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

  # Drift is produced through `update`, never by pulling in the plugin dir:
  # under the store that dir is a symlink into a filed entry, and mutating an
  # entry in place is the one thing the design forbids. The lock is then put
  # back by hand, because the situation being tested is a committed lock that
  # disk has run ahead of.
  def test_install_returns_disk_to_the_locked_commit
    install(env_for(@repo))
    lock_path = File.join(@dir, "tempo.lock")
    locked = Tempo::Lockfile.read(lock_path).dig("tmux-example-plugin", "commit")
    lock_before = File.read(lock_path)

    add_upstream_commit(@repo)
    Tempo::Commands.update(env_for(@repo), capture_ui.first, ["all"])
    File.write(lock_path, lock_before)
    dir = File.join(@plugins, "tmux-example-plugin")
    refute_equal locked, git(dir, "rev-parse", "HEAD").strip

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.install(env_for(@repo), ui)
    assert_equal locked, git(dir, "rev-parse", "HEAD").strip
    assert_includes out.string, %("tmux-example-plugin" restored to #{locked[0, 12]})
  end

  def test_install_adds_missing_enforces_the_lock_and_cleans
    install(env_for(@repo))
    lock_path = File.join(@dir, "tempo.lock")
    locked = Tempo::Lockfile.read(lock_path).dig("tmux-example-plugin", "commit")

    # wipe the clone, drop an orphan, move upstream: sync must fix all three
    FileUtils.rm_rf(File.join(@plugins, "tmux-example-plugin"))
    FileUtils.mkdir_p(File.join(@plugins, "tmux-orphan"))
    add_upstream_commit(@repo)

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.install(env_for(@repo), ui)
    dir = File.join(@plugins, "tmux-example-plugin")
    assert_equal locked, git(dir, "rev-parse", "HEAD").strip,
                 "sync must check out the locked commit, not upstream HEAD"
    refute File.directory?(File.join(@plugins, "tmux-orphan"))
    assert_includes out.string, %("tmux-example-plugin" download success)

    # the lock still points at the enforced commit
    assert_equal locked, Tempo::Lockfile.read(lock_path).dig("tmux-example-plugin", "commit")
  end

  # PRD OQ5: legacy `@tpm_plugins` entries must lock identically to `@plugin`
  # ones. `specs: nil` is load-bearing — it forces Env#specs through the real
  # merge (option string + scraped lines); overriding `specs:` would test the
  # override, not the merge this exists to pin.
  def test_legacy_tpm_plugins_option_locks_like_a_scraped_spec
    env = build_env(@dir, specs: nil, tpm_plugins_option: "#{@repo}#dev")
    install(env)

    entry = Tempo::Lockfile.read(File.join(@dir, "tempo.lock"))
                           .fetch("tmux-example-plugin")
    assert_equal @repo, entry["url"]
    assert_equal "dev", entry["branch"]
    dir = File.join(@plugins, "tmux-example-plugin")
    assert_equal git(dir, "rev-parse", "HEAD").strip, entry["commit"]
  end

  def test_unparseable_lock_is_ignored
    File.write(File.join(@dir, "tempo.lock"), "not json{")
    assert_equal({}, Tempo::Lockfile.read(File.join(@dir, "tempo.lock")))
  end

  # Dotfiles case: ~/.tmux.conf is a symlink into a dotfiles repo — the
  # lock must land next to the real file, where it can be committed.
  def test_lockfile_path_resolves_conf_symlink
    real_dir = File.join(@dir, "dotfiles")
    FileUtils.mkdir_p(real_dir)
    File.write(File.join(real_dir, ".tmux.conf"), "")
    link = File.join(@dir, ".tmux.conf")
    File.symlink(File.join(real_dir, ".tmux.conf"), link)

    env = Tempo::Env.new(user_conf: link)
    # realpath both sides: on macOS the tmpdir itself sits behind /tmp -> /private/tmp
    assert_equal File.join(File.realpath(real_dir), "tempo.lock"), env.lockfile_path
  end

  def test_lockfile_path_missing_conf_keeps_logical_dir
    conf = File.join(@dir, "no-such-dir", ".tmux.conf")
    env = Tempo::Env.new(user_conf: conf)
    assert_equal File.join(@dir, "no-such-dir", "tempo.lock"), env.lockfile_path
  end
end
