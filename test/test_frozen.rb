# frozen_string_literal: true

require "helper"
require "json"

# `sync --frozen` / `restore --frozen`: the lock is enforced from local
# objects only. Network-proof here is "delete the fixture repo after the
# install" — origin then points at nothing, so any clone/fetch/pull fails
# loudly. The flows suite proves the same property from the outside with a
# PATH git shim the Ruby code cannot see.
class TestFrozen < Minitest::Test
  include TempoTest

  def setup
    @dir = Dir.mktmpdir("tempo-frozen")
    @fixtures = File.join(@dir, "fixtures")
    @plugins = "#{File.join(@dir, "plugins")}/"
    @repo = make_plugin_repo(@fixtures, "tmux-alpha")
  end

  def teardown
    FileUtils.chmod_R("u+w", @dir)
    FileUtils.remove_entry(@dir)
  end

  def env_for(*specs)
    build_env(@dir, specs: specs)
  end

  def lockfile_path
    File.join(@dir, "tempo.lock")
  end

  def artifact_path
    File.join(@dir, "data", "load.sh")
  end

  # Rewrite the lock in place; the block gets the "plugins" map and the
  # whole document, so tests can both corrupt entries and plant sentinels.
  def rewrite_lock
    doc = JSON.parse(File.read(lockfile_path))
    yield doc["plugins"], doc
    File.write(lockfile_path, "#{JSON.pretty_generate(doc)}\n")
  end

  # Origin now points at a path that does not exist: fetch/clone/pull fail.
  def cut_the_network
    FileUtils.remove_entry(@fixtures)
  end

  def plugin_dir(name)
    File.join(@plugins, name)
  end

  # --- the happy path --------------------------------------------------

  def test_satisfiable_lock_is_enforced_offline_and_cleans
    Tempo::Commands.install(env_for(@repo), capture_ui.first)
    FileUtils.mkdir_p(File.join(@plugins, "tmux-orphan"))
    cut_the_network

    ui, _, err = capture_ui
    assert_equal 0, Tempo::Commands.sync(env_for(@repo), ui, frozen: true)
    assert_empty err.string
    refute File.directory?(File.join(@plugins, "tmux-orphan")), "clean must still run under frozen"
    assert File.file?(artifact_path), "frozen must regenerate the artifact"
  end

  # Frozen must not write the lock — proven with a sentinel key that
  # Lockfile.write would drop. The non-frozen half is the negative pair:
  # without it, "unchanged bytes" could just mean "nothing to change".
  def test_frozen_never_rewrites_the_lockfile
    Tempo::Commands.install(env_for(@repo), capture_ui.first)
    rewrite_lock { |_plugins, doc| doc["note"] = "sentinel" }
    cut_the_network

    assert_equal 0, Tempo::Commands.sync(env_for(@repo), capture_ui.first, frozen: true)
    assert_includes File.read(lockfile_path), "sentinel"

    assert_equal 0, Tempo::Commands.sync(env_for(@repo), capture_ui.first)
    refute_includes File.read(lockfile_path), "sentinel"
  end

  # The lock points at a commit the clone has but is not on. Frozen must
  # check it out with no fetch arm at all.
  def test_restores_a_local_commit_without_fetching
    Tempo::Commands.install(env_for(@repo), capture_ui.first)
    locked = JSON.parse(File.read(lockfile_path))["plugins"]["tmux-alpha"]["commit"]
    add_upstream_commit(@repo)
    Tempo::Git.pull(plugin_dir("tmux-alpha"))
    refute_equal locked, Tempo::Git.head_commit(plugin_dir("tmux-alpha"))
    cut_the_network

    ui, out, err = capture_ui
    assert_equal 0, Tempo::Commands.sync(env_for(@repo), ui, frozen: true)
    assert_empty err.string
    assert_includes out.string, %("tmux-alpha" restored to #{locked[0, 12]})
    assert_equal locked, Tempo::Git.head_commit(plugin_dir("tmux-alpha"))
  end

  # restore --frozen is sync --frozen minus the clean: orphans survive.
  def test_frozen_restore_enforces_without_cleaning
    Tempo::Commands.install(env_for(@repo), capture_ui.first)
    FileUtils.mkdir_p(File.join(@plugins, "tmux-orphan"))
    cut_the_network

    ui, _, err = capture_ui
    assert_equal 0, Tempo::Commands.restore(env_for(@repo), ui, frozen: true)
    assert_empty err.string
    assert File.directory?(File.join(@plugins, "tmux-orphan"))
  end

  # --- violations ------------------------------------------------------

  # All three violation kinds at once, next to one satisfied plugin. An
  # implementation that fails fast on the first violation names one plugin
  # and fails this test.
  def test_every_violation_is_named_and_nothing_is_mutated
    charlie = make_plugin_repo(@fixtures, "tmux-charlie")
    delta = make_plugin_repo(@fixtures, "tmux-delta")
    installed = [@repo, charlie, delta]
    Tempo::Commands.install(env_for(*installed), capture_ui.first)

    rewrite_lock do |plugins|
      plugins.delete("tmux-charlie")            # installed, but unlocked
      plugins["tmux-delta"]["commit"] = "0" * 40 # locked at an absent object
    end
    delta_head = Tempo::Git.head_commit(plugin_dir("tmux-delta"))
    File.write(artifact_path, "sentinel\n")
    FileUtils.mkdir_p(File.join(@plugins, "tmux-orphan"))
    lock_before = File.read(lockfile_path)
    cut_the_network

    # tmux-bravo is declared but was never installed.
    specs = installed + [File.join(@dir, "fixtures", "tmux-bravo")]
    ui, out, err = capture_ui
    assert_equal 1, Tempo::Commands.sync(env_for(*specs), ui, frozen: true)

    assert_includes err.string, %("tmux-bravo" not installed)
    assert_includes err.string, %("tmux-charlie" not in the lockfile)
    assert_includes err.string, %("tmux-delta" locked commit #{"0" * 12} missing locally)
    refute_includes err.string, "tmux-alpha" # the satisfied one stays quiet
    assert_empty out.string

    assert_equal lock_before, File.read(lockfile_path), "frozen must not touch the lock"
    assert_equal "sentinel\n", File.read(artifact_path), "a failed frozen run must not regenerate"
    assert File.directory?(File.join(@plugins, "tmux-orphan")), "a failed frozen run must not clean"
    assert_equal delta_head, Tempo::Git.head_commit(plugin_dir("tmux-delta"))
  end

  # A missing lock reads as {} (same as an unparseable one), so under frozen
  # every declared plugin is a violation — nothing is "already fine".
  def test_missing_lockfile_violates_every_declared_plugin
    bravo = make_plugin_repo(@fixtures, "tmux-bravo")
    Tempo::Commands.install(env_for(@repo, bravo), capture_ui.first)
    FileUtils.rm_f(lockfile_path)
    cut_the_network

    ui, _, err = capture_ui
    assert_equal 1, Tempo::Commands.sync(env_for(@repo, bravo), ui, frozen: true)
    assert_includes err.string, %("tmux-alpha" not in the lockfile)
    assert_includes err.string, %("tmux-bravo" not in the lockfile)
    refute File.file?(lockfile_path), "a failed frozen run must not create the lock"
  end

  def test_frozen_restore_also_refuses_a_violating_tree
    ui, _, err = capture_ui
    assert_equal 1, Tempo::Commands.restore(env_for(@repo), ui, frozen: true)
    assert_includes err.string, %("tmux-alpha" not installed)
  end

  # Duplicate declarations collapse, mirroring Lockfile.write's guard.
  def test_duplicate_specs_report_once
    ui, _, err = capture_ui
    assert_equal 1, Tempo::Commands.sync(env_for(@repo, @repo), ui, frozen: true)
    assert_equal 1, err.string.scan(%("tmux-alpha" not installed)).size
  end
end

# Flag parsing is rejected before Env is built, so these never touch tmux.
class TestFlagParsing < Minitest::Test
  include TempoTest

  def run_cli(*argv)
    rc = nil
    _out, err = capture_io { rc = Tempo::CLI.run(argv) }
    [rc, err]
  end

  def test_typo_of_a_known_flag_is_a_usage_error
    rc, err = run_cli("sync", "--froozen")
    assert_equal 1, rc
    assert_includes err, "unknown option: --froozen"
    assert_includes err, "usage:"
  end

  # The paired negative: --frozen is real, but only on sync/restore.
  # install and update are inherently network operations (out of scope).
  def test_frozen_is_rejected_on_commands_that_do_not_have_it
    assert_equal 1, run_cli("install", "--frozen").first
    assert_equal 1, run_cli("clean", "--frozen").first
    assert_equal 1, run_cli("status", "--frozen").first
  end

  def test_usage_advertises_frozen_on_sync_and_restore
    usage = Tempo::CLI::USAGE.lines
    assert usage.any? { |l| l.include?("sync") && l.include?("frozen") }
    assert usage.any? { |l| l.include?("restore") && l.include?("frozen") }
  end

  # Update's tokens are prompt data by contract, never flag-checked; the
  # word-splitting path turns them into plugin names.
  def test_update_tokens_are_never_flag_checked
    dir = Dir.mktmpdir("tempo-flags")
    env = build_env(dir, specs: [])
    ui, _, err = capture_ui
    assert_equal 1, Tempo::Commands.update(env, ui, ["--weird"])
    assert_includes err.string, "--weird not installed!"
  ensure
    FileUtils.remove_entry(dir)
  end
end
