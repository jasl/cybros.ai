require "test_helper"
require "test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationRegenerationToolsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @agent = users(:agent)
    @conversation = Conversation.create!(workspace: @workspace,
      creating_user: @human, answering_user: @agent)
    result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation, path: "workspace/skills/review", by: @human), conversation: @conversation,
      path: "workspace/skills/review", content: "Read the changed files.",
      description: "Review a change.", by: @human)
    assert_predicate result, :accepted?, result.outcome.inspect
  end

  test "regeneration assembles the skill catalog from the original narrowed tools" do
    declare_tools!(@agent, tools: [READ_TOOL, Nexus::Tools::SKILL])
    turn = settled_reply(tool_names: ["read_file"])

    request = regenerate_request(turn)

    assert_equal ["read_file"], tool_names(request)
    assert_not_includes request_text(request), Nexus::Skills::CATALOG_HEADER
  end

  test "regeneration retains the original skill surface after the profile changes" do
    declare_tools!(@agent, tools: [Nexus::Tools::SKILL])
    turn = settled_reply
    declare_tools!(@agent, tools: [READ_TOOL])

    request = regenerate_request(turn)

    assert_equal ["skill"], tool_names(request)
    assert_includes request_text(request), Nexus::Skills::CATALOG_HEADER
    assert_includes request_text(request), "review: Review a change."
  end

  test "regenerating an edited candidate does not acquire the profile skill surface" do
    declare_tools!(@agent, tools: [Nexus::Tools::SKILL])
    turn = settled_reply
    post "#{conversation_turns_path(@conversation)}/#{turn.public_id}/edit",
      headers: auth, as: :json, params: { edit: { text: "A revised answer." } }
    assert_response :success

    request = regenerate_request(turn)

    assert_empty tool_names(request)
    assert_not_includes request_text(request), Nexus::Skills::CATALOG_HEADER
  end

  private

    def settled_reply(**options)
      post conversation_inputs_path(@conversation), headers: auth(SecureRandom.uuid), as: :json,
        params: { input: { kind: "direct_reply", text: "Please review.",
                           model: { model: "dev/mock-text" }, **options } }
      assert_response :accepted
      perform_enqueued_jobs only: Conversations::Inputs::DrainJob
      turn = @conversation.conversation_turns.sole
      agent_run = turn.active_variant.agent_run
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, sse_success("Reviewed."))
      Conversations::Turns::Converge.call(agent_run_id: agent_run.id, conversation_id: @conversation.id)
      assert_equal "completed", turn.reload.status
      turn
    end

    def regenerate_request(turn)
      # A different model forces reassembly instead of copying the sealed seed.
      post "#{conversation_turns_path(@conversation)}/#{turn.public_id}/regeneration",
        headers: auth(SecureRandom.uuid), as: :json,
        params: { regeneration: { model: { model: "dev/mock-text-only" } } }
      assert_response :accepted
      variant = turn.conversation_turn_variants.find_by!(public_id: response.parsed_body.dig("variant", "public_id"))
      schedule_loop!(variant.agent_run) if variant.agent_run
      get request_path(@conversation, turn, variant), headers: auth
      assert_response :success
      response.parsed_body.fetch("request")
    end

    def tool_names(request)
      request.fetch("request_options").fetch("tools", []).map { |tool| tool.dig("function", "name") }
    end

    def request_text(request)
      request.fetch("entries").flat_map { |entry| entry.fetch("parts", []).map { |part| part["text"] } }.join("\n")
    end
end
