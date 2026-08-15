# frozen_string_literal: true

require "helper"
require "pty"
require "timeout"

# The first-install consent gate (D23). Two halves: the decision matrix,
# exercised in-process against a Trust built by hand, and a pair of pty tests
# that drive the real `bin/tempo` through a terminal — the TTY branch is
# unreachable any other way, and the whole point of the gate is what a human
# sees before a clone happens.
class TestTrust < Minitest::Test
  include TempoTest

  def setup
    @dir = Dir.mktmpdir("tempo-trust")
    @fixtures = File.join(@dir, "fixtures")
    @plugins = "#{File.join(@dir, "plugins")}/"
    @repo = make_plugin_repo(@fixtures, "tmux-example-plugin")
    # Env#xdg_conf reads ENV directly even when home: is overridden, so a
    # developer's XDG setup must not leak into these sandboxes (NOTES.md).
    @old_xdg = ENV.delete("XDG_CONFIG_HOME")
    @old_markers = Tempo::Trust::MARKERS.to_h { |m| [m, ENV.delete(m)] }
  end

  def teardown
    ENV["XDG_CONFIG_HOME"] = @old_xdg if @old_xdg
    @old_markers.each { |m, v| v.nil? ? ENV.delete(m) : ENV[m] = v }
    FileUtils.remove_entry(@dir)
  end

  def env_for(*specs)
    build_env(@dir, specs: specs)
  end

  def trust_for(env, **opts)
    Tempo::Trust.new(env, **opts)
  end

  def spec_for(raw)
    Tempo::Spec.parse(raw)
  end

  # Answers the prompt from a StringIO and swallows the question text, which
  # Trust writes straight to the terminal rather than through `ui`.
  def with_answer(answer)
    old_in = $stdin
    old_out = $stdout
    $stdin = StringIO.new(answer)
    $stdout = StringIO.new
    yield $stdout
  ensure
    $stdin = old_in
    $stdout = old_out
  end

  # --- allowlist file ---------------------------------------------------

  def test_allowlist_reads_writes_appends_and_ignores_comments
    env = env_for
    trust = trust_for(env)
    assert_empty trust.trusted
    refute File.exist?(trust.path)

    trust.record(["https://example.com/a"])
    assert_equal ["https://example.com/a"], trust.trusted
    assert_includes File.read(trust.path), "# tempo trusted sources"

    trust.record(["https://example.com/b"])
    assert_equal ["https://example.com/a", "https://example.com/b"], trust.trusted

    # Recording a URL already present must not duplicate the line.
    trust.record(["https://example.com/a"])
    assert_equal 1, File.read(trust.path).scan("https://example.com/a").size

    File.write(trust.path, "# a comment\n\n  https://example.com/c  \n", mode: "a")
    assert_includes trust.trusted, "https://example.com/c"
    refute_includes trust.trusted, "# a comment"
    assert trust.trusted?("https://example.com/b")
  end

  # --- keyed on the resolved URL, never the name ------------------------

  def test_shorthand_records_both_resolved_forms_and_never_double_prompts
    env = env_for
    trust = trust_for(env, yes: true)
    spec = spec_for("tmux-plugins/tmux-sensible")
    ui, = capture_ui

    assert trust.allow?(spec, ui)
    assert_equal ["tmux-plugins/tmux-sensible",
                  "https://git::@github.com/tmux-plugins/tmux-sensible"], trust.trusted

    # A fresh, non-TTY, non-yes gate must sail straight through: the verbatim
    # form and the GitHub expansion are both on record.
    strict = trust_for(env, tty: false)
    ui2, _, err2 = capture_ui
    assert strict.allow?(spec, ui2)
    assert_empty err2.string
  end

  def test_a_changed_url_for_a_known_name_prompts_again
    env = env_for
    trust = trust_for(env, yes: true)
    ui, = capture_ui
    assert trust.allow?(spec_for("https://example.com/old/tmux-thing"), ui)

    # Same plugin *name*, different source. Name-keyed trust would wave this
    # through; URL-keyed trust must not.
    moved = spec_for("https://evil.example.com/new/tmux-thing")
    assert_equal "tmux-thing", moved.name
    strict = trust_for(env, tty: false)
    ui2, _, err2 = capture_ui
    refute strict.allow?(moved, ui2)
    assert_includes err2.string, "evil.example.com"
  end

  # --- decision matrix --------------------------------------------------

  def test_non_tty_skips_instructs_and_fails_the_run
    env = env_for(@repo)
    ui, out, err = capture_ui
    assert_equal 1, Tempo::Commands.install(env, ui, trust_for(env, tty: false))
    assert_includes err.string, "skipped: source not trusted"
    assert_includes err.string, @repo
    assert_includes err.string, "tempo trust tmux-example-plugin"
    assert_includes err.string, "--yes"
    refute_includes out.string, %(Installing "tmux-example-plugin")
    refute File.exist?(File.join(@plugins, "tmux-example-plugin"))
    refute File.exist?(trust_for(env).path)
  end

  def test_yes_bypasses_and_records
    env = env_for(@repo)
    ui, out, = capture_ui
    assert_equal 0, Tempo::Commands.install(env, ui, trust_for(env, yes: true))
    assert_includes out.string, %("tmux-example-plugin" download success)
    assert_equal [@repo], trust_for(env).trusted
  end

  def test_tty_prompt_accepted_installs_and_records
    env = env_for(@repo)
    ui, out, = capture_ui
    prompt = nil
    with_answer("y\n") do |terminal|
      assert_equal 0, Tempo::Commands.install(env, ui, trust_for(env, tty: true))
      prompt = terminal.string
    end
    assert_includes prompt, "[y/N]"
    assert_includes out.string, @repo # the resolved URL, before anything is fetched
    assert_includes out.string, %("tmux-example-plugin" download success)
    assert_equal [@repo], trust_for(env).trusted
  end

  def test_contract_mode_markers_bypass_the_gate_entirely
    env = env_for(@repo)
    assert_instance_of Tempo::Trust, Tempo::Trust.gate(env)

    Tempo::Trust::MARKERS.each do |marker|
      ENV[marker] = "1"
      assert_nil Tempo::Trust.gate(env), "#{marker} must disable the gate"
      ENV.delete(marker)
    end
  end

  # A nil gate is the contract-mode call shape: install must be silent about
  # trust and clone the never-seen source, exactly like the original tpm.
  def test_ungated_install_is_silent_and_clones
    env = env_for(@repo)
    ui, out, err = capture_ui
    assert_equal 0, Tempo::Commands.install(env, ui, nil)
    assert_includes out.string, %("tmux-example-plugin" download success)
    refute_includes out.string, "trust"
    refute_includes err.string, "trust"
    refute File.exist?(trust_for(env).path)
  end

  def test_declined_plugin_is_skipped_and_the_rest_proceed
    other = make_plugin_repo(@fixtures, "tmux-other-plugin")
    env = env_for(@repo, other)
    ui, out, err = capture_ui
    # One "n", one "y": the first declines, the second must still install.
    with_answer("n\ny\n") do
      assert_equal 1, Tempo::Commands.install(env, ui, trust_for(env, tty: true))
    end
    assert_includes err.string, %("tmux-example-plugin" skipped)
    refute File.exist?(File.join(@plugins, "tmux-example-plugin"))
    assert_includes out.string, %("tmux-other-plugin" download success)
    assert File.directory?(File.join(@plugins, "tmux-other-plugin"))
    assert_equal [other], trust_for(env).trusted
  end

  # --- surfaces that must never gate ------------------------------------

  def test_update_of_an_installed_plugin_never_gates
    env = env_for(@repo)
    Tempo::Commands.install(env, capture_ui.first, trust_for(env, yes: true))
    FileUtils.rm_f(trust_for(env).path) # forget the source entirely
    add_upstream_commit(@repo)

    ui, out, err = capture_ui
    assert_equal 0, Tempo::Commands.update(env_for(@repo), ui, ["all"])
    assert_includes out.string, %("tmux-example-plugin" update success)
    refute_includes err.string, "trust"
  end

  def test_sync_enforcing_the_lock_on_installed_plugins_never_gates
    env = env_for(@repo)
    Tempo::Commands.install(env, capture_ui.first, trust_for(env, yes: true))
    first = Tempo::Git.head_commit(File.join(@plugins, "tmux-example-plugin"))
    add_upstream_commit(@repo)
    Tempo::Commands.update(env_for(@repo), capture_ui.first, ["all"])

    # Pin the lock back to the original commit, then forget the source.
    doc = JSON.parse(File.read(env.lockfile_path))
    doc["plugins"]["tmux-example-plugin"]["commit"] = first
    File.write(env.lockfile_path, "#{JSON.pretty_generate(doc)}\n")
    FileUtils.rm_f(trust_for(env).path)

    fresh = env_for(@repo)
    ui, out, err = capture_ui
    assert_equal 0, Tempo::Commands.sync(fresh, ui, trust: trust_for(fresh, tty: false))
    assert_includes out.string, %("tmux-example-plugin" restored to)
    refute_includes err.string, "trust"
  end

  def test_sync_cloning_a_never_seen_missing_plugin_gates
    env = env_for(@repo)
    ui, _, err = capture_ui
    assert_equal 1, Tempo::Commands.sync(env, ui, trust: trust_for(env, tty: false))
    assert_includes err.string, %("tmux-example-plugin" skipped)
    refute File.exist?(File.join(@plugins, "tmux-example-plugin"))
  end

  # --- `tempo trust` ----------------------------------------------------

  def test_trust_command_records_by_url_and_by_declared_name
    env = env_for(@repo)
    ui, out, = capture_ui
    assert_equal 0, Tempo::Trust.run(env, ui, ["tmux-example-plugin"])
    assert_equal [@repo], trust_for(env).trusted
    assert_includes out.string, "trusted #{@repo}"

    ui2, = capture_ui
    assert_equal 0, Tempo::Trust.run(env, ui2, ["tmux-plugins/tmux-sensible"])
    assert_includes trust_for(env).trusted, "https://git::@github.com/tmux-plugins/tmux-sensible"

    ui3, _, err3 = capture_ui
    assert_equal 1, Tempo::Trust.run(env, ui3, ["nope"])
    assert_includes err3.string, "no declared plugin"

    ui4, _, err4 = capture_ui
    assert_equal 1, Tempo::Trust.run(env, ui4, [])
    assert_includes err4.string, "usage:"
  end

  # A recorded source installs without a word about trust — `tempo trust`
  # has to actually unblock the gate it is advertised in.
  def test_trust_command_unblocks_a_later_non_tty_install
    env = env_for(@repo)
    Tempo::Trust.run(env, capture_ui.first, [@repo])

    ui, out, err = capture_ui
    assert_equal 0, Tempo::Commands.install(env_for(@repo), ui, trust_for(env, tty: false))
    assert_includes out.string, %("tmux-example-plugin" download success)
    refute_includes err.string, "skipped"
  end

  # --- pty: the real binary, through a real terminal --------------------

  def test_pty_prompt_shows_the_url_installs_on_y_and_never_asks_twice
    buf, status = pty_install
    assert_equal 0, status
    assert_includes buf, @repo # the resolved URL, in the prompt itself
    assert_includes buf, "[y/N]"
    assert_includes buf, %("tmux-example-plugin" download success)
    assert File.directory?(File.join(pty_plugins, "tmux-example-plugin"))
    assert_equal [@repo], File.readlines(pty_allowlist, chomp: true).grep_v(/\A#|\A\z/)

    # Second run: same URL, already recorded — no prompt, nothing to answer.
    buf2, status2 = pty_install(expect_prompt: false)
    assert_equal 0, status2
    refute_includes buf2, "[y/N]"
    assert_includes buf2, %(Already installed "tmux-example-plugin")
  end

  def test_pty_prompt_declined_clones_nothing_and_leaves_the_allowlist_alone
    buf, status = pty_install(answer: "n\n")
    assert_equal 1, status
    assert_includes buf, "[y/N]"
    assert_includes buf, "skipped"
    refute File.exist?(File.join(pty_plugins, "tmux-example-plugin"))
    refute File.exist?(pty_allowlist)
  end

  private

  def pty_home
    @pty_home ||= begin
      home = File.join(@dir, "pty-home")
      FileUtils.mkdir_p(File.join(home, "sock"))
      File.write(File.join(home, ".tmux.conf"), "set -g @plugin '#{@repo}'\n")
      home
    end
  end

  def pty_plugins
    File.join(pty_home, ".tmux", "plugins")
  end

  def pty_allowlist
    File.join(pty_home, "data", "tempo", "trusted_urls")
  end

  # Drives bin/tempo through a real pty. Never `script(1)`: macOS forwards EOF
  # ahead of piped input, so the answer never reaches the child (NOTES.md).
  # TMUX_TMPDIR is a sandbox path and TMUX is cleared, so the tmux server the
  # Env queries start can never be the developer's own.
  def pty_install(answer: "y\n", expect_prompt: true)
    bin = File.expand_path("../bin/tempo", __dir__)
    env = { "HOME" => pty_home, "XDG_DATA_HOME" => File.join(pty_home, "data"),
            "TMUX_TMPDIR" => File.join(pty_home, "sock"), "TMUX" => nil, "TMUX_PANE" => nil }
    buf = +""
    status = nil
    Timeout.timeout(60) do
      PTY.spawn(env, bin, "install") do |r, w, pid|
        if expect_prompt
          buf << r.readpartial(4096) until buf.include?("[y/N]")
          w.write(answer)
        end
        begin
          loop { buf << r.readpartial(4096) }
        rescue EOFError, Errno::EIO
          nil
        end
        Process.wait(pid)
        status = $?.exitstatus
      end
    end
    [buf, status]
  ensure
    # Explicit socket path, never $TMUX or the ambient TMUX_TMPDIR: this line
    # must be incapable of reaching the developer's own server.
    system("tmux", "-S", File.join(pty_home, "sock", "tmux-#{Process.uid}", "default"),
           "kill-server", out: File::NULL, err: File::NULL)
  end
end
