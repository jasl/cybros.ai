require "test_helper"

class Conversations::ContextViewStateTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = Conversation.create!(
      workspace: @workspace, creating_user: @human, answering_user: @agent
    )
  end

  test "a fork's next requests use frozen prefix views and the child's own restores" do
    visible = append_message("prefix-visible")
    hidden = append_message("prefix-hidden")
    excluded = append_message("prefix-excluded")
    concealed = append_message("prefix-concealed")
    boundary = append_message("fork-boundary")
    view(hidden, visibility: "hidden")
    view(excluded, visibility: "excluded_from_context")
    view(concealed, concealed: true)

    forked = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @conversation.reload, turn_public_id: boundary.public_id,
      variant_public_id: nil, acting_user: @human, title: nil
    ))
    assert_predicate forked, :accepted?
    child = forked.value

    view(visible, visibility: "hidden")
    view(hidden, visibility: "visible")
    view(excluded, visibility: "visible")
    first, = reply_request(child, "first child question")
    assert_includes first, "prefix-visible"
    assert_includes first, "fork-boundary"
    %w[prefix-hidden prefix-excluded prefix-concealed].each { |text| refute_includes first, text }

    view(visible, conversation: child, visibility: "hidden")
    view(hidden, conversation: child, visibility: "visible")
    view(excluded, conversation: child, visibility: "visible")
    view(concealed, conversation: child, concealed: false)
    second, = reply_request(child, "second child question")
    refute_includes second, "prefix-visible"
    %w[prefix-hidden prefix-excluded prefix-concealed fork-boundary].each do |text|
      assert_includes second, text
    end
    assert_predicate concealed.reload, :deleted?, "the child's restore does not restore the source"
    assert_equal "hidden", visible.reload.visibility
  end

  test "hiding and excluding a reply remove its seed and every tool round from the next request" do
    turn = tool_reply
    %w[hidden excluded_from_context].each do |visibility|
      view(turn, visibility: visibility)
      absent, = reply_request(@conversation, "question while #{visibility}")
      assert_reply_absent(absent)

      view(turn, visibility: "visible")
      restored, = reply_request(@conversation, "question after #{visibility}")
      assert_reply_present(restored)
    end
  end

  test "undoing successors permits a concealed reply to restore into the next sealed request" do
    turn = tool_reply
    successor = append_message("successor-to-undo")
    view(turn, concealed: true)
    absent, probe = reply_request(@conversation, "probe-to-undo")
    assert_reply_absent(absent)
    assert_includes absent, "successor-to-undo"

    [probe, successor].each do |target|
      removed = Conversations::Turns::HardDelete.call(Conversations::Turns::HardDelete::Command.new(
        conversation: @conversation.reload, turn_public_id: target.public_id, acting_user: @human
      ))
      assert_predicate removed, :accepted?, removed.outcome.inspect
    end
    view(turn, concealed: false)
    restored, = reply_request(@conversation, "after restoring the tail")
    assert_reply_present(restored)
    refute_includes restored, "successor-to-undo"
    refute_includes restored, "probe-to-undo"
  end

  private

    def append_message(text)
      post_input!(@conversation, acting_user: @human, text: text)
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      @conversation.conversation_turns.order(:position).last
    end

    def view(turn, conversation: @conversation, visibility: nil, concealed: nil)
      changed = Conversations::Turns::SetViewState.call(Conversations::Turns::SetViewState::Command.new(
        conversation: conversation.reload, turn_public_id: turn.public_id,
        acting_user: @human, visibility: visibility, concealed: concealed
      ))
      assert_predicate changed, :accepted?, changed.outcome.inspect
    end

    def reply_request(conversation, prompt)
      turn, agent_run = materialize_loop_reply!(conversation.reload, agent: @human, text: prompt)
      schedule_loop!(agent_run)
      bytes = Nexus::CanonicalJson.encode(round_request_entries(loop_node(agent_run, "r1")))
      run_loop_round!(agent_run, sse_success("neutral answer"))
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      [bytes, turn]
    end

    def tool_reply
      turn, agent_run = materialize_loop_reply!(@conversation, agent: @human, text: "reply-seed-marker")
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, sse_success("first-round-marker", tool_calls: [
        { id: "call_view_marker", name: "read_file", arguments: '{"path":"tool-path-marker"}' },
      ]))
      result = AgentRuns::Parks::Settle.call(
        node: agent_run.agent_run_tasks.find_by!(tool_call_id: "call_view_marker"),
        trusted: true, content: "tool-output-marker", outcome: "completed"
      )
      assert_predicate result, :applied?
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, sse_success("final-round-marker"))
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      turn
    end

    def reply_markers
      %w[reply-seed-marker first-round-marker tool-path-marker tool-output-marker final-round-marker]
    end

    def assert_reply_absent(bytes)
      reply_markers.each { |marker| refute_includes bytes, marker }
    end

    def assert_reply_present(bytes)
      reply_markers.each { |marker| assert_includes bytes, marker }
      assert_equal 2, bytes.scan("call_view_marker\"").length,
        "the restored tool call and result appear as one pair"
    end
end
