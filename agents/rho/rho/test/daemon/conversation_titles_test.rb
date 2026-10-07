require "support/daemon_run_helpers"

class ConversationTitlesTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  def test_title_is_forwarded_with_and_without_the_first_prompt
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)

    [{ "title" => "An empty conversation" },
     { "title" => "A first prompt", "prompt" => "hello", "model" => "dev/mock-text" }].each do |body|
      code, answer = open(daemon, body)
      assert_equal "201", code, answer.inspect
      assert_equal body.fetch("title"), api.conversation_creates.last.dig("conversation", "title")
    end
    assert_equal 1, api.conversation_inputs.length
  end
end
