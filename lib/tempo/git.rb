# frozen_string_literal: true

require "open3"
require "fileutils"

module Tempo
  # All git operations. GIT_TERMINAL_PROMPT=0 plus the empty `git::@`
  # credential in the GitHub expansion guarantee no operation ever blocks
  # on a credential prompt — a hang here wedges tmux's run-shell.
  module Git
    NO_PROMPT = { "GIT_TERMINAL_PROMPT" => "0" }.freeze

    # git cannot run at all (D35). Without this gate a broken git made every
    # clone report `download fail` — naming the network, not the cause — and
    # every `installed?` answer false. Raised before a verb touches disk.
    class Unavailable < StandardError; end

    module_function

    def preflight!
      out, status = Open3.capture2e("git", "--version")
      return if status.success?

      raise Unavailable, "git is not usable: #{out.lines.first.to_s.strip}"
    rescue Errno::ENOENT
      raise Unavailable, "git is not in PATH"
    end

    # Verbatim URL first; GitHub shorthand expansion only on failure. Both
    # attempts target the same path — a failed clone must leave nothing behind
    # for the next one to trip over.
    def clone_plugin(spec, dest)
      clone(spec.url, spec.branch, dest) ||
        clone(spec.github_shorthand_url, spec.branch, dest)
    end

    # Full-history clone, like the original (no --depth), into an explicit
    # destination: under the store the directory name is a content key, not
    # git's guess from the URL.
    def clone(url, branch, dest)
      FileUtils.rm_rf(dest)
      args = ["git", "clone", "--single-branch"]
      args += ["-b", branch] if branch && !branch.empty?
      args += ["--recursive", url, dest]
      system(NO_PROMPT, *args, out: File::NULL, err: File::NULL)
    end

    # A disposable working copy of a store entry. Cloning a local path makes
    # git hardlink the object database, so this costs almost nothing; pointing
    # origin back at the real upstream is what makes a later `git pull` behave
    # exactly as the old in-place pull did.
    def clone_working_copy(src, url, dest)
      FileUtils.rm_rf(dest)
      return false unless system(NO_PROMPT, "git", "clone", "--recursive", src, dest,
                                 out: File::NULL, err: File::NULL)
      return true if url.nil? || url.empty?

      system(NO_PROMPT, "git", "-C", dest, "remote", "set-url", "origin", url,
             out: File::NULL, err: File::NULL)
    end

    # `git pull` + submodule init; combined output feeds the `    | `
    # indented update report. Returns [output, success].
    def pull(dir)
      out, status = Open3.capture2e(NO_PROMPT, "git", "pull", chdir: dir)
      return [out, false] unless status.success?

      sub_out, sub_status = Open3.capture2e(
        NO_PROMPT, "git", "submodule", "update", "--init", "--recursive", chdir: dir
      )
      [out + sub_out, sub_status.success?]
    end

    def head_commit(dir)
      capture(dir, "rev-parse", "HEAD")
    end

    def remote_url(dir)
      capture(dir, "remote", "get-url", "origin")
    end

    def checkout(dir, ref)
      system(NO_PROMPT, "git", "-C", dir, "checkout", "-q", ref,
             out: File::NULL, err: File::NULL)
    end

    # Read-only presence probe for the frozen preflight: is this commit
    # object already in the local clone? `git checkout` answers the same
    # question but mutates, and preflight must leave the tree untouched.
    def commit_present?(dir, commit)
      system(NO_PROMPT, "git", "-C", dir, "cat-file", "-e", "#{commit}^{commit}",
             out: File::NULL, err: File::NULL)
    end

    def repo?(dir)
      system(NO_PROMPT, "git", "-C", dir, "rev-parse", "--git-dir",
             out: File::NULL, err: File::NULL)
    end

    # Untracked files count as dirty on purpose: adoption *moves* the tree into
    # a store entry other configs may share, so anything not reproducible from
    # the remote is a reason to leave the directory alone.
    def clean_worktree?(dir)
      out, status = Open3.capture2(NO_PROMPT, "git", "-C", dir, "status", "--porcelain",
                                   err: File::NULL)
      status.success? && out.strip.empty?
    end

    # Is HEAD contained in some remote-tracking branch? Purely local — it reads
    # refs/remotes, never the network. False for a locally-committed HEAD, which
    # is exactly the tree adoption must not swallow.
    def head_on_remote_branch?(dir)
      !capture(dir, "branch", "-r", "--contains", "HEAD").nil?
    end

    def fetch(dir)
      system(NO_PROMPT, "git", "-C", dir, "fetch", "--quiet",
             out: File::NULL, err: File::NULL)
    end

    def capture(dir, *args)
      out, status = Open3.capture2("git", "-C", dir, *args, err: File::NULL)
      status.success? && !out.strip.empty? ? out.strip : nil
    end
  end
end
