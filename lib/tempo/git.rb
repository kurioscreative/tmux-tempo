# frozen_string_literal: true

require "open3"

module Tempo
  # All git operations. GIT_TERMINAL_PROMPT=0 plus the empty `git::@`
  # credential in the GitHub expansion guarantee no operation ever blocks
  # on a credential prompt — a hang here wedges tmux's run-shell.
  module Git
    NO_PROMPT = { "GIT_TERMINAL_PROMPT" => "0" }.freeze

    module_function

    # Verbatim URL first; GitHub shorthand expansion only on failure.
    def clone_plugin(spec, into)
      clone(spec.url, spec.branch, into) ||
        clone(spec.github_shorthand_url, spec.branch, into)
    end

    # Full-history clone, like the original (no --depth).
    def clone(url, branch, into)
      args = ["git", "clone", "--single-branch"]
      args += ["-b", branch] if branch && !branch.empty?
      args += ["--recursive", url]
      system(NO_PROMPT, *args, chdir: into, out: File::NULL, err: File::NULL)
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
