# frozen_string_literal: true

require "helper"
require "json"

# Generations and rollback (D25). The claims under test are the ones nothing
# else can prove: every mutating op files exactly one numbered generation, a
# rollback *restores* stored state rather than re-deriving it, retention is
# bounded at a constant, and the store GC that rides retention is neither
# over-eager (it must keep what a kept generation or a live link needs) nor a
# no-op (it must actually reclaim what nothing needs).
class TestGenerations < Minitest::Test
  include TempoTest

  def setup
    @dir = Dir.mktmpdir("tempo-generations")
    @fixtures = File.join(@dir, "fixtures")
    @plugins = "#{File.join(@dir, "plugins")}/"
    @lock = File.join(@dir, "tempo.lock")
    @repo = make_plugin_repo(@fixtures, "tmux-alpha")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # --- harness ------------------------------------------------------------

  def env_for(*specs)
    build_env(@dir, specs: specs)
  end

  def install(*specs)
    ui, out, err = capture_ui
    [Tempo::Commands.install(env_for(*specs), ui), out.string, err.string]
  end

  def update(*specs)
    ui, out, err = capture_ui
    [Tempo::Commands.update(env_for(*specs), ui, ["all"]), out.string, err.string]
  end

  def clean(*specs)
    ui, out, err = capture_ui
    [Tempo::Commands.clean(env_for(*specs), ui), out.string, err.string]
  end

  def rollback(args, specs: [@repo])
    ui, out, err = capture_ui
    [Tempo::Commands.rollback(env_for(*specs), ui, args), out.string, err.string]
  end

  def data_dir
    File.join(@dir, "data")
  end

  def gens_root
    File.join(data_dir, "generations")
  end

  def numbers
    Tempo::Generations.numbers(env_for(@repo))
  end

  def current
    Tempo::Generations.current(env_for(@repo))
  end

  def manifest(number)
    JSON.parse(File.read(File.join(gens_root, number.to_s, "manifest.json")))
  end

  def store_entries
    Dir.glob(File.join(data_dir, "store", "*", "*")).sort
  end

  def plugin_dir(name = "tmux-alpha")
    File.join(@plugins, name)
  end

  # --- filing -------------------------------------------------------------

  # Four mutating ops, four generations, numbered 1..4 in the order they ran.
  # The frozen path bypasses `finalize`, so it would silently go unrecorded if
  # filing lived only there. The one deliberate exception: an install with
  # nothing declared mutates nothing and files nothing (D33; pinned in
  # test_lockfile.rb).
  def test_every_mutating_op_files_one_generation_with_monotonic_numbering
    install(@repo)
    assert_equal [1], numbers

    add_upstream_commit(@repo)
    update(@repo)
    clean(@repo)
    install(@repo)

    assert_equal [1, 2, 3, 4], numbers
    assert_equal 4, current
    assert_equal %w[install update clean install], numbers.map { |n| manifest(n)["op"] }
  end

  # A generation is (lockfile bytes, symlink set). The bytes matter: restoring
  # a stored copy is immune to any future drift in how the lock is serialized,
  # which re-snapshotting disk would not be.
  def test_a_generation_stores_the_lockfile_bytes_and_the_link_set
    install(@repo)

    assert_equal File.read(@lock), File.read(File.join(gens_root, "1", "tempo.lock"))
    assert_equal({ "tmux-alpha" => File.readlink(plugin_dir) }, manifest(1)["links"])
    assert_empty manifest(1)["unmanaged"]
  end

  # --- rolling back -------------------------------------------------------

  def test_bare_rollback_returns_to_the_previous_generation
    install(@repo)
    first = File.readlink(plugin_dir)
    add_upstream_commit(@repo)
    update(@repo)
    refute_equal first, File.readlink(plugin_dir)

    rc, out, = rollback([])

    assert_equal 0, rc
    assert_includes out, "rolled back to generation 1"
    assert_equal first, File.readlink(plugin_dir)
    assert_equal 1, current
    assert File.file?(File.join(data_dir, "load.sh")), "rollback must regenerate the artifact"
  end

  # Rolling back does not file a generation, so a second bare rollback walks
  # further down the history instead of ping-ponging between two states.
  def test_repeated_bare_rollbacks_walk_further_down
    install(@repo)
    first = File.readlink(plugin_dir)
    2.times do
      add_upstream_commit(@repo)
      update(@repo)
    end

    rollback([])
    assert_equal 2, current
    rollback([])

    assert_equal 1, current
    assert_equal first, File.readlink(plugin_dir)
    assert_equal [1, 2, 3], numbers, "rollback must not file or drop generations"
  end

  def test_rollback_targets_a_generation_by_number
    install(@repo)
    first = File.readlink(plugin_dir)
    2.times do
      add_upstream_commit(@repo)
      update(@repo)
    end

    assert_equal 0, rollback(["1"]).first
    assert_equal first, File.readlink(plugin_dir)
    assert_equal 1, current
  end

  # The lock rewrite IS the point — it is what makes the revert show up in the
  # user's dotfiles diff.
  def test_rollback_restores_the_lockfile
    install(@repo)
    before = File.read(@lock)
    add_upstream_commit(@repo)
    update(@repo)
    refute_equal before, File.read(@lock)

    rollback([])

    assert_equal before, File.read(@lock)
  end

  def test_unknown_generation_exits_1_and_changes_nothing
    install(@repo)
    add_upstream_commit(@repo)
    update(@repo)
    link = File.readlink(plugin_dir)
    lock = File.read(@lock)

    rc, _out, err = rollback(["99"])

    assert_equal 1, rc
    assert_includes err, "no such generation: 99"
    assert_equal link, File.readlink(plugin_dir)
    assert_equal lock, File.read(@lock)
    assert_equal 2, current
  end

  def test_bare_rollback_with_nothing_earlier_exits_1
    install(@repo)

    rc, _out, err = rollback([])

    assert_equal 1, rc
    assert_includes err, "no earlier generation"
    assert_equal 1, current
  end

  # Rollback never edits tmux.conf, so a plugin declared after the target
  # generation cannot be reverted to anything. It must be named — and must not
  # be conjured into the restored lockfile.
  def test_a_plugin_absent_from_the_target_generation_is_reported_not_invented
    install(@repo)
    beta = make_plugin_repo(@fixtures, "tmux-beta")
    install(@repo, beta)

    rc, _out, err = rollback([], specs: [@repo, beta])

    assert_equal 0, rc
    assert_includes err, %("tmux-beta" is declared but not in generation 1)
    assert_equal ["tmux-alpha"], JSON.parse(File.read(@lock)).fetch("plugins").keys
    assert File.symlink?(plugin_dir("tmux-beta")), "rollback must not remove what it cannot revert"
  end

  # A directory that declined adoption (untracked files, D24) has no second
  # copy to flip to. Record it as unmanaged, say so, and leave it alone.
  def test_an_unadopted_plain_directory_is_recorded_unmanaged_and_left_alone
    FileUtils.mkdir_p(@plugins)
    system("git", "clone", "-q", @repo, plugin_dir, out: File::NULL, err: File::NULL)
    File.write(File.join(plugin_dir, "SCRATCH"), "a cache the plugin wrote\n")
    install(@repo)
    clean(@repo)

    assert_empty manifest(1)["links"]
    assert_equal ["tmux-alpha"], manifest(1)["unmanaged"]

    _rc, _out, err = rollback([])

    assert_includes err, %("tmux-alpha" left alone)
    refute File.symlink?(plugin_dir), "an unadopted directory must never be flipped"
    assert File.file?(File.join(plugin_dir, "SCRATCH"))
  end

  # --- retention and GC ---------------------------------------------------

  # Both halves of the GC rule in one run. After twelve ops only generations
  # 3..12 survive; the first entry is referenced by none of them and nothing
  # links it, so it goes — while the entry the plugin path stands on survives
  # even though it is older than every kept generation's *creation*.
  def test_pruning_keeps_ten_generations_and_gc_reclaims_only_dead_entries
    install(@repo)
    dead = File.readlink(plugin_dir)
    add_upstream_commit(@repo)
    update(@repo)
    live = File.readlink(plugin_dir)

    refute_equal dead, live
    assert_equal 2, store_entries.size
    assert File.directory?(dead), "an entry a kept generation references must survive unlinked"

    10.times { clean(@repo) }

    assert_equal (3..12).to_a, numbers
    assert_equal 10, numbers.size
    refute File.exist?(dead), "an entry no kept generation references must be reclaimed"
    assert File.directory?(live), "the entry the plugin path links to must never be reclaimed"
    assert_equal [live], store_entries
  end

  # Working forward after a rollback carries the *state*, not the number: the
  # marker moves onto each new generation, and once the generation you named
  # ages out its links live on in the ones that replaced it — so GC still may
  # not touch the entry you are standing on.
  def test_working_forward_after_a_rollback_carries_the_state_not_the_number
    install(@repo)
    rolled_back_to = File.readlink(plugin_dir)
    add_upstream_commit(@repo)
    update(@repo)
    superseded = File.readlink(plugin_dir)

    rollback(["1"])
    assert_equal rolled_back_to, File.readlink(plugin_dir)

    12.times { clean(@repo) }

    assert_equal (5..14).to_a, numbers
    assert_equal 14, current
    assert_equal rolled_back_to, File.readlink(plugin_dir)
    assert File.directory?(rolled_back_to), "GC must not reclaim the entry in use"
    refute File.exist?(superseded), "the abandoned entry must be reclaimed once its generations age out"
  end

  # --- surfaces -----------------------------------------------------------

  def test_status_lists_generations_newest_first_with_a_current_marker
    install(@repo)
    add_upstream_commit(@repo)
    update(@repo)
    rollback([])

    ui, out, = capture_ui
    Tempo::Commands.status(env_for(@repo), ui)
    lines = out.string.lines.map(&:rstrip)

    assert_includes out.string, "generations (newest first, keeping 10):"
    assert lines.any? { |l| l.start_with?("  * 1 ") }, out.string
    assert lines.any? { |l| l.start_with?("    2 ") }, out.string
    assert lines.index { |l| l.start_with?("    2 ") } < lines.index { |l| l.start_with?("  * 1 ") }
  end
end
