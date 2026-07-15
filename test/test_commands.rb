# frozen_string_literal: true

require "helper"
require "stringio"

class TestCommands < Minitest::Test
  include TempoTest

  def setup
    @dir = Dir.mktmpdir("tempo-cmd")
    @fixtures = File.join(@dir, "fixtures")
    @plugins = "#{File.join(@dir, "plugins")}/"
    @repo = make_plugin_repo(@fixtures, "tmux-example-plugin")
  end

  def teardown
    FileUtils.chmod_R("u+w", @dir)
    FileUtils.remove_entry(@dir)
  end

  def env_for(*specs)
    build_env(@dir, specs: specs)
  end

  def test_install_clone_already_installed_and_fail
    env = env_for(@repo)
    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.install(env, ui)
    assert_includes out.string, %(Installing "tmux-example-plugin")
    assert_includes out.string, %("tmux-example-plugin" download success)
    assert File.directory?(File.join(@plugins, "tmux-example-plugin", ".git"))

    ui2, out2, = capture_ui
    assert_equal 0, Tempo::Commands.install(env_for(@repo), ui2)
    assert_includes out2.string, %(Already installed "tmux-example-plugin")

    ui3, _, err3 = capture_ui
    bogus = env_for(File.join(@dir, "no-such-repo"))
    assert_equal 1, Tempo::Commands.install(bogus, ui3)
    assert_includes err3.string, %("no-such-repo" download fail)
  end

  def test_install_branch_pinning
    env = env_for("#{@repo}#dev")
    ui, = capture_ui
    assert_equal 0, Tempo::Commands.install(env, ui)
    dir = File.join(@plugins, "tmux-example-plugin")
    assert_equal "dev", git(dir, "rev-parse", "--abbrev-ref", "HEAD").strip
    assert File.file?(File.join(dir, "ON_BRANCH"))
    refute File.directory?(File.join(@plugins, "tmux-example-plugin#dev"))
  end

  def test_update_pulls_and_reports_indented_output
    env = env_for(@repo)
    Tempo::Commands.install(env, capture_ui.first)
    add_upstream_commit(@repo)

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.update(env_for(@repo), ui, ["tmux-example-plugin"])
    assert_includes out.string, %("tmux-example-plugin" update success)
    assert_includes out.string, "    | "
    assert File.file?(File.join(@plugins, "tmux-example-plugin", "CHANGES"))
  end

  def test_update_all_and_real_exit_code_for_not_installed
    env = env_for(@repo)
    Tempo::Commands.install(env, capture_ui.first)

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.update(env_for(@repo), ui, ["all"])
    assert_includes out.string, "Updating all plugins!"

    # Intentional divergence 1: the original always exited 0 here.
    ui2, _, err2 = capture_ui
    assert_equal 1, Tempo::Commands.update(env_for(@repo), ui2, ["tmux-nope"])
    assert_includes err2.string, "tmux-nope not installed!"
  end

  def test_update_no_args_usage
    ui, _, err = capture_ui
    assert_equal 1, Tempo::Commands.update(env_for(@repo), ui, [])
    assert_includes err.string, "usage"
  end

  def test_clean_exact_match_and_tpm_protection
    env = env_for(@repo)
    Tempo::Commands.install(env, capture_ui.first)
    FileUtils.mkdir_p(File.join(@plugins, "tmux-orphan"))
    FileUtils.mkdir_p(File.join(@plugins, "tpm"))
    # substring quirk dropped: a dir whose name is a substring of a declared
    # spec must still be removed when it isn't a declared plugin name
    FileUtils.mkdir_p(File.join(@plugins, "tmux-example"))

    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.clean(env_for(@repo), ui)
    assert_includes out.string, %(Removing "tmux-orphan")
    assert_includes out.string, %("tmux-orphan" clean success)
    assert_includes out.string, %("tmux-example" clean success)
    refute File.directory?(File.join(@plugins, "tmux-orphan"))
    assert File.directory?(File.join(@plugins, "tpm"))
    assert File.directory?(File.join(@plugins, "tmux-example-plugin"))
  end

  def test_clean_blocked_removal_fails
    env = env_for(@repo)
    blocked = File.join(@plugins, "tmux-blocked", "sub")
    FileUtils.mkdir_p(blocked)
    FileUtils.touch(File.join(blocked, "file"))
    File.chmod(0o555, blocked)

    ui, _, err = capture_ui
    assert_equal 1, Tempo::Commands.clean(env, ui)
    assert_includes err.string, %("tmux-blocked" clean fail)
  end

  def test_install_with_no_declared_plugins_prints_guidance
    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.install(env_for, ui)
    assert_includes out.string, "No plugins declared"
    assert_includes out.string, "@plugin"
  end

  def test_install_with_declared_plugin_omits_guidance
    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.install(env_for(@repo), ui)
    refute_includes out.string, "No plugins declared"
  end

  def test_mutating_commands_regenerate_artifact_and_lock
    env = env_for(@repo)
    Tempo::Commands.install(env, capture_ui.first)
    assert File.file?(env.artifact_path)
    assert File.file?(env.fingerprint_path)
    assert File.file?(env.lockfile_path)
    assert_includes File.read(env.artifact_path), "tmux-example-plugin/"
  end
end
