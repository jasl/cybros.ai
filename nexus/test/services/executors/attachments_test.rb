require "test_helper"

class Executors::AttachmentsTest < ActiveSupport::TestCase
  Loop = Data.define(:account, :conversation_turn_variant, :agent_run_tasks)

  setup do
    @account = accounts(:cybros)
    @user = users(:member)
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @user)
    @actor = Speaker.create!(account: @account, kind: "member", user: @user,
      channel_key: "attachments", external_id: @user.public_id, display_name: "Member")
  end

  test "prior visible active variants and this exact prompt are available but other variants and later turns are not" do
    previous, prior = attached_turn(@conversation, 0)
    alternative = attached_variant(previous, role: "content", activate: false)
    current, own = attached_turn(@conversation, 1, role: "prompt")
    _future, later = attached_turn(@conversation, 2)
    loop = loop_for(current.active_variant)

    assert_equal prior, find(loop, prior)
    assert_equal own, find(loop, own)
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, alternative) }
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, later) }
    previous.update!(visibility: "excluded_from_context")
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, prior) }
    previous.update!(visibility: "hidden")
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, prior) }
    previous.update!(deleted_at: Time.current)
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, prior) }
  end

  test "a fork reads only its reachable prefix and honors its own concealment overrides" do
    inherited, allowed = attached_turn(@conversation, 0)
    _beyond, excluded = attached_turn(@conversation, 1)
    child = Conversation.create!(workspace: @conversation.workspace, creating_user: @user)
    ConversationAncestry.create!(account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 0)
    current, _own = attached_turn(child, 1, role: "prompt")
    loop = loop_for(current.active_variant)
    assert_equal allowed, find(loop, allowed)
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, excluded) }
    ConversationTurnOverride.create!(account: @account, conversation: child,
      conversation_turn: inherited, visibility: "excluded_from_context")
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, allowed) }
  end

  test "compaction does not revoke an existing reference to an earlier bound input" do
    _previous, file = attached_turn(@conversation, 0)
    summary = turn(@conversation, 1, kind: "compaction_summary")
    attached_variant(summary, role: "content")
    current, _own = attached_turn(@conversation, 2, role: "prompt")
    assert_equal file, find(loop_for(current.active_variant), file)
  end

  test "this loop reads its bound result captures but not staged files or another loop's captures" do
    agent_run, captured = capture_loop
    _other_loop, elsewhere = capture_loop
    staged = document

    assert_equal captured, find(agent_run, captured)
    assert_raises(ActiveRecord::RecordNotFound) { find(agent_run, elsewhere) }
    assert_raises(ActiveRecord::RecordNotFound) { find(agent_run, staged) }
  end

  test "prior active variant captures follow the same visibility and position boundary as input files" do
    previous, _previous_loop, captured = captured_turn(@conversation, 0)
    _alternative_loop, alternative = captured_variant(previous, activate: false)
    current, _own = attached_turn(@conversation, 1, role: "prompt")
    _future, _future_loop, later = captured_turn(@conversation, 2)
    agent_run = loop_for(current.active_variant)

    assert_equal captured, find(agent_run, captured)
    assert_raises(ActiveRecord::RecordNotFound) { find(agent_run, alternative) }
    assert_raises(ActiveRecord::RecordNotFound) { find(agent_run, later) }
    previous.update!(visibility: "excluded_from_context")
    assert_raises(ActiveRecord::RecordNotFound) { find(agent_run, captured) }
    previous.update!(visibility: "hidden")
    assert_raises(ActiveRecord::RecordNotFound) { find(agent_run, captured) }
    previous.update!(deleted_at: Time.current)
    assert_raises(ActiveRecord::RecordNotFound) { find(agent_run, captured) }
  end

  test "a visible prior peer answerer's capture remains readable through its file reference" do
    _previous, _previous_loop, captured = captured_turn(@conversation, 0, answering_user: users(:agent))
    current, _own = attached_turn(@conversation, 1, role: "prompt")

    refute_equal users(:agent), current.answering_user
    assert_equal captured, find(loop_for(current.active_variant), captured)
  end

  test "a summary and a result prune leave the earlier output binding readable" do
    _previous, previous_loop, captured = captured_turn(@conversation, 0)
    grow!(previous_loop, model("after"))
    reader = previous_loop.agent_run_tasks.find_by!(node_key: "after")
    AgentRunTask.where(id: reader.id).update_all(compaction: { "pruned_before" => reader.node_key })

    assert_equal captured, find(previous_loop, captured)
    summary = turn(@conversation, 1, kind: "compaction_summary")
    attached_variant(summary, role: "content")
    current, _own = attached_turn(@conversation, 2, role: "prompt")
    assert_equal captured, find(loop_for(current.active_variant), captured)
  end

  test "a fork reads only captures in its inherited prefix and respects its concealment overrides" do
    inherited, _inherited_loop, allowed = captured_turn(@conversation, 0)
    _beyond, _beyond_loop, excluded = captured_turn(@conversation, 1)
    child = Conversation.create!(workspace: @conversation.workspace, creating_user: @user)
    ConversationAncestry.create!(account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 0)
    current, _own = attached_turn(child, 1, role: "prompt")
    agent_run = loop_for(current.active_variant)

    assert_equal allowed, find(agent_run, allowed)
    assert_raises(ActiveRecord::RecordNotFound) { find(agent_run, excluded) }
    ConversationTurnOverride.create!(account: @account, conversation: child,
      conversation_turn: inherited, visibility: "excluded_from_context")
    assert_raises(ActiveRecord::RecordNotFound) { find(agent_run, allowed) }
  end

  private

    def loop_for(variant)
      Loop.new(account: @account, conversation_turn_variant: variant, agent_run_tasks: AgentRunTask.none)
    end

    def find(loop, file) = Executors::Attachments.fetch(agent_run: loop, public_id: file.public_id)

    def turn(conversation, position, kind: "message", answering_user: conversation.answering_user)
      ConversationTurn.create!(account: @account, conversation: conversation, position: position,
        kind: kind, role: "user", status: "completed", speaker: @actor, control_owner_user: @user,
        answering_user: answering_user)
    end

    def attached_turn(conversation, position, role: "content")
      row = turn(conversation, position)
      [row, attached_variant(row, role: role)]
    end

    def attached_variant(turn, role:, activate: true)
      variant = ConversationTurnVariant.create!(account: @account, conversation_turn: turn,
        position: turn.conversation_turn_variants.count, status: "completed", source: "manual")
      upload = @account.content_uploads.create!(creating_user: @user,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new("document"), filename: "notes.txt",
          content_type: "text/plain", identify: false))
      ContentBodies::Replace.call(owner: variant, role: role, seal: true, uploads: [upload],
        entries: [{ "role" => "user", "parts" => [{ "type" => "upload", "upload_public_id" => upload.public_id }] }])
      turn.update!(active_variant: variant) if activate
      upload
    end

    def captured_turn(conversation, position, answering_user: conversation.answering_user)
      row = turn(conversation, position, kind: "direct_reply", answering_user: answering_user)
      agent_run, upload = captured_variant(row)
      [row, agent_run, upload]
    end

    def captured_variant(turn, activate: true)
      variant = turn.conversation_turn_variants.create!(
        position: turn.conversation_turn_variants.count, status: "completed", source: "run")
      turn.update!(active_variant: variant) if activate
      capture_loop(variant: variant)
    end

    def capture_loop(variant: nil)
      agent_run = AgentRun.create!(workspace: @conversation.workspace, creating_user: @user,
        conversation_turn_variant: variant, approval_mode: "bypass", approval_rules: [], status: "running")
      grow!(agent_run, tool("capture", "read_file", "route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }))
      node = agent_run.agent_run_tasks.find_by!(node_key: "capture")
      AgentRuns::Transition.node(node, status: "needs_approval", await_started_at: Time.current)
      AgentRuns::Transition.node(node, status: "running", started_at: Time.current,
        approval_origin: "author", approval_decided_at: Time.current)
      upload = document
      result = AgentRuns::Parks::Settle.call(node: node, trusted: true, creator: @user,
        content: [{ "type" => "resource_link", "uri" => "nexus://uploads/#{upload.public_id}",
                    "name" => upload.filename.to_s }], outcome: "completed", release: false)
      assert_predicate result, :applied?, result.outcome.to_s
      [agent_run, upload]
    end

    def document
      @account.content_uploads.create!(creating_user: @user,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-1.7\n%%EOF\n"), filename: "report.pdf",
          content_type: "application/pdf", identify: false))
    end
end
