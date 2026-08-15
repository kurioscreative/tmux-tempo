# frozen_string_literal: true

require "digest"
require "fileutils"

module Tempo
  # The content-addressed plugin store (D24). Every plugin is filed once per
  # `(url, commit)` under `<data_dir>/store/<url-digest>/<commit>/`, and the
  # flat `TMUX_PLUGIN_MANAGER_PATH` layout becomes symlinks into it. Two
  # configs — or two plugin names — that want the same commit share one clone,
  # and update/restore stop being in-place mutations: they become link flips.
  #
  # One invariant carries the whole design: **tempo never runs a mutating git
  # command inside a filed entry.** Update and restore clone the current entry
  # into a staging working copy, mutate *that*, file the result as a new entry
  # and flip the link. An entry's git state therefore always matches the key it
  # is filed under, which is what makes a flip a safe substitute for a checkout.
  #
  # Entries stay writable (see DECISIONS.md D24): plugins that cache inside
  # their own directory must keep working, so immutability is a tempo-side rule
  # about git state, not a filesystem permission.
  module Store
    module_function

    def root(env)
      File.join(env.data_dir, "store")
    end

    # SHA-256 of the clone URL in full hex: filesystem-safe on every platform,
    # fixed-length, and collision-free for any input we will ever see. It is
    # deliberately one-way — the URL is recovered from the entry's own `origin`
    # remote, never by inverting the digest.
    def key(url)
      Digest::SHA256.hexdigest(url.to_s)
    end

    def entry_path(env, url, commit)
      File.join(root(env), key(url), commit)
    end

    def entry?(env, url, commit)
      !url.to_s.empty? && !commit.to_s.empty? && File.directory?(entry_path(env, url, commit))
    end

    # --- the three mutating flows ----------------------------------------

    # Clone into staging, then file by the commit the clone actually landed
    # on — the commit is unknowable before the clone, which is why nothing can
    # be written straight to its final path. Returns false exactly when the
    # clone failed, so install's "download fail" branch is unchanged.
    def install(env, spec)
      staging = staging_path(env)
      return false unless Git.clone_plugin(spec, staging)

      file_and_link(env, spec.name, staging)
    ensure
      FileUtils.rm_rf(staging) if staging
    end

    # The pull happens in a throwaway local clone of the current entry (git
    # hardlinks the object store, so this is nearly free) and its real output
    # is what the `    | `-indented report shows. A pull that lands on a commit
    # already filed re-uses that entry and files nothing — it still reports
    # honestly, because the report is the pull's own words.
    def update(env, name)
      dir = env.plugin_dir(name)
      return Git.pull(dir) unless File.symlink?(dir) # hybrid: a plain dir updates in place

      entry = File.realpath(dir)
      staging = staging_path(env)
      return ["fatal: could not stage a working copy of #{name}\n", false] unless
        Git.clone_working_copy(entry, Git.remote_url(entry), staging)

      out, ok = Git.pull(staging)
      ok &&= file_and_link(env, name, staging)
      [out, ok]
    ensure
      FileUtils.rm_rf(staging) if staging
    end

    # Restore = flip to the entry for the locked `(url, commit)`, building that
    # entry from the current one's objects when it has never been filed. The
    # checkout happens in staging; `frozen` drops the fetch arm exactly like the
    # in-place path it replaces.
    def place(env, name, url, commit, frozen: false)
      dir = env.plugin_dir(name)
      return checkout_in_place(dir, commit, frozen: frozen) unless File.symlink?(dir)

      entry = entry_path(env, url, commit)
      return link!(env, name, entry) if File.directory?(entry)

      staging = staging_path(env)
      return false unless Git.clone_working_copy(File.realpath(dir), url, staging)

      ok = Git.checkout(staging, commit)
      ok ||= Git.fetch(staging) && Git.checkout(staging, commit) unless frozen
      ok && file_and_link(env, name, staging)
    ensure
      FileUtils.rm_rf(staging) if staging
    end

    # --- lazy migration ---------------------------------------------------

    # A real directory left by tpm, an older tempo, or a hand-run `git clone`
    # is adopted into the store on the first mutating op — but only when it is
    # provably a faithful checkout of its origin: clean work tree (untracked
    # files included, because adoption *shares* whatever it moves) and a HEAD
    # some remote branch contains. Anything else keeps its real directory and
    # says so once. The hybrid layout is supported indefinitely, not a
    # migration deadline, so this never fails an operation.
    def adopt(env, ui)
      each_declared(env) do |name|
        dir = env.plugin_dir(name)
        next if File.symlink?(dir) || !File.directory?(dir) || !Git.repo?(dir)

        if !Git.clean_worktree?(dir)
          ui.warn(%(  "#{name}" kept as a plain directory: uncommitted changes))
        elsif !Git.head_on_remote_branch?(dir)
          ui.warn(%(  "#{name}" kept as a plain directory: HEAD is on no remote branch))
        else
          adopt_dir(env, name, dir)
        end
      end
    end

    # Frozen's offline question, store-aware: the locked commit counts as
    # available when its entry is already filed *or* when the current entry
    # carries the object (so a checkout in staging needs no network).
    def commit_available?(env, name, url, commit)
      entry?(env, url, commit) || Git.commit_present?(env.plugin_dir(name), commit)
    end

    # --- internals --------------------------------------------------------

    def each_declared(env)
      seen = {}
      env.specs.each do |spec|
        next if seen[spec.name]

        seen[spec.name] = true
        yield spec.name
      end
    end

    # Move the clean directory in as its own entry when that key is unfiled,
    # otherwise drop it in favour of the entry already there — the two are
    # interchangeable by construction.
    def adopt_dir(env, name, dir)
      url = Git.remote_url(dir)
      commit = Git.head_commit(dir)
      return unless url && commit

      entry = entry_path(env, url, commit)
      if File.directory?(entry)
        FileUtils.rm_rf(dir)
      else
        FileUtils.mkdir_p(File.dirname(entry))
        FileUtils.mv(dir, entry) # may cross filesystems: plugin path vs data dir
      end
      link!(env, name, entry)
    end

    # The clone-then-file dance. Staging lives under the store root so this
    # rename is same-filesystem and therefore atomic; losing the race to
    # another process just means keeping its entry and dropping ours.
    def file_and_link(env, name, staging)
      url = Git.remote_url(staging)
      commit = Git.head_commit(staging)
      return false unless url && commit

      entry = entry_path(env, url, commit)
      unless File.directory?(entry)
        FileUtils.mkdir_p(File.dirname(entry))
        begin
          File.rename(staging, entry)
        rescue SystemCallError
          return false unless File.directory?(entry)
        end
      end
      link!(env, name, entry)
    end

    # Symlink at a temp name, then rename over the old link: never
    # unlink-then-link, which would leave a window in which a tmux server
    # starting up finds no plugin directory at all. The temp name is dotted so
    # clean's `*` glob can never see it.
    def link!(env, name, target)
      dir = env.plugin_dir(name)
      tmp = File.join(env.plugin_path, ".#{name}.link.#{Process.pid}")
      FileUtils.rm_rf(tmp)
      File.symlink(target, tmp)
      File.rename(tmp, dir)
      true
    rescue SystemCallError
      FileUtils.rm_rf(tmp)
      false
    end

    def staging_path(env)
      dir = File.join(root(env), ".staging")
      FileUtils.mkdir_p(dir)
      File.join(dir, "#{Process.pid}-#{rand(1 << 32).to_s(16)}")
    end

    # The pre-store restore, kept for plugin directories that were never
    # adopted — the hybrid layout has to keep working, not just keep existing.
    def checkout_in_place(dir, commit, frozen:)
      ok = Git.checkout(dir, commit)
      ok ||= Git.fetch(dir) && Git.checkout(dir, commit) unless frozen
      ok
    end
  end
end
