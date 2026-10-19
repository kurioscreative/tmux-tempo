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

      why = out.lines.first.to_s.strip
      why = "`git --version` exited #{status.exitstatus} with no output" if why.empty?
      raise Unavailable, "git is not usable: #{why}"
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
    # destination: the plugin name derived from the spec, not git's guess
    # from the URL.
    def clone(url, branch, dest)
      FileUtils.rm_rf(dest)
      args = ["git", "clone", "--single-branch"]
      args += ["-b", branch] if branch && !branch.empty?
      args += ["--recursive", url, dest]
      system(NO_PROMPT, *args, out: File::NULL, err: File::NULL)
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

    # Moves the work tree to `ref` without detaching HEAD (D36): when HEAD is
    # on a branch, that branch is moved to `ref`, so the next `git pull`
    # fast-forwards instead of failing with "not currently on a branch".
    # `checkout -B`, not `reset --hard`: like a plain checkout it refuses
    # rather than discard a conflicting local edit.
    def checkout(dir, ref)
      branch = capture(dir, "symbolic-ref", "-q", "--short", "HEAD")
      target = branch ? ["-B", branch, ref] : [ref]
      system(NO_PROMPT, "git", "-C", dir, "checkout", "-q", *target,
             out: File::NULL, err: File::NULL)
    end

    # Read-only presence probe for the frozen preflight: is this commit
    # object already in the local clone? `git checkout` answers the same
    # question but mutates, and preflight must leave the tree untouched.
    def commit_present?(dir, commit)
      system(NO_PROMPT, "git", "-C", dir, "cat-file", "-e", "#{commit}^{commit}",
             out: File::NULL, err: File::NULL)
    end

    # Is this file in some repository's index? False both outside any work
    # tree and for a file never added — to doctor those are the same gap.
    def tracked?(path)
      system(NO_PROMPT, "git", "-C", File.dirname(path), "ls-files", "--error-unmatch", "--",
             File.basename(path), out: File::NULL, err: File::NULL)
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
