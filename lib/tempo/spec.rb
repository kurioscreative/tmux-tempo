# frozen_string_literal: true

module Tempo
  # A plugin declaration: "user/repo", a full git URL, or a local path,
  # optionally suffixed "#branch". Directory naming must match the original
  # tpm exactly (INTERFACE.md §1.2): #branch is stripped first, then the
  # name is the spec's basename minus one trailing ".git". This derivation
  # decides whether existing installations are recognized at all.
  class Spec
    attr_reader :raw, :url, :branch

    # Mirrors the original's `IFS='#' read -ra`: field 0 is the url, field 1
    # the branch; anything past a second '#' is discarded.
    def self.parse(raw)
      parts = raw.split("#")
      new(raw: raw, url: parts[0].to_s, branch: parts[1])
    end

    def initialize(raw:, url:, branch: nil)
      @raw = raw
      @url = url
      @branch = branch
    end

    def name
      File.basename(url).sub(/\.git\z/, "")
    end

    # GitHub-only shorthand expansion; the empty `git::@` credential keeps
    # git from ever prompting (paired with GIT_TERMINAL_PROMPT=0).
    def github_shorthand_url
      "https://git::@github.com/#{url}"
    end

    def ==(other)
      other.is_a?(Spec) && raw == other.raw
    end
  end
end
