# Homebrew formula for agent-bus. Lives in the scottbaggett/homebrew-tap repo
# as Formula/agent-bus.rb; this copy is the source. At each release, set `url`
# to the new tag and `sha256` to:
#   curl -fsSL https://github.com/scottbaggett/agent-bus/archive/refs/tags/<tag>.tar.gz | shasum -a 256
class AgentBus < Formula
  desc "File-backed handoff bus for coding agents sharing repos and worktrees"
  homepage "https://github.com/scottbaggett/agent-bus"
  url "https://github.com/scottbaggett/agent-bus/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  depends_on "jq"

  def install
    libexec.install Dir["*"]
    (libexec/".installed-version").write "v#{version}\n"
    bin.install_symlink libexec/"bin/agent-bus"
  end

  def caveats
    <<~EOS
      Wire agent-bus into the agents on this machine (Claude Code, OpenCode, Codex):
        agent-bus hooks
      Then, in each repo, set the team's rules:
        agent-bus init
      Hooks point at #{opt_libexec}, so `brew upgrade` needs no re-run,
      except for OpenCode's plugin copy: run `agent-bus hooks --opencode` after upgrading.
    EOS
  end

  test do
    assert_match "agent-bus", shell_output("#{bin}/agent-bus version")
  end
end
