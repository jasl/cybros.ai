# Reuse the protocol fixture; only the cancellation cleanup is held at a
# file gate so the caller can return before the old prompt's final update.
require_relative "../../../../../e2e/support/acp_fixture/agent"

class DeferredCancelAgent < E2E::AcpFixture::Agent
  private

    def plain_turn(turn, text)
      return super unless text.start_with?("defer:")

      gate = text.delete_prefix("defer:")
      say(turn, "old-head")
      sleep POLL_SECONDS until File.exist?(gate)
      "old-tail"
    end
end

exit DeferredCancelAgent.new(mode: "plain", protocol_version: 1).run
