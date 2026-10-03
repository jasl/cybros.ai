require "test_helper"

class AgentLoops::ConversationHistoryTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human, @agent = users(:member), users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      title: "人工智能 running searches")
    declare_tools!(@agent, tools: %w[session_search session_read].map { |name| Nexus::ToolRegistry.function_definition(name) })
  end

  test "declared conventional search and read tools execute through the kernel dispatch" do
    agent_loop = dispatch([
      { id: "search", name: "session_search", arguments: { query: "人工智能 runs search" }.to_json },
      { id: "read", name: "session_read", arguments: { session_id: @conversation.public_id }.to_json },
    ])
    perform_enqueued_jobs only: [AgentLoops::ConversationToolJob, AgentLoops::ScheduleJob]
    search = loop_node(agent_loop, "r2t0")
    read = loop_node(agent_loop, "r2t1")
    assert_not search.output_summary["is_error"]
    assert_not read.output_summary["is_error"]
    assert_equal @conversation.public_id, output(search).fetch("matches").sole.fetch("conversation_public_id")
    assert_equal @conversation.public_id, output(read).dig("conversation", "public_id")
    accepted = search.output_body.effective_text
    assert_no_changes -> { search.reload.output_body.effective_text } do
      AgentLoops::ConversationToolJob.perform_now(search.id)
    end
    assert_equal accepted, search.reload.output_body.effective_text
  end

  test "history tool boundary refusals settle as ordinary error text" do
    agent_loop = dispatch([
      { id: "search", name: "session_search", arguments: { query: "words", after: "broken" }.to_json },
      { id: "read", name: "session_read", arguments: { session_id: SecureRandom.uuid }.to_json },
    ])
    %w[r2t0 r2t1].each do |key|
      node = loop_node(agent_loop, key)
      AgentLoops::ConversationToolJob.perform_now(node.id)
      assert_equal "completed", node.reload.status
      assert node.output_summary.fetch("is_error")
    end
    assert_match(/\Aparameter_invalid:/, loop_node(agent_loop, "r2t0").output_body.effective_text)
    assert_match(/\Anot_found:/, loop_node(agent_loop, "r2t1").output_body.effective_text)
  end

  test "a late history result obeys the shared park deadline" do
    agent_loop = dispatch([
      { id: "search", name: "session_search", arguments: { query: "人工智能" }.to_json },
    ])
    node = loop_node(agent_loop, "r2t0")
    travel_to(node.deadline_at + 1.second) { AgentLoops::ConversationToolJob.perform_now(node.id) }
    assert_equal "timed_out", node.reload.status
    assert_nil node.output_body
  end

  private

    def dispatch(calls)
      post_input!(@conversation, acting_user: @human, text: "Find my history")
      _turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
      schedule_loop!(agent_loop)
      invocation_id = loop_node(agent_loop, "r1").selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      attempt = ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
      apply_via(attempt, sse_success("searching", tool_calls: calls))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      agent_loop
    end

    def output(node)
      JSON.parse(node.content_bodies.find_by!(role: "output").effective_text)
    end
end
