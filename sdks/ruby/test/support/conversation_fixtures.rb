require_relative "contract_fixtures"

module CybrosAgentTest
  # A Workspace's nested Conversation surface: the multi-turn plane.
  #
  # The fixtures come from the Nexus-owned contract pack rather than from
  # hand-written literals here, so a wire change that Nexus regenerates fails
  # in this suite instead of in production. What these tests add on top of
  # the pack is the SDK's own contract: which shapes are parsed strictly,
  # which are read by presence, and what a caller may conclude from each.
  module ConversationFixtures
    WORKSPACE_ID = "019f0000-0000-7000-8000-000000000101".freeze
    CONVERSATION_ID = "01900000-0000-7000-8000-000000000070".freeze
    TURN_ID = "01900000-0000-7000-8000-000000000071".freeze
    VARIANT_ID = "01900000-0000-7000-8000-000000000091".freeze
    BASE = "/agent_api/v1/workspaces/#{WORKSPACE_ID}/conversations".freeze
    PATH = "#{BASE}/#{CONVERSATION_ID}".freeze

    def contract = CybrosAgentTest::ContractFixtures.pack("conversations.json")

    def workspace(script)
      @transport = CybrosAgentTest::FakeTransport.new(script)
      CybrosAgent::Client.new(
        base_url: "http://example.test", credential: "sk-member", transport: @transport
      ).workspace(WORKSPACE_ID)
    end

    def conversations(script) = workspace(script).conversations
    def chat(script) = workspace(script).conversation(CONVERSATION_ID)
    def request(index = 0) = @transport.requests.fetch(index)
  end
end
