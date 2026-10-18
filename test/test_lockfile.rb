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

  # --- enforcement keeps the branch attached (D36) ---------------------------
  #
  # The documented undo is "revert tempo.lock, then install". A bare
  # `git checkout <sha>` would detach HEAD, and the next `git pull` — every
  # `prefix + U` — would fail with "You are not currently on a branch".

  # A plain clone that has run ahead of the lock: installed at C1 and locked
  # there, upstream moved to C2, the clone pulled to C2 on master. The stray
  # untracked file is the shape of a plugin that keeps local state in its
  # tree (tmux-resurrect strategies, friction log day 2).
  def plain_clone_ahead_of_lock
    install(env_for(@repo))
    locked = Tempo::Lockfile.read(lock_path).dig("tmux-example-plugin", "commit")
    add_upstream_commit(@repo)
    dir = File.join(@plugins, "tmux-example-plugin")
    FileUtils.rm_rf(dir)
    git(@dir, "clone", "-q", @repo, dir)
    File.write(File.join(dir, "local-state"), "kept\n")
    [dir, locked, git(@repo, "rev-parse", "HEAD").strip]
  end

  def test_restore_keeps_the_plugin_on_its_branch
    dir, locked, = plain_clone_ahead_of_lock

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.install(env_for(@repo), ui)

    assert_equal locked, git(dir, "rev-parse", "HEAD").strip
    assert_equal "refs/heads/master", git(dir, "symbolic-ref", "-q", "HEAD").strip
    assert_includes out.string, %("tmux-example-plugin" restored to #{locked[0, 12]})
  end

  def test_update_after_a_restore_succeeds_and_moves_the_pin
    dir, _locked, upstream = plain_clone_ahead_of_lock
    Tempo::Commands.install(env_for(@repo), capture_ui.first)

    ui, out, err = capture_ui
    assert_equal 0, Tempo::Commands.update(env_for(@repo), ui, ["all"]), err.string

    assert_includes out.string, %("tmux-example-plugin" update success)
    assert_equal upstream, git(dir, "rev-parse", "HEAD").strip
    assert_equal upstream, Tempo::Lockfile.read(lock_path).dig("tmux-example-plugin", "commit")
  end

  def test_restore_on_a_detached_head_still_reaches_the_commit
    dir, locked, = plain_clone_ahead_of_lock
    git(dir, "checkout", "-q", "--detach")

    assert_equal 0, Tempo::Commands.install(env_for(@repo), capture_ui.first)
    assert_equal locked, git(dir, "rev-parse", "HEAD").strip
  end

  # CHANGES exists only at C2, so moving to C1 would have to delete a file
  # the user edited. Enforcement must refuse like `git checkout` does, never
  # discard the edit the way `reset --hard` would.
  def test_restore_refuses_rather_than_discarding_a_local_edit
    dir, locked, upstream = plain_clone_ahead_of_lock
    File.write(File.join(dir, "CHANGES"), "my edit\n")
    lock_before = File.read(lock_path)

    ui, _, err = capture_ui
    assert_equal 1, Tempo::Commands.install(env_for(@repo), ui)

    assert_includes err.string, %("tmux-example-plugin" restore fail: locked commit #{locked[0, 12]})
    assert_equal upstream, git(dir, "rev-parse", "HEAD").strip
    assert_equal "my edit\n", File.read(File.join(dir, "CHANGES"))
    assert_equal lock_before, File.read(lock_path)
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


  # The observer cannot tell "nothing declared" from "tmux unreachable" or
  # "read the wrong config", so an empty declared set must write nothing:
  # the run that already refuses to clean must not erase the pins either.
  def test_install_with_nothing_declared_leaves_the_lock_and_artifact_alone
    install(env_for(@repo))
    lock_before = File.read(lock_path)
    env = env_for
    # The artifact is the most dangerous of the skipped writes: regenerating
    # from an empty observation would bake an empty load.sh with a fresh
    # fingerprint, and every plugin would stop loading until a config edit.
    File.write(env.artifact_path, "sentinel\n")

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.install(env, ui)

    assert_includes out.string, "No plugins declared"
    assert_equal lock_before, File.read(lock_path)
    assert_equal "sentinel\n", File.read(env.artifact_path)
  end

  # Frozen is the CI posture, and a gate that passes having verified nothing
  # is worse than one that fails: unlike plain install this exits 1.
  def test_frozen_install_with_nothing_declared_fails_and_touches_nothing
    install(env_for(@repo))
    lock_before = File.read(lock_path)
    env = env_for
    File.write(env.artifact_path, "sentinel\n")

    ui, _, err = capture_ui
    assert_equal 1, Tempo::Commands.install(env, ui, frozen: true)

    assert_includes err.string, "frozen: no plugins declared"
    assert_equal lock_before, File.read(lock_path)
    assert_equal "sentinel\n", File.read(env.artifact_path)
    # Before the guard, an empty set under --frozen had no violations and so
    # went straight to clean_undeclared: every installed plugin deleted, exit 0.
    assert File.exist?(File.join(@plugins, "tmux-example-plugin"))
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
    assert_includes err.string, "`tempo update tmux-example-plugin` moves the pin"
    assert_equal lock_before, File.read(lock_path)
  end

  # The same rule for update (found in review): `prefix + U` on a machine
  # where one declared plugin never cloned used to drop that plugin's pin at
  # exit 0, because the writer recorded disk and disk had nothing to say.
  def test_update_keeps_the_pin_of_a_declared_plugin_it_could_not_touch
    install(env_for(@repo))
    ghost = File.join(@fixtures, "tmux-ghost") # declared, locked elsewhere, never cloned here
    doc = JSON.parse(File.read(lock_path))
    doc["plugins"]["tmux-ghost"] = { "url" => ghost, "branch" => nil, "commit" => "f" * 40 }
    File.write(lock_path, "#{JSON.pretty_generate(doc)}\n")
    add_upstream_commit(@repo)

    assert_equal 0, Tempo::Commands.update(env_for(@repo, ghost), capture_ui.first, ["all"])

    lock = Tempo::Lockfile.read(lock_path)
    assert_equal "f" * 40, lock.dig("tmux-ghost", "commit")
    refute_equal doc.dig("plugins", "tmux-example-plugin", "commit"),
                 lock.dig("tmux-example-plugin", "commit"), "the updated plugin's pin must move"
  end

  def test_update_with_nothing_declared_touches_nothing
    install(env_for(@repo))
    lock_before = File.read(lock_path)
    env = env_for
    File.write(env.artifact_path, "sentinel\n")

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.update(env, ui, ["all"])

    assert_includes out.string, "No plugins declared"
    assert_equal lock_before, File.read(lock_path)
    assert_equal "sentinel\n", File.read(env.artifact_path)
  end

  # clean drops the entries of what it removed and nothing else; the `branch`
  # sentinel proves the surviving entry was carried, not re-derived.
  def test_clean_drops_undeclared_entries_and_carries_declared_ones_verbatim
    other = make_plugin_repo(@fixtures, "tmux-other-plugin")
    install(env_for(@repo, other))
    doc = JSON.parse(File.read(lock_path))
    doc["plugins"]["tmux-example-plugin"]["branch"] = "dev"
    File.write(lock_path, "#{JSON.pretty_generate(doc)}\n")

    assert_equal 0, Tempo::Commands.clean(env_for(@repo), capture_ui.first)

    lock = Tempo::Lockfile.read(lock_path)
    assert_equal %w[tmux-example-plugin], lock.keys
    assert_equal doc["plugins"]["tmux-example-plugin"], lock["tmux-example-plugin"]
    refute File.exist?(File.join(@plugins, "tmux-other-plugin"))
  end

  # What install may do to the lock: add an entry for a plugin it cloned,
  # drop one for a plugin it cleaned. An entry for a plugin that is still
  # declared is carried over byte for byte, even when disk has moved.
  #
  # The carried-over entry deliberately pins `branch` to a value the
  # declaration does not carry: a successful install puts disk back on the
  # locked commit, so `commit` alone cannot tell a snapshot writer from a
  # reconciling one, and an exit-code gate would pass the failure tests
  # while still re-deriving every pin on success. `branch` is the field that
  # only the declaration can produce, so it is the one that exposes a
  # re-derivation.
  def test_install_adds_and_drops_entries_but_never_rewrites_a_declared_one
    other = make_plugin_repo(@fixtures, "tmux-other-plugin")
    install(env_for(@repo))
    pinned = Tempo::Lockfile.read(lock_path).fetch("tmux-example-plugin").merge("branch" => "dev")

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

  # A lock that does not parse is a refusal, never an empty lock (D35):
  # reading it as {} made every plugin "never seen" and re-snapshotted disk
  # over the user's file. Missing is still {} — there is nothing to protect.
  def test_unparseable_lock_is_a_refusal_and_a_missing_one_is_empty
    assert_equal({}, Tempo::Lockfile.read(File.join(@dir, "tempo.lock")))
    File.write(File.join(@dir, "tempo.lock"), "not json{")
    err = assert_raises(Tempo::Lockfile::Unparseable) { Tempo::Lockfile.read(File.join(@dir, "tempo.lock")) }
    assert_includes err.message, "dotfiles history"
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
