# frozen_string_literal: true

require "helper"

# Directory-name derivation is the riskiest single line of the rewrite
# (INTERFACE.md §4). Expected values below reproduce the original's
# `plugin_name_helper` output (basename, minus one trailing ".git", branch
# stripped first via IFS='#').
class TestSpec < Minitest::Test
  CASES = {
    "tmux-plugins/tmux-copycat" => ["tmux-copycat", nil],
    "tmux-plugins/tmux-copycat#dev" => ["tmux-copycat", "dev"],
    "https://github.com/user/repo.git" => ["repo", nil],
    "https://git::@github.com/user/repo.git" => ["repo", nil],
    "git@github.com:user/repo.git" => ["repo", nil],
    "git://github.com/user/plugin_name.git" => ["plugin_name", nil],
    "/local/path/tmux-foo" => ["tmux-foo", nil],
    "/local/path/tmux-foo/" => ["tmux-foo", nil],
    "user/repo.git#v2.1" => ["repo", "v2.1"],
    "repo.git.git" => ["repo.git", nil], # exactly one trailing .git stripped
    "name#branch#junk" => ["name", "branch"], # IFS='#' keeps fields 0 and 1
    "ssh://host/path/plug" => ["plug", nil],
  }.freeze

  def test_name_and_branch_derivation
    CASES.each do |raw, (name, branch)|
      spec = Tempo::Spec.parse(raw)
      assert_equal name, spec.name, "name for #{raw.inspect}"
      if branch.nil?
        assert_nil spec.branch, "branch for #{raw.inspect}"
      else
        assert_equal branch, spec.branch, "branch for #{raw.inspect}"
      end
    end
  end

  def test_github_shorthand_expansion
    spec = Tempo::Spec.parse("user/repo")
    assert_equal "https://git::@github.com/user/repo", spec.github_shorthand_url
  end
end
