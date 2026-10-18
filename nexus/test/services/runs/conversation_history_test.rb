require "test_helper"

class Runs::ConversationHistoryTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

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
    run = dispatch([
      { id: "search", name: "session_search", arguments: { query: "人工智能 runs search" }.to_json },
      { id: "read", name: "session_read", arguments: { session_id: @conversation.public_id, include_execution: true }.to_json },
    ])
    perform_enqueued_jobs only: [Runs::ConversationToolJob, Runs::ScheduleJob]
    search = loop_node(run, "r2t0")
    read = loop_node(run, "r2t1")
    assert_not search.output_summary["is_error"]
    assert_not read.output_summary["is_error"]
    match = output(search).fetch("matches").sole
    assert_equal @conversation.public_id, match.fetch("conversation_public_id")
    assert_nil match.fetch("location")
    assert_equal @conversation.public_id, output(read).dig("conversation", "public_id")
    assert_equal run.public_id, output(read).dig("execution", "run_public_id")
    waiting = output(read).dig("execution", "rounds").last
    assert_equal "waiting", waiting.fetch("status")
    assert_equal %w[r2t0 r2t1], waiting.fetch("calls").fetch("items").map { |call| call.fetch("task_key") }
    accepted = search.output_body.effective_text
    assert_no_changes -> { search.reload.output_body.effective_text } do
      Runs::ConversationToolJob.perform_now(search.id)
    end
    assert_equal accepted, search.reload.output_body.effective_text
  end

  test "history tool boundary refusals settle as ordinary error text" do
    run = dispatch([
      { id: "search", name: "session_search", arguments: { query: "words", after: "broken" }.to_json },
      { id: "read", name: "session_read", arguments: { session_id: SecureRandom.uuid }.to_json },
    ])
    %w[r2t0 r2t1].each do |key|
      node = loop_node(run, key)
      Runs::ConversationToolJob.perform_now(node.id)
      assert_equal "completed", node.reload.status
      assert node.output_summary.fetch("is_error")
    end
    assert_match(/\Aparameter_invalid:/, loop_node(run, "r2t0").output_body.effective_text)
    assert_match(/\Anot_found:/, loop_node(run, "r2t1").output_body.effective_text)
  end

  test "a late history result obeys the shared park deadline" do
    run = dispatch([
      { id: "search", name: "session_search", arguments: { query: "人工智能" }.to_json },
    ])
    node = loop_node(run, "r2t0")
    travel_to(node.deadline_at + 1.second) { Runs::ConversationToolJob.perform_now(node.id) }
    assert_equal "timed_out", node.reload.status
    assert_nil node.output_body
  end

  test "frozen subtree reach filters both search results and direct UUID reads" do
    unrelated = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      title: "人工智能 other conversation")
    child = Conversation.create!(workspace: @workspace, creating_user: @agent, answering_user: @agent,
      parent_conversation: @conversation, parent_conversation_public_id: @conversation.public_id,
      title: "人工智能 child conversation")
    @agent.update!(conversation_reach: "subtree")
    run = dispatch([
      { id: "search", name: "session_search", arguments: { query: "人工智能", include_auxiliary: true }.to_json },
      { id: "foreign", name: "session_read", arguments: { session_id: unrelated.public_id }.to_json },
      { id: "child", name: "session_read", arguments: { session_id: child.public_id }.to_json },
    ])
    @agent.update!(conversation_reach: nil)
    %w[r2t0 r2t1 r2t2].each { |key| Runs::ConversationToolJob.perform_now(loop_node(run, key).id) }
    assert_equal [@conversation.public_id, child.public_id].sort,
      output(loop_node(run, "r2t0")).fetch("matches").map { |match| match.fetch("conversation_public_id") }.sort
    foreign = loop_node(run, "r2t1")
    assert foreign.output_summary.fetch("is_error")
    assert_match(/\Anot_found:/, foreign.output_body.effective_text)
    assert_equal child.public_id, output(loop_node(run, "r2t2")).dig("conversation", "public_id")
    assert_equal "subtree", run.reload.conversation_reach
  end

  test "subtree history keeps inherited text without expanding the source execution" do
    source = @conversation
    seam = create_run_backed_turn(conversation: source, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
    ContentBodies::Replace.call(owner: seam.variant, role: "content", entries: [{ "text" => "inherited context" }], seal: true)
    source.reload.update!(active_turn: nil)
    post_input!(source, acting_user: @human, text: "boundary")
    Conversations::Inputs::ApplyNext.drain(conversation_id: source.id)
    boundary = source.turns.order(:position).last
    outcome = Conversations::Fork.call(Conversations::Fork::Command.new(conversation: source,
      turn_public_id: boundary.public_id, variant_public_id: nil, acting_user: @human, title: "fork"))
    assert_predicate outcome, :accepted?
    @conversation = outcome.value
    @agent.update!(conversation_reach: "subtree")
    run = dispatch([
      { id: "read", name: "session_read", arguments: { session_id: @conversation.public_id,
        around_turn_id: seam.turn.public_id, include_execution: true }.to_json },
    ])
    @agent.update!(conversation_reach: nil)
    read = loop_node(run, "r2t0")
    Runs::ConversationToolJob.perform_now(read.id)
    assert_not read.reload.output_summary["is_error"]
    body = output(read)
    assert_equal "inherited context", body.fetch("turns").first.fetch("content")
    assert_nil body.fetch("execution")
  end

  private

    def dispatch(calls)
      post_input!(@conversation, acting_user: @human, text: "Find my history")
      _turn, run = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
      schedule_loop!(run)
      invocation_id = loop_node(run, "r1").selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      attempt = ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
      apply_via(attempt, sse_success("searching", tool_calls: calls))
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      Runs::ScheduleReady.call(run_id: run.id)
      run
    end

    def output(node)
      JSON.parse(node.content_bodies.find_by!(role: "output").effective_text)
    end
end
