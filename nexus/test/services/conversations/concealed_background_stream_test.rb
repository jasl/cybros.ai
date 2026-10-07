require "test_helper"

class Conversations::ConcealedBackgroundStreamTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent, tools: [Nexus::ToolRegistry.function_definition("wait"), READ_TOOL])
    @agent.update!(runner_executor_public_ids: [suite_runner.public_id])
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      answering_user: @agent, default_runner_executor: suite_runner)
  end

  test "concealing a delivered turn silences its later background content without stopping its work" do
    turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: "continue in background")
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("starting background work", tool_calls: [{
      id: "background", name: "read_file", arguments: "{}",
    }]))
    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "background")
    append_branch!(call, [tool("#{call.node_key}-gate", "read_file"), model("#{call.node_key}-later", "prompt" => "background answer")])
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("foreground answer"))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_predicate agent_run.reload, :delivered?
    assert_equal "running", agent_run.status

    post_input!(@conversation, acting_user: @human, text: "the next message")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    concealed = Conversations::Turns::SetViewState.call(Conversations::Turns::SetViewState::Command.new(
      conversation: @conversation.reload, turn_public_id: turn.public_id, acting_user: @human,
      visibility: nil, concealed: true
    ))
    assert_predicate concealed, :accepted?
    refute_includes @conversation.timeline.entries(surface: :timeline).map { |entry| entry.turn.id }, turn.id
    event_boundary = @conversation.conversation_event_items.maximum(:sequence)

    published = []
    ActionCable.server.stub(:broadcast, ->(stream, payload) { published << [stream.to_s, payload] }) do
      finish_gate(agent_run, "#{call.node_key}-gate")
      schedule_loop!(agent_run)
      attempt = loop_attempt(agent_run)
      fake_dispatch(sse_success("the concealed background answer")) do
        ModelInvocations::ExecuteAttempt.call(
          attempt: attempt, host: "solid_queue",
          stream_sink: ModelInvocations::StreamSink.for(attempt: attempt, host: "solid_queue")
        )
      end
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(agent_run)
    end

    branch = agent_run.agent_run_tasks.find_by!(node_key: "#{call.node_key}-later")
    assert_equal "completed", branch.status, "concealment changes the view, not execution"
    assert_equal "Mock: the concealed background answer", branch.output_body.effective_text
    assert @conversation.conversation_event_items.where(sequence: (event_boundary + 1)..)
      .where(item_type: "task_status").exists?, "durable task narration remains readable"
    assert_equal "Mock: the concealed background answer", AgentRuns::Transcript.round_snapshot(branch).fetch(:text_preview),
      "the loop's own transcript still owns the result"
    content_frames = published.select { |stream, _| stream.end_with?(":transcript", ":progress") }
    assert_empty content_frames, "a concealed turn no longer contributes to the conversation's content feeds"
  end

  private

    def finish_gate(agent_run, key)
      claim = Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: agent_run, task_key: key, executor: suite_runner
      ))
      assert_predicate claim, :accepted?, claim.outcome.to_s
      result = Executors::Commit.call(Executors::Commit::Command.new(
        agent_run: agent_run, task_key: key, executor: suite_runner,
        claim_token: claim.value.claim_token, content: "read complete", structured_content: nil,
        result_type: nil, outcome: "completed", is_error: false, title: nil, metadata: nil
      ))
      assert_predicate result, :applied?, result.outcome.to_s
      clear_enqueued_jobs
    end
end
