# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "stringio"
require "tempo"

# Isolation by construction, not by a run prefix (NOTES 2026-08-16 / 09-15).
# Every tmux server a test starts lives on this socket dir, so the kill at
# the end can only ever reach sandbox servers; XDG_DATA_HOME is absolute and
# would otherwise send a forgotten `data_dir:` override at the operator's
# real store; the three unsets stop a shell inside tmux from handing the
# operator's real session and plugin path to the code under test.
# Minitest.after_run, not at_exit: minitest/autorun registered its own
# at_exit first, and at_exit handlers run last-in-first-out, so a plain
# at_exit here would fire before a single test had run.
TEMPO_TEST_ISOLATION = Dir.mktmpdir("tempo-test-iso")
ENV["TMUX_TMPDIR"] = File.join(TEMPO_TEST_ISOLATION, "sock").tap { |d| Dir.mkdir(d) }
ENV["XDG_DATA_HOME"] = File.join(TEMPO_TEST_ISOLATION, "data")
%w[TMUX TMUX_PANE TMUX_PLUGIN_MANAGER_PATH].each { |k| ENV.delete(k) }
Minitest.after_run do
  system("tmux", "kill-server", out: File::NULL, err: File::NULL)
  FileUtils.remove_entry(TEMPO_TEST_ISOLATION)
end

module TempoTest
  # A local git repo usable as a plugin source (specs are tried verbatim as
  # git URLs, so local paths clone offline). Mirrors the compat suite's
  # fixture shape: a <name>.tmux file that logs its own $0, plus a `dev`
  # branch carrying an ON_BRANCH marker.
  def make_plugin_repo(root, name)
    dir = File.join(root, name)
    FileUtils.mkdir_p(dir)
    git(dir, "init", "-q", "-b", "master")
    File.write(File.join(dir, "#{name}.tmux"), <<~SH)
      #!/usr/bin/env bash
      echo "$0" >> "$PLUGIN_RUN_LOG"
    SH
    File.chmod(0o755, File.join(dir, "#{name}.tmux"))
    git(dir, "add", "-A")
    git(dir, "commit", "-qm", "init")
    git(dir, "checkout", "-qb", "dev")
    File.write(File.join(dir, "ON_BRANCH"), "dev\n")
    git(dir, "add", "-A")
    git(dir, "commit", "-qm", "dev branch")
    git(dir, "checkout", "-q", "master")
    dir
  end

  def add_upstream_commit(dir)
    File.write(File.join(dir, "CHANGES"), "update #{Time.now.to_f}\n", mode: "a")
    git(dir, "add", "-A")
    git(dir, "commit", "-qm", "upstream change")
  end

  def git(dir, *args)
    out, status = Open3.capture2e(
      "git", "-C", dir,
      "-c", "user.name=tempo-test", "-c", "user.email=tempo-test@example.com",
      "-c", "commit.gpgsign=false", *args
    )
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out
  end

  # An Env wired entirely from overrides — no tmux, no real $HOME.
  def build_env(dir, specs:, **extra)
    Tempo::Env.new(
      plugin_path: "#{File.join(dir, "plugins")}/",
      specs: specs,
      tpm_plugins_option: "",
      candidate_config_files: [],
      data_dir: File.join(dir, "data"),
      lockfile_path: File.join(dir, "tempo.lock"),
      home: dir,
      **extra
    )
  end

  def capture_ui
    out = StringIO.new
    err = StringIO.new
    [Tempo::UI.new(out: out, err: err), out, err]
  end
end
