# frozen_string_literal: true

require "helper"

class TestGenerator < Minitest::Test
  include TempoTest

  def setup
    @dir = Dir.mktmpdir("tempo-gen")
    @plugins = "#{File.join(@dir, "plugins")}/"
    FileUtils.mkdir_p(@plugins)
    @log = File.join(@dir, "ran.log")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def env_for(*specs)
    build_env(@dir, specs: specs)
  end

  def make_installed(name)
    dir = File.join(@plugins, name)
    FileUtils.mkdir_p(dir)
    dir
  end

  def tmux_file(plugin_dir, filename, executable: true)
    path = File.join(plugin_dir, filename)
    File.write(path, "#!/bin/sh\necho \"$0\" >> \"$PLUGIN_RUN_LOG\"\n")
    File.chmod(executable ? 0o755 : 0o644, path)
    path
  end

  def run_artifact(env)
    out, status = Open3.capture2e(
      { "PLUGIN_RUN_LOG" => @log }, "sh", env.artifact_path
    )
    [out, status]
  end

  def ran
    File.file?(@log) ? File.read(@log).split("\n") : []
  end

  def test_executes_top_level_tmux_files_byte_sorted
    dir = make_installed("tmux-example")
    # (case pairs like B.tmux/b.tmux can't coexist on APFS; underscore
    # still distinguishes byte order from naive expectations: _ < a < b)
    tmux_file(dir, "b.tmux")
    tmux_file(dir, "a.tmux")
    tmux_file(dir, "_zz.tmux")
    FileUtils.mkdir_p(File.join(dir, "scripts"))
    tmux_file(File.join(dir, "scripts"), "nested.tmux")

    env = env_for("owner/tmux-example")
    Tempo::Generator.new(env).generate
    _, status = run_artifact(env)

    assert_equal 0, status.exitstatus
    assert_equal %w[_zz.tmux a.tmux b.tmux], ran.map { |p| File.basename(p) }
  end

  def test_missing_plugin_dir_is_silent_and_exits_zero
    env = env_for("owner/never-installed")
    Tempo::Generator.new(env).generate
    out, status = run_artifact(env)

    assert_equal 0, status.exitstatus
    assert_equal "", out
    assert_empty ran
  end

  def test_non_executable_file_warns_and_later_plugins_still_run
    broken = make_installed("tmux-broken")
    tmux_file(broken, "tmux-broken.tmux", executable: false)
    good = make_installed("tmux-good")
    tmux_file(good, "tmux-good.tmux")

    env = env_for("o/tmux-broken", "o/tmux-good")
    Tempo::Generator.new(env).generate
    out, status = run_artifact(env)

    assert_equal 0, status.exitstatus
    assert_includes out, "tempo: warning: skipping non-executable"
    assert_includes out, "tmux-broken.tmux"
    assert_equal %w[tmux-good.tmux], ran.map { |p| File.basename(p) }
  end

  def test_plugin_output_is_discarded_and_zero_double_slash
    dir = make_installed("tmux-noisy")
    path = File.join(dir, "tmux-noisy.tmux")
    File.write(path, "#!/bin/sh\necho \"$0\" >> \"$PLUGIN_RUN_LOG\"\necho LOUD\necho LOUDER >&2\n")
    File.chmod(0o755, path)

    env = env_for("o/tmux-noisy")
    Tempo::Generator.new(env).generate
    out, = run_artifact(env)

    assert_equal "", out, "plugin stdout/stderr must be discarded"
    refute_includes ran.first, "//", "the original's $0 double slash is normalized"
    assert ran.first.end_with?("tmux-noisy/tmux-noisy.tmux")
  end

  def test_fingerprint_format
    conf = File.join(@dir, "tmux.conf")
    File.write(conf, "set -g @plugin 'a/b'\n")
    env = build_env(@dir, specs: nil,
                         candidate_config_files: [conf, File.join(@dir, "missing.conf")],
                         tpm_plugins_option: "x/y z/w")
    body = Tempo::Generator.new(env).fingerprint_body
    lines = body.split("\n")

    assert_equal "tempo-fingerprint 1", lines[0]
    assert_equal "path #{File.join(@dir, "plugins")}/", lines[1]
    assert_equal "tpm_plugins x/y z/w", lines[2]
    st = File.stat(conf)
    assert_includes lines, "f #{st.mtime.to_i} #{st.size} #{conf}"
    assert_includes lines, "m #{File.join(@dir, "missing.conf")}"
  end

  def test_artifact_quotes_paths_with_spaces_and_quotes
    weird = "#{File.join(@dir, "pl ug'ins")}/"
    env = Tempo::Env.new(plugin_path: weird, specs: ["o/name"],
                         tpm_plugins_option: "", candidate_config_files: [],
                         data_dir: File.join(@dir, "data"), home: @dir)
    Tempo::Generator.new(env).generate
    _, status = Open3.capture2e("sh", "-n", env.artifact_path)
    assert_equal 0, status.exitstatus, "artifact must stay valid sh"
    assert_includes File.read(env.artifact_path), "pl ug'\\''ins"
  end
end
