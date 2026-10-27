require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationLinksTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @sender = @human.build_agent(display_name: "Link sender")
    @sender.save!
    @recipient = create_agent_member(display_name: "Link recipient", agent_identifier: "link-recipient")
    [@sender, @recipient].each { declare_tools!(_1, tools: [Nexus::Tools::SEND, Nexus::Tools::REQUEST], default_model: "dev/mock-text") }
    @source = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @sender)
    @target = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @recipient)
    @fields = { agent_public_id: @sender.public_id, peer_conversation_public_id: @target.public_id,
      peer_agent_public_id: @recipient.public_id }
  end

  test "public create replay close and recreation preserve irreversible link identity" do
    post links_path, params: { link: @fields }, headers: auth("link-one"), as: :json
    assert_response :created
    original = response.parsed_body.fetch("link")
    assert_equal @target.public_id, original.dig("peer", "conversation_public_id")
    post links_path, params: { link: @fields }, headers: auth("link-two"), as: :json
    assert_response :ok
    assert_equal original.fetch("public_id"), response.parsed_body.dig("link", "public_id")
    post "#{links_path}/#{original.fetch("public_id")}/closure", headers: auth, as: :json
    assert_response :ok
    assert_equal "closed", response.parsed_body.dig("link", "state")
    post links_path, params: { link: @fields }, headers: auth("link-one"), as: :json
    assert_response :created
    assert_equal "true", response.headers["Idempotency-Replayed"]
    get "#{links_path}/#{original.fetch("public_id")}", headers: auth
    assert_response :ok
    assert_equal "closed", response.parsed_body.dig("link", "state")
    post links_path, params: { link: @fields }, headers: auth("link-three"), as: :json
    assert_response :created
    refute_equal original.fetch("public_id"), response.parsed_body.dig("link", "public_id")
    get links_path, headers: auth
    assert_response :ok
    assert_equal 1, response.parsed_body.fetch("links").length
  end

  test "link events attribute creation and explicit closure once on both endpoints" do
    post links_path, params: { link: @fields }, headers: auth("audit-create"), as: :json
    assert_response :created
    link_id = response.parsed_body.dig("link", "public_id")
    post links_path, params: { link: @fields }, headers: auth("audit-pair"), as: :json
    assert_response :ok
    post links_path, params: { link: @fields }, headers: auth("audit-create"), as: :json
    assert_response :created
    2.times do
      post "#{links_path}/#{link_id}/closure", headers: auth, as: :json
      assert_response :ok
    end
    [@source, @target].each do |conversation|
      events = conversation.event_items.where(item_type: "conversation_link_changed").order(:sequence).map(&:payload)
      assert_equal %w[active closed], events.map { |event| event.fetch("state") }
      events.each do |event|
        assert_equal link_id, event.fetch("link_public_id")
        assert_equal @human.public_id, event.fetch("by")
        assert_equal "human", event.fetch("kind")
      end
    end
  end

  test "shared link contract cases are produced by public commands" do
    cases = Nexus::Contract.pack.fetch("communication.json").fetch("cases").index_by { |row| row.fetch("name") }
    post links_path, params: { link: @fields }, headers: auth("shared-link"), as: :json
    assert_link_contract(cases.fetch("link_accepted"))
    link_id = response.parsed_body.dig("link", "public_id")
    post links_path, params: { link: @fields }, headers: auth("shared-link"), as: :json
    assert_link_contract(cases.fetch("link_replayed"))
    assert_equal "true", response.headers["Idempotency-Replayed"]
    post links_path, params: { link: @fields }, headers: auth("shared-pair"), as: :json
    assert_link_contract(cases.fetch("link_active_pair"))
    post links_path, params: { link: @fields.merge(peer_agent_public_id: @sender.public_id) }, headers: auth("shared-link"), as: :json
    assert_response cases.fetch("link_mismatch").fetch("status")
    assert_equal cases.dig("link_mismatch", "body", "error", "code"), response.parsed_body.dig("error", "code")
    get "#{links_path}/#{link_id}", headers: auth
    assert_link_contract(cases.fetch("link_read"))
    get links_path, headers: auth
    assert_equal cases.dig("link_list", "body").keys.sort, response.parsed_body.keys.sort
    assert_equal link_id, response.parsed_body.fetch("links").sole.fetch("public_id")
    post "#{links_path}/#{link_id}/closure", headers: auth, as: :json
    assert_link_contract(cases.fetch("link_closed"))
  end

  test "a link permits a real message without granting peer history access" do
    post links_path, params: { link: @fields }, headers: auth("link"), as: :json
    assert_response :created
    link_id = response.parsed_body.dig("link", "public_id")
    @target.update!(access_default: "none")
    @token = AccessTokens::IssueAPIKey.call(user: @sender, name: "Sender")
    assert_equal :issued, @token.outcome
    get conversation_path(@target), headers: auth
    assert_response :not_found
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "send", link_public_id: link_id, message: "Message through the granted link")
    get task_path(source, call), headers: auth
    assert_response :ok
    receipt = response.parsed_body.dig("task", "structured_content")
    assert_equal link_id, receipt.fetch("link_public_id")
    input_id = receipt.fetch("input_public_id")
    clear_enqueued_jobs
    # Lose every enqueue and retry the completed job: the task's own result
    # survives beyond the hosted receipt's transport retention.
    travel 25.hours do
      Runs::ConversationToolJob.perform_now(call.id)
      assert_equal 1, @target.inputs.count
      perform_enqueued_jobs(only: [Conversations::Inputs::DrainJob]) do
        Runs::Spawn::Relay.call
      end
    end
    turn = @target.turns.find_by!(input_public_id: input_id)
    assert_equal @recipient, turn.control_owner_user
    assert_equal "message", turn.communication_kind
    get conversation_path(@target), headers: auth
    assert_response :not_found
    get links_path, headers: auth
    assert_response :ok
    assert_equal link_id, response.parsed_body.fetch("links").sole.fetch("public_id")
  end

  test "request acceptance and exact result can be recovered by public task reads" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "request", to: @target.public_id, prompt: "Original work", lifetime: "conversation")
    get task_path(source, call), headers: auth
    assert_response :ok
    receipt = response.parsed_body.dig("task", "structured_content")
    original_id = receipt.fetch("input_public_id")
    turn = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id).value
    worker = turn.active_variant.run
    schedule_loop!(worker)
    run_loop_round!(worker, sse_success("The exact result"))
    clear_enqueued_jobs
    # The normal bounded recovery frontier discovers completion without a hint.
    Runs::Spawn::Relay.call
    completion = source.tasks.find_by!(node_key: receipt.fetch("completion").fetch("task_key"))
    get task_path(source, completion), headers: auth
    assert_response :ok
    result = response.parsed_body.dig("task", "structured_content")
    assert_equal original_id, result.fetch("input_public_id")
    assert_equal turn.public_id, result.fetch("turn_public_id")
    assert_equal worker.public_id, result.fetch("run_public_id")
    assert_equal "completed", result.fetch("status")
  end

  test "the same Agent cannot use a link from a different Conversation" do
    post links_path, params: { link: @fields }, headers: auth("link"), as: :json
    assert_response :created
    link_id = response.parsed_body.dig("link", "public_id")
    other = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @sender)
    _turn, source = materialize_loop_reply!(other, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "send", error: true, link_public_id: link_id, message: "Wrong endpoint")
    assert_includes call.output_body.effective_text, "not_found"
    assert_empty @target.inputs
  end

  test "a closed link refuses a new message" do
    post links_path, params: { link: @fields }, headers: auth("link"), as: :json
    assert_response :created
    link_id = response.parsed_body.dig("link", "public_id")
    post "#{links_path}/#{link_id}/closure", headers: auth, as: :json
    assert_response :ok
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "send", error: true, link_public_id: link_id, message: "Too late")
    assert_includes call.output_body.effective_text, "conversation_link_closed"
    assert_empty @target.inputs
  end

  test "a request cannot target its own Conversation" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "request", error: true, to: @source.public_id, prompt: "Deadlocking work")
    assert_includes call.output_body.effective_text, "request_target_self"
    assert_empty @source.inputs.reload
    assert_nil Runs::Delegations.for_call(call)
  end

  private

    def assert_link_contract(example)
      assert_response example.fetch("status")
      expected = example.dig("body", "link")
      actual = response.parsed_body.fetch("link")
      assert_equal expected.keys.sort, actual.keys.sort
      assert_equal expected.fetch("state"), actual.fetch("state")
      assert_equal [expected["close_reason"]], [actual["close_reason"]]
      assert_equal expected.fetch("endpoint").keys.sort, actual.fetch("endpoint").keys.sort
      assert_equal @source.public_id, actual.dig("endpoint", "conversation_public_id")
      assert_equal @recipient.public_id, actual.dig("peer", "agent_public_id")
    end

    def links_path = "#{conversation_path(@source)}/links"
    def task_path(run, task) = "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{run.public_id}/tasks/#{task.node_key}"

    def call_tool(run, name, error: false, **input)
      apply_via(loop_attempt(run), sse_success("working", tool_calls: [
        { id: "boundary_call", name: name, arguments: input.to_json },
      ]))
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [Runs::ConversationToolJob, Runs::ScheduleJob]) { Runs::ScheduleReady.call(run_id: run.id) }
      call = run.tasks.where(tool_name: name).order(:id).last
      assert_equal "completed", call.status
      assert_equal error, call.output_summary["is_error"] == true, call.output_body&.effective_text
      call
    end
end
