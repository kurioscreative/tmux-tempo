# frozen_string_literal: true

require "helper"
require "pty"
require "timeout"

class TestInit < Minitest::Test
  include TempoTest

  # The checkout root Init derives from its own __dir__ (already realpath'd
  # by Ruby); every symlink assertion compares realpaths against this.
  ROOT = File.expand_path("..", __dir__)

  def setup
    @dir = Dir.mktmpdir("tempo-init")
    # xdg_conf reads ENV directly; a developer's XDG_CONFIG_HOME must not
    # leak real-home paths into the sandboxed Env.
    @old_xdg = ENV.delete("XDG_CONFIG_HOME")
  end

  def teardown
    ENV["XDG_CONFIG_HOME"] = @old_xdg if @old_xdg
    FileUtils.remove_entry(@dir)
  end

  def conf
    File.join(@dir, ".tmux.conf")
  end

  def link
    File.join(@dir, ".tmux", "plugins", "tempo")
  end

  def init_env(confs: nil)
    Tempo::Env.new(home: @dir, user_conf: conf, candidate_config_files: confs || [conf])
  end

  def run_init(env = init_env)
    ui, out, err = capture_ui
    [Tempo::Init.run(env, ui), out.string, err.string]
  end

  def test_fresh_creates_minimal_conf_and_symlink
    rc, = run_init
    assert_equal 0, rc
    assert_includes File.read(conf), "run '~/.tmux/plugins/tempo/tempo'"
    assert_includes File.read(conf), "@plugin" # commented example for first-timers
    assert File.symlink?(link)
    assert_equal File.realpath(ROOT), File.realpath(link)
    assert_empty Dir.glob("#{conf}.bak-*") # no backup for a conf init created
  end

  def test_fresh_appends_to_existing_conf_with_backup
    File.write(conf, "set -g @plugin 'tmux-plugins/tmux-sensible'\n")
    rc, = run_init
    assert_equal 0, rc
    content = File.read(conf)
    assert_includes content, "set -g @plugin 'tmux-plugins/tmux-sensible'"
    assert_includes content, "run '~/.tmux/plugins/tempo/tempo'"
    backups = Dir.glob("#{conf}.bak-*")
    assert_equal 1, backups.size
    assert_equal "set -g @plugin 'tmux-plugins/tmux-sensible'\n", File.read(backups.first)
  end

  def test_drop_in_backs_up_tpm_and_leaves_conf_byte_identical
    tpm = File.join(@dir, ".tmux", "plugins", "tpm")
    FileUtils.mkdir_p(tpm)
    File.write(File.join(tpm, "marker"), "original tpm\n")
    File.write(conf, "set -g @plugin 'tmux-plugins/tmux-sensible'\nrun '~/.tmux/plugins/tpm/tpm'\n")
    before = File.read(conf)

    rc, out, = run_init
    assert_equal 0, rc
    assert_includes out, "not modify your tmux config" # the plan states the promise
    assert_equal before, File.read(conf)
    assert File.symlink?(tpm)
    assert_equal File.realpath(ROOT), File.realpath(tpm)
    backups = Dir.glob(File.join(@dir, ".tmux", "plugins", "tpm.orig*"))
    assert_equal 1, backups.size
    assert_equal "original tpm\n", File.read(File.join(backups.first, "marker"))
  end

  def test_noop_when_run_line_already_resolves_into_checkout
    File.write(conf, "run '#{ROOT}/tempo'\n")
    before = File.read(conf)

    rc, out, = run_init
    assert_equal 0, rc
    assert_includes out, "Already set up"
    assert_equal before, File.read(conf)
    refute File.exist?(link)
  end

  def test_second_init_is_a_noop
    assert_equal 0, run_init.first
    after_first = File.read(conf)
    rc, out, = run_init
    assert_equal 0, rc
    assert_includes out, "Already set up"
    assert_equal after_first, File.read(conf)
  end

  # Consent surface: every mutation appears in the printed plan with its
  # final path — including the backup name — before anything runs. (The
  # TTY prompt itself is unreachable here: test stdin is never a TTY, so
  # init auto-proceeds, which is also what the acceptance gates pin.)
  def test_plan_lists_every_mutation_with_final_paths
    File.write(conf, "set -g @plugin 'x'\n")
    rc, out, = run_init
    assert_equal 0, rc
    assert_includes out, "tempo init will:"
    assert_includes out, "symlink #{link}"
    assert_includes out, "copy #{conf} -> #{Dir.glob("#{conf}.bak-*").first}"
    assert_includes out, "append to #{conf}: run '~/.tmux/plugins/tempo/tempo'"
  end

  # The decline branch is unreachable without a TTY, so pin it through a
  # real pty against the real bin. (Don't drive this with `script(1)`:
  # macOS script forwards EOF ahead of piped input, so the answer never
  # arrives — see NOTES.md.)
  def test_interactive_decline_aborts_without_touching_anything
    bin = File.expand_path("../bin/tempo", __dir__)
    status = nil
    buf = +""
    Timeout.timeout(15) do
      PTY.spawn({ "HOME" => @dir }, bin, "init") do |r, w, pid|
        buf << r.readpartial(4096) until buf.include?("Proceed?")
        w.write("n\n")
        begin
          loop { buf << r.readpartial(4096) }
        rescue EOFError, Errno::EIO
          nil
        end
        Process.wait(pid)
        status = $?.exitstatus
      end
    end
    assert_equal 1, status
    assert_includes buf, "tempo init will:"
    assert_includes buf, "Aborted: nothing was changed."
    refute File.exist?(conf)
    refute File.exist?(link)
  end

  def test_refuses_real_directory_at_canonical_path
    FileUtils.mkdir_p(link)
    File.write(conf, "set -g @plugin 'x'\n")
    before = File.read(conf)

    rc, _, err = run_init
    assert_equal 1, rc
    assert_includes err, link
    assert_equal before, File.read(conf) # refusal touches nothing
    assert_empty Dir.glob("#{conf}.bak-*")
    assert File.directory?(link)
    refute File.symlink?(link)
  end

  def test_fresh_respects_xdg_layout
    ENV["XDG_CONFIG_HOME"] = File.join(@dir, ".config")
    xdg_conf = File.join(@dir, ".config", "tmux", "tmux.conf")
    FileUtils.mkdir_p(File.dirname(xdg_conf))
    File.write(xdg_conf, "set -g @plugin 'x'\n")
    env = Tempo::Env.new(home: @dir, candidate_config_files: [xdg_conf])

    rc, = run_init(env)
    assert_equal 0, rc
    xdg_link = File.join(@dir, ".config", "tmux", "plugins", "tempo")
    assert File.symlink?(xdg_link)
    assert_includes File.read(xdg_conf), "run '~/.config/tmux/plugins/tempo/tempo'"
  end
end
