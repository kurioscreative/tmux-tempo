# frozen_string_literal: true

require "helper"

# Since D36 the undo for a bad update is restoring the previous tempo.lock
# from version control, so a lock git does not track is an undo that does
# not exist. The owner's own lock sat untracked for a month with nothing
# saying so; doctor is where that gets said.
class TestDoctor < Minitest::Test
  include TempoTest

  LOCK = %({\n  "version": 1,\n  "plugins": {}\n}\n)

  def setup
    @dir = Dir.mktmpdir("tempo-doctor")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def lockfile_line
    ui, out, = capture_ui
    Tempo::Doctor.run(build_env(@dir, specs: []), ui)
    out.string[/^lockfile:.*$/]
  end

  def test_a_lockfile_outside_any_repository_is_flagged
    File.write(File.join(@dir, "tempo.lock"), LOCK)
    assert_includes lockfile_line, "not tracked by git"
  end

  def test_a_lockfile_in_a_repository_but_never_added_is_flagged
    git(@dir, "init", "-q")
    File.write(File.join(@dir, "tempo.lock"), LOCK)
    assert_includes lockfile_line, "not tracked by git"
  end

  def test_a_committed_lockfile_is_not_flagged
    git(@dir, "init", "-q")
    File.write(File.join(@dir, "tempo.lock"), LOCK)
    git(@dir, "add", "tempo.lock")
    git(@dir, "commit", "-qm", "lock")

    line = lockfile_line
    assert_includes line, "OK (0 plugins locked)"
    refute_includes line, "not tracked"
  end
end
