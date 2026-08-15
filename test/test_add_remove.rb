# frozen_string_literal: true

require "helper"
require "pty"
require "timeout"

# `tempo add` / `tempo remove` (D22): the config file is the manifest, so
# these tests are mostly about bytes in a config file — what lands in it, what
# survives, and what tempo refuses to touch at all.
#
# The refusal cases are the point. Every one of them must exit 1, name the
# exact `file:line`, and leave the config byte-identical: a manager that
# "helpfully" rewrites a hand-tuned config is worse than one that says no.
class TestAddRemove < Minitest::Test
  include TempoTest

  def setup
    @dir = Dir.mktmpdir("tempo-edit")
    @fixtures = File.join(@dir, "fixtures")
    # Env#xdg_conf reads ENV directly even when home: is overridden, and the
    # data dir would follow XDG_DATA_HOME (NOTES.md).
    @old_xdg_conf = ENV.delete("XDG_CONFIG_HOME")
    @old_xdg_data = ENV.delete("XDG_DATA_HOME")
    @old_markers = Tempo::Trust::MARKERS.to_h { |m| [m, ENV.delete(m)] }
  end

  def teardown
    ENV["XDG_CONFIG_HOME"] = @old_xdg_conf if @old_xdg_conf
    ENV["XDG_DATA_HOME"] = @old_xdg_data if @old_xdg_data
    @old_markers.each { |m, v| v.nil? ? ENV.delete(m) : ENV[m] = v }
    FileUtils.remove_entry(@dir)
  end

  def conf
    File.join(@dir, ".tmux.conf")
  end

  def write_conf(text)
    File.write(conf, text)
  end

  # A real scanning Env (no `specs:` override): `add` writes a line and the
  # install that follows has to see it.
  def env_for(candidates: [conf], **extra)
    build_env(@dir, specs: nil, tpm_plugins_option: "",
                    candidate_config_files: candidates, user_conf: conf, **extra)
  end

  def add(*args, env: env_for, trust: nil)
    ui, out, err = capture_ui
    [Tempo::ConfigEdit.add(env, ui, args, trust: trust), out.string, err.string]
  end

  def remove(*args, env: env_for)
    ui, out, err = capture_ui
    [Tempo::ConfigEdit.remove(env, ui, args), out.string, err.string]
  end

  def backups
    Dir.glob("#{conf}.bak-*")
  end

  # `add` always installs, so every add test declares a *local* git repo:
  # the whole suite stays offline, and the install half is real rather than
  # stubbed.
  def repo
    @repo ||= make_plugin_repo(@fixtures, "tmux-example-plugin")
  end

  # --- add: what lands in the file ---------------------------------------

  def test_append_is_the_byte_exact_canonical_line
    write_conf("set -g status on\n")
    code, out, = add(repo)

    assert_equal 0, code
    assert_equal "set -g status on\nset -g @plugin '#{repo}'\n", File.read(conf)
    assert_includes out, "Added to #{conf}"
  end

  # A config whose last byte is not a newline would otherwise get the
  # declaration glued onto the end of the user's last line.
  def test_append_terminates_a_config_that_has_no_trailing_newline
    write_conf("set -g status on")
    add(repo)

    assert_equal "set -g status on\nset -g @plugin '#{repo}'\n", File.read(conf)
  end

  # Dotfiles setups symlink the conf into a repo. The link must survive and
  # the real file must change — the same rule the lockfile follows (D11/D14).
  def test_append_writes_through_a_symlinked_conf_and_backs_it_up
    real = File.join(@dir, "dotfiles", "tmux.conf")
    FileUtils.mkdir_p(File.dirname(real))
    File.write(real, "set -g status on\n")
    File.symlink(real, conf)

    code, = add(repo)

    assert_equal 0, code
    assert File.symlink?(conf), "the conf must still be a symlink"
    assert_equal real, File.readlink(conf)
    assert_includes File.read(real), "set -g @plugin '#{repo}'"
    assert_equal 1, backups.size
    refute File.symlink?(backups.first)
    assert_equal "set -g status on\n", File.read(backups.first)
  end

  # The spec grammar is uniform, so `add` serializes whatever the user typed —
  # a #branch pin included — and the install half honours it.
  def test_a_branch_suffix_is_serialized_verbatim
    write_conf("")
    code, out, = add("#{repo}#dev")

    assert_equal 0, code
    assert_equal "set -g @plugin '#{repo}#dev'\n", File.read(conf)
    assert_includes out, %("tmux-example-plugin" download success)
    assert File.exist?(File.join(@dir, "plugins", "tmux-example-plugin", "ON_BRANCH"))
  end

  def test_add_creates_a_missing_config_without_a_backup
    code, = add(repo)

    assert_equal 0, code
    assert_equal "set -g @plugin '#{repo}'\n", File.read(conf)
    assert_empty backups
  end

  # --- add: idempotency, by parsing rather than string matching -----------

  def test_add_is_idempotent_across_every_quote_form
    ["'#{repo}'", %("#{repo}"), repo].each do |quoted|
      write_conf("set -g @plugin #{quoted}\n")
      before = File.read(conf)

      code, out, = add(repo)

      assert_equal 0, code, "an already-declared plugin is not an error"
      assert_equal before, File.read(conf), "#{quoted}: appended a duplicate declaration"
      assert_includes out, "Already declared"
      assert_includes out, "#{conf}:1"
      assert_empty backups, "#{quoted}: backed up a file it did not change"
    end
  end

  def test_add_does_not_duplicate_a_legacy_tpm_plugins_membership
    write_conf(%(set -g @tpm_plugins "#{repo} other/thing"\n))
    before = File.read(conf)

    code, out, = add(repo)

    assert_equal 0, code
    assert_equal before, File.read(conf)
    assert_includes out, "Already declared"
  end

  # Same list grammar as `tempo trust`. The repeat is the interesting half:
  # the second pass has to see the line the first one just wrote.
  def test_add_takes_a_list_and_never_repeats_itself
    other = make_plugin_repo(@fixtures, "tmux-other-plugin")
    write_conf("")

    code, = add(repo, other, repo)

    assert_equal 0, code
    assert_equal "set -g @plugin '#{repo}'\nset -g @plugin '#{other}'\n", File.read(conf)
  end

  def test_add_without_a_spec_is_a_usage_error
    code, _, err = add

    assert_equal 1, code
    assert_includes err, "usage: tempo add"
  end

  # --- add: the install half ---------------------------------------------

  def test_add_installs_the_plugin_and_writes_the_lock
    write_conf("")

    code, out, = add(repo)

    assert_equal 0, code
    assert_includes File.read(conf), "set -g @plugin '#{repo}'"
    assert_includes out, %("tmux-example-plugin" download success)
    assert File.exist?(File.join(@dir, "plugins", "tmux-example-plugin", ".git"))
    assert_includes File.read(File.join(@dir, "tempo.lock")), "tmux-example-plugin"
  end

  # The declaration is the user's intent and lands either way; only the clone
  # is gated (D23/D27). A refused source still tells the user how to proceed.
  def test_add_installs_through_the_trust_gate
    write_conf("")
    env = env_for

    code, _, err = add(repo, env: env, trust: Tempo::Trust.new(env, tty: false))

    assert_equal 1, code
    assert_includes File.read(conf), "set -g @plugin '#{repo}'"
    assert_includes err, "skipped: source not trusted"
    assert_includes err, "tempo trust"
    refute File.exist?(File.join(@dir, "plugins", "tmux-example-plugin"))
  end

  # --- remove: the three quote forms -------------------------------------

  def test_remove_deletes_each_quote_form_and_leaves_everything_else_alone
    ["'owner/repo'", '"owner/repo"', "owner/repo"].each do |quoted|
      write_conf(<<~CONF)
        # keep me: owner/repo is mentioned here
        set -g status on
        set-option -g @plugin #{quoted}
        set -g @plugin 'other/thing'
      CONF

      code, out, = remove("repo")

      assert_equal 0, code, "#{quoted}: expected a clean removal"
      assert_equal <<~CONF, File.read(conf)
        # keep me: owner/repo is mentioned here
        set -g status on
        set -g @plugin 'other/thing'
      CONF
      assert_includes out, "#{conf}:3"
      assert_includes out, "tempo clean"
      assert_equal 1, backups.size
      FileUtils.rm_f(backups)
    end
  end

  def test_remove_accepts_the_verbatim_spec_too
    write_conf("set -g @plugin 'owner/repo'\n")

    assert_equal 0, remove("owner/repo").first
    assert_equal "", File.read(conf)
  end

  def test_remove_without_a_name_is_a_usage_error
    write_conf("")
    code, _, err = remove

    assert_equal 1, code
    assert_includes err, "usage: tempo remove"
  end

  # --- remove: the refusal quartet ---------------------------------------

  def test_remove_refuses_a_declaration_inside_a_conditional
    write_conf(<<~CONF)
      %if 1
      set -g @plugin 'owner/repo'
      %endif
    CONF
    before = File.read(conf)

    code, _, err = remove("repo")

    assert_equal 1, code
    assert_equal before, File.read(conf)
    assert_includes err, "#{conf}:2"
    assert_includes err, "%if"
    assert_includes err, "remove it by hand"
    assert_empty backups
  end

  def test_remove_refuses_legacy_tpm_plugins_membership
    write_conf(%(set -g @tpm_plugins "tmux-foo tmux-bar"\n))
    before = File.read(conf)

    code, _, err = remove("tmux-foo")

    assert_equal 1, code
    assert_equal before, File.read(conf)
    assert_includes err, "#{conf}:1"
    assert_includes err, "@tpm_plugins"
    assert_includes err, "remove it by hand"
  end

  def test_remove_refuses_a_declaration_in_a_sourced_file
    included = File.join(@dir, "plugins.conf")
    File.write(included, "\nset -g @plugin 'owner/repo'\n")
    write_conf("source-file #{included}\n")
    before = File.read(conf)

    code, _, err = remove("repo")

    assert_equal 1, code
    assert_equal before, File.read(conf)
    assert_equal "\nset -g @plugin 'owner/repo'\n", File.read(included)
    assert_includes err, "#{included}:2"
    assert_includes err, "remove it by hand"
  end

  def test_remove_refuses_a_declaration_in_another_candidate_config_file
    other = File.join(@dir, "system-tmux.conf")
    File.write(other, "set -g @plugin 'owner/repo'\n")
    write_conf("set -g status on\n")
    before = File.read(conf)

    code, _, err = remove("repo", env: env_for(candidates: [other, conf]))

    assert_equal 1, code
    assert_equal before, File.read(conf)
    assert_includes err, "#{other}:1"
    assert_includes err, "remove it by hand"
  end

  def test_remove_refuses_a_plugin_that_is_not_declared_anywhere
    write_conf("set -g @plugin 'other/thing'\n")
    before = File.read(conf)

    code, _, err = remove("nope")

    assert_equal 1, code
    assert_equal before, File.read(conf)
    assert_includes err, %(no @plugin declaration for "nope")
    assert_empty backups
  end

  # The scraper counts field 4 of anything matching its (deliberately loose)
  # detector, so a line tempo cannot fully parse still declares a plugin —
  # which makes silently ignoring it the one unacceptable answer.
  def test_remove_refuses_a_line_it_cannot_fully_parse
    write_conf("set -g @plugin 'owner/repo' ; set -g status on\n")
    before = File.read(conf)

    code, _, err = remove("repo")

    assert_equal 1, code
    assert_equal before, File.read(conf)
    assert_includes err, "#{conf}:1"
    assert_includes err, "remove it by hand"
  end

  def test_remove_refuses_the_whole_edit_when_only_one_match_is_unsafe
    write_conf(<<~CONF)
      set -g @plugin 'owner/repo'
      %if 1
      set -g @plugin 'owner/repo'
      %endif
    CONF
    before = File.read(conf)

    code, _, err = remove("repo")

    assert_equal 1, code
    assert_equal before, File.read(conf), "a partial edit is worse than none"
    assert_includes err, "#{conf}:3"
  end

  def test_remove_never_deletes_plugin_files
    write_conf("")
    add(repo)
    installed = File.join(@dir, "plugins", "tmux-example-plugin")
    assert File.exist?(installed)

    code, out, = remove("tmux-example-plugin")

    assert_equal 0, code
    assert File.exist?(installed), "remove edits the config, never the plugin files"
    assert_includes out, "tempo clean"
  end

  # --- the interactive pick, through a real terminal ----------------------

  # search -> numbered pick -> add -> trust prompt -> installed, driven over a
  # pty against the real binary: every one of those steps is TTY-gated, so no
  # in-process assertion can reach them. Never `script(1)` (NOTES.md).
  def test_interactive_search_pick_installs_the_chosen_plugin
    index = File.join(@dir, "index.json")
    File.write(index, JSON.generate({ "version" => 1, "plugins" => [
                                      { "name" => "tmux-example-plugin", "repo" => repo,
                                        "description" => "a local fixture", "tags" => ["test"] },
                                    ] }))
    File.write(File.join(pty_home, ".tmux.conf"), "set -g status on\n")

    buf, status = pty_search(index, "example") do |r, w, seen|
      seen.call(r, "Enter to skip")
      w.write("1\n")
      seen.call(r, "[y/N]")
      w.write("y\n")
    end

    assert_equal 0, status
    assert_includes buf, "1. tmux-example-plugin"
    assert_includes buf, %("tmux-example-plugin" download success)
    assert_includes File.read(File.join(pty_home, ".tmux.conf")),
                    "set -g @plugin '#{repo}'"
    assert File.directory?(File.join(pty_home, ".tmux", "plugins", "tmux-example-plugin"))
  end

  # Enter is the safe answer: nothing is written, nothing is installed, and
  # the exit code still says "found it".
  def test_interactive_pick_skipped_by_enter_writes_nothing
    repo = make_plugin_repo(@fixtures, "tmux-other-plugin")
    index = File.join(@dir, "index.json")
    File.write(index, JSON.generate({ "version" => 1, "plugins" => [
                                      { "name" => "tmux-other-plugin", "repo" => repo,
                                        "description" => "a local fixture", "tags" => [] },
                                    ] }))
    File.write(File.join(pty_home, ".tmux.conf"), "set -g status on\n")

    buf, status = pty_search(index, "other") do |r, w, seen|
      seen.call(r, "Enter to skip")
      w.write("\n")
    end

    assert_equal 0, status
    refute_includes buf, "download success"
    assert_equal "set -g status on\n", File.read(File.join(pty_home, ".tmux.conf"))
    refute File.exist?(File.join(pty_home, ".tmux", "plugins", "tmux-other-plugin"))
  end

  private

  def pty_home
    @pty_home ||= begin
      home = File.join(@dir, "pty-home")
      FileUtils.mkdir_p(File.join(home, "sock"))
      home
    end
  end

  # TMUX_TMPDIR is a sandbox path and TMUX is cleared, so the server the Env
  # queries start can never be the developer's own.
  def pty_search(index, query)
    bin = File.expand_path("../bin/tempo", __dir__)
    env = { "HOME" => pty_home, "XDG_DATA_HOME" => File.join(pty_home, "data"),
            "XDG_CONFIG_HOME" => nil, "TEMPO_INDEX_URL" => "file://#{index}",
            "TMUX_TMPDIR" => File.join(pty_home, "sock"), "TMUX" => nil, "TMUX_PANE" => nil }
    buf = +""
    status = nil
    seen = ->(reader, needle) { buf << reader.readpartial(4096) until buf.include?(needle) }
    Timeout.timeout(60) do
      PTY.spawn(env, bin, "search", query) do |r, w, pid|
        yield(r, w, seen)
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
    # Explicit socket path, never $TMUX or the ambient TMUX_TMPDIR.
    system("tmux", "-S", File.join(pty_home, "sock", "tmux-#{Process.uid}", "default"),
           "kill-server", out: File::NULL, err: File::NULL)
  end
end
