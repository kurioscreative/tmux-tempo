# frozen_string_literal: true

require "helper"
require "digest"
require "json"

# The content-addressed store (D24). Everything here is about the two claims
# the layout makes and nothing else can prove: an entry is filed once per
# `(url, commit)` and is shared, and a filed entry is never mutated again —
# updates and restores move the *link*, not the clone.
class TestStore < Minitest::Test
  include TempoTest

  def setup
    @dir = Dir.mktmpdir("tempo-store")
    @fixtures = File.join(@dir, "fixtures")
    @plugins = "#{File.join(@dir, "plugins")}/"
    @repo = make_plugin_repo(@fixtures, "tmux-alpha")
  end

  def teardown
    FileUtils.chmod_R("u+w", @dir)
    FileUtils.remove_entry(@dir)
  end

  def env_for(*specs, **extra)
    build_env(@dir, specs: specs, **extra)
  end

  def plugin_dir(name = "tmux-alpha")
    File.join(@plugins, name)
  end

  def store_root
    File.join(@dir, "data", "store")
  end

  # Every filed entry, as <digest>/<commit> paths. The `.staging` scratch dir
  # is dotted, so a plain `*` glob cannot see it — which is the point.
  def entries
    Dir.glob(File.join(store_root, "*", "*")).sort
  end

  def entry_heads
    entries.to_h { |e| [e, Tempo::Git.head_commit(e)] }
  end

  def install(*specs, **extra)
    ui, out, err = capture_ui
    rc = Tempo::Commands.install(env_for(*specs, **extra), ui)
    [rc, out.string, err.string]
  end

  # A plugin directory in the old flat layout: a real clone tempo did not make.
  def flat_clone(name = "tmux-alpha")
    FileUtils.mkdir_p(@plugins)
    system("git", "clone", "-q", @repo, plugin_dir(name), out: File::NULL, err: File::NULL)
    plugin_dir(name)
  end

  # --- filing and sharing ------------------------------------------------

  # One entry, two plugin paths. This is the whole reason for the store: a
  # second config on the same machine costs a symlink, not a clone.
  def test_entry_is_filed_once_per_url_commit_and_shared_across_plugin_paths
    a = "#{File.join(@dir, "plugins-a")}/"
    b = "#{File.join(@dir, "plugins-b")}/"
    install(@repo, plugin_path: a, lockfile_path: File.join(@dir, "a.lock"))
    install(@repo, plugin_path: b, lockfile_path: File.join(@dir, "b.lock"))

    link_a = File.join(a, "tmux-alpha")
    link_b = File.join(b, "tmux-alpha")
    assert File.symlink?(link_a)
    assert File.symlink?(link_b)
    assert_equal File.readlink(link_a), File.readlink(link_b), "both paths must share one entry"
    assert_equal 1, entries.size, "the same (url, commit) must be filed exactly once"
  end

  # The key: <sha256(url)>/<commit>, with the URL recoverable from the entry's
  # own origin remote rather than by inverting the digest.
  def test_entry_key_is_the_url_digest_and_the_commit
    install(@repo)
    entry = File.realpath(plugin_dir)
    digest, commit = entry.split(File::SEPARATOR).last(2)

    assert_equal Tempo::Git.head_commit(entry), commit
    assert_equal Digest::SHA256.hexdigest(Tempo::Git.remote_url(entry)), digest
    assert_equal @repo, Tempo::Git.remote_url(entry)
  end

  # The compat contract pins `rev-parse --abbrev-ref HEAD` on a #branch
  # install, so entries built by install must keep an attached HEAD — a store
  # that detached everything to match its commit key would break parity.
  def test_branch_pinned_install_keeps_an_attached_head_in_the_entry
    install("#{@repo}#dev")

    assert_equal "dev", git(plugin_dir, "rev-parse", "--abbrev-ref", "HEAD").strip
    assert File.file?(File.join(plugin_dir, "ON_BRANCH"))
  end

  # --- immutability ------------------------------------------------------

  # The load-bearing test: update must file a NEW entry and leave the old one
  # byte-for-byte where it was. An implementation that pulls through the
  # symlink passes every user-visible assertion and fails this one.
  def test_update_files_a_new_entry_and_leaves_the_old_one_untouched
    install(@repo)
    old_entry = File.realpath(plugin_dir)
    old_head = Tempo::Git.head_commit(old_entry)
    add_upstream_commit(@repo)

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.update(env_for(@repo), ui, ["tmux-alpha"])
    assert_includes out.string, %("tmux-alpha" update success)
    assert_includes out.string, "    | " # still the real `git pull` report

    new_entry = File.realpath(plugin_dir)
    refute_equal old_entry, new_entry, "update must land on a new entry"
    assert File.directory?(old_entry), "the old entry must survive"
    assert_equal old_head, Tempo::Git.head_commit(old_entry), "the old entry must not move"
    refute File.exist?(File.join(old_entry, "CHANGES")), "the pull must not touch the old entry"

    assert_equal File.basename(new_entry), Tempo::Git.head_commit(new_entry)
    assert File.file?(File.join(plugin_dir, "CHANGES")), "the link must show the pulled tree"
    assert_equal 2, entries.size
    assert_empty Dir.glob(File.join(@plugins, ".*.link.*")), "no flip temp may be left behind"
  end

  # Restore is a flip: it lands on the entry that already holds the locked
  # commit and mutates nothing at all — not the entry it leaves, not the one
  # it arrives at, and it files nothing new.
  def test_restore_flips_to_the_locked_entry_without_mutating_any_entry
    install(@repo)
    entry_before = File.realpath(plugin_dir)
    lock_path = File.join(@dir, "tempo.lock")
    lock_bytes = File.read(lock_path)

    add_upstream_commit(@repo)
    Tempo::Commands.update(env_for(@repo), capture_ui.first, ["tmux-alpha"])
    File.write(lock_path, lock_bytes) # the lock is the committed one; disk ran ahead
    refute_equal entry_before, File.realpath(plugin_dir)
    heads_before = entry_heads

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.restore(env_for(@repo), ui)
    assert_includes out.string, %("tmux-alpha" restored to)
    assert_equal entry_before, File.realpath(plugin_dir), "restore must flip back to the filed entry"
    assert_equal heads_before, entry_heads, "no entry may move during a restore"
    assert_equal 2, entries.size, "a flip must not file anything"
  end

  # --- lazy adoption -----------------------------------------------------

  # The migration path: a real clone from tpm (or from a user's own hands)
  # becomes a store entry on the first mutating op, at exactly the commit it
  # was already on, and says nothing about it.
  def test_clean_flat_dir_is_adopted_at_the_same_head
    flat_clone
    head = Tempo::Git.head_commit(plugin_dir)
    refute File.symlink?(plugin_dir)

    rc, out, err = install(@repo)
    assert_equal 0, rc
    assert_includes out, %(Already installed "tmux-alpha")
    assert_empty err, "a successful adoption must be silent"
    assert File.symlink?(plugin_dir), "the flat dir must become a link"
    assert_equal head, Tempo::Git.head_commit(plugin_dir), "adoption must not move HEAD"
    assert_equal 1, entries.size
    assert File.realpath(plugin_dir).start_with?(File.realpath(store_root))
  end

  # The negative pair. A dirty tree is never swallowed into a shared entry:
  # it keeps its real directory and its uncommitted work, the op still exits
  # 0, and the orphan beside it is still cleaned — so this is a scoped refusal,
  # not a bailout.
  def test_dirty_flat_dir_is_kept_as_a_real_directory_and_warned_about
    flat_clone
    File.write(File.join(plugin_dir, "LOCAL-WORK"), "mine\n")
    FileUtils.mkdir_p(File.join(@plugins, "tmux-orphan"))

    ui, out, err = capture_ui
    assert_equal 0, Tempo::Commands.sync(env_for(@repo), ui), "a declined adoption is not a failure"
    assert_includes err.string, %("tmux-alpha")
    assert_includes err.string, "uncommitted changes"
    refute File.symlink?(plugin_dir), "a dirty tree must stay a real directory"
    assert File.file?(File.join(plugin_dir, "LOCAL-WORK")), "local work must survive"
    assert_empty entries, "nothing may be filed from a dirty tree"

    refute File.directory?(File.join(@plugins, "tmux-orphan")), "clean must still run"
    assert_includes out.string, %("tmux-orphan" clean success)
  end

  # The other half of the clean-only rule: a commit that exists nowhere but
  # this working copy would be silently shared with every other config if the
  # directory were filed, so it is not.
  def test_flat_dir_with_a_local_only_commit_is_not_adopted
    flat_clone
    File.write(File.join(plugin_dir, "LOCAL-COMMIT"), "mine\n")
    git(plugin_dir, "add", "-A")
    git(plugin_dir, "commit", "-qm", "local only")

    ui, _, err = capture_ui
    assert_equal 0, Tempo::Commands.install(env_for(@repo), ui)
    assert_includes err.string, "no remote branch"
    refute File.symlink?(plugin_dir)
    assert_empty entries
  end

  # A never-adopted directory has to keep working forever, not merely keep
  # existing: the hybrid layout is supported, so update still pulls in place.
  def test_update_still_pulls_a_never_adopted_directory_in_place
    flat_clone
    File.write(File.join(plugin_dir, "LOCAL-WORK"), "mine\n")
    add_upstream_commit(@repo)

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.update(env_for(@repo), ui, ["tmux-alpha"])
    assert_includes out.string, %("tmux-alpha" update success)
    refute File.symlink?(plugin_dir)
    assert File.file?(File.join(plugin_dir, "CHANGES")), "the in-place pull must land"
    assert File.file?(File.join(plugin_dir, "LOCAL-WORK"))
  end

  # --- links that outlive their target -----------------------------------

  # A wiped store (or a store on a volume that did not mount) leaves dangling
  # links. `installed?` reads them as missing, and install must be able to
  # clone over the corpse instead of colliding with it.
  def test_dangling_link_after_a_wiped_store_reinstalls
    install(@repo)
    FileUtils.rm_rf(store_root)

    assert File.symlink?(plugin_dir)
    refute File.exist?(plugin_dir), "the link must now dangle"
    refute env_for(@repo).installed?("tmux-alpha")

    rc, out, = install(@repo)
    assert_equal 0, rc
    assert_includes out, %("tmux-alpha" download success)
    assert File.symlink?(plugin_dir)
    assert File.file?(File.join(plugin_dir, "tmux-alpha.tmux"))
    assert_equal 1, entries.size
  end

  # Clean removes the LINK. The entry stays filed — it may still be the
  # current version for another config, and retention is generations' job.
  def test_clean_removes_the_link_and_leaves_the_entry_filed
    install(@repo)
    entry = File.realpath(plugin_dir)
    head = Tempo::Git.head_commit(entry)

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.clean(env_for, ui)
    assert_includes out.string, %("tmux-alpha" clean success)
    refute File.symlink?(plugin_dir)
    refute File.exist?(plugin_dir)

    assert File.directory?(entry), "clean must never reach into the store"
    assert_equal head, Tempo::Git.head_commit(entry)
  end
end
