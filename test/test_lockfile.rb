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

    # the entry is the one the run started with: install never rewrites a
    # declared plugin's pin (D33), and here disk was brought back to it
    assert_equal locked, Tempo::Lockfile.read(lock_path).dig("tmux-example-plugin", "commit")
  end

  # --- D33: under install the lock is an input -----------------------------
  #
  # None of these were caught by the suite before they were written: install
  # rewrote the lock from disk after every run, and every existing test ran
  # install on a healthy observer with a reachable upstream. tpm has no lock,
  # so the compat suite can never see any of this either (NOTES 2026-08-22).

  def lock_path
    File.join(@dir, "tempo.lock")
  end

  def generation_count
    Dir.glob(File.join(@dir, "data", "generations", "*", "manifest.json")).size
  end

  # The observer cannot tell "nothing declared" from "tmux unreachable" or
  # "read the wrong config", so an empty declared set must write nothing:
  # the run that already refuses to clean must not erase the pins either.
  def test_install_with_nothing_declared_leaves_the_lock_and_generations_alone
    install(env_for(@repo))
    lock_before = File.read(lock_path)
    assert_equal 1, generation_count

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.install(env_for, ui)

    assert_includes out.string, "No plugins declared"
    assert_equal lock_before, File.read(lock_path)
    assert_equal 1, generation_count
  end

  def test_frozen_install_with_nothing_declared_files_no_generation
    install(env_for(@repo))
    lock_before = File.read(lock_path)

    assert_equal 0, Tempo::Commands.install(env_for, capture_ui.first, frozen: true)

    assert_equal lock_before, File.read(lock_path)
    assert_equal 1, generation_count
  end

  # Fresh machine with a committed lock, upstream unreachable: the clone
  # fails, the run exits 1, and the pin must survive for the next attempt.
  def test_install_keeps_the_pin_when_the_clone_fails
    install(env_for(@repo))
    lock_before = File.read(lock_path)
    FileUtils.rm_rf(File.join(@plugins, "tmux-example-plugin"))
    FileUtils.rm_rf(@repo)

    ui, _, err = capture_ui
    assert_equal 1, Tempo::Commands.install(env_for(@repo), ui)

    assert_includes err.string, %("tmux-example-plugin" download fail)
    assert_equal lock_before, File.read(lock_path)
  end

  # The locked commit cannot be produced, so disk stays where it was. The
  # lock is the side that is right; recording disk would move the pin to the
  # very commit the run just failed to move away from.
  def test_install_keeps_the_pin_when_the_restore_fails
    install(env_for(@repo))
    doc = JSON.parse(File.read(lock_path))
    doc["plugins"]["tmux-example-plugin"]["commit"] = "0" * 40
    File.write(lock_path, "#{JSON.pretty_generate(doc)}\n")
    lock_before = File.read(lock_path)

    ui, _, err = capture_ui
    assert_equal 1, Tempo::Commands.install(env_for(@repo), ui)

    assert_includes err.string, %("tmux-example-plugin" restore fail)
    assert_equal lock_before, File.read(lock_path)
  end

  # What install may do to the lock: add an entry for a plugin it cloned,
  # drop one for a plugin it cleaned. An entry for a plugin that is still
  # declared is carried over byte for byte, even when disk has moved.
  def test_install_adds_and_drops_entries_but_never_rewrites_a_declared_one
    other = make_plugin_repo(@fixtures, "tmux-other-plugin")
    install(env_for(@repo))
    pinned = Tempo::Lockfile.read(lock_path).fetch("tmux-example-plugin")

    add_upstream_commit(@repo)
    Tempo::Commands.update(env_for(@repo), capture_ui.first, ["all"])
    File.write(lock_path, JSON.pretty_generate({ "version" => 1, "plugins" => { "tmux-example-plugin" => pinned } }))

    assert_equal 0, install(env_for(@repo, other))
    lock = Tempo::Lockfile.read(lock_path)
    assert_equal %w[tmux-example-plugin tmux-other-plugin], lock.keys
    assert_equal pinned, lock["tmux-example-plugin"]

    assert_equal 0, install(env_for(other))
    assert_equal %w[tmux-other-plugin], Tempo::Lockfile.read(lock_path).keys
    refute File.exist?(File.join(@plugins, "tmux-example-plugin"))
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
