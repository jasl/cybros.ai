# Build a loop-backed turn directly when a test needs control over its turn, variant, and loop
# states. The conversation-turn binding is immutable, so the loop receives it at creation.
module RunSeamTestHelper
  RunBackedTurn = Data.define(:turn, :variant, :agent_run)

  # `answering_user` is the TURN's answerer: the conversation's stored one unless the test addresses
  # another — the loop derives from it.
  def create_run_backed_turn(conversation:, acting_user:, position: nil, answering_user: nil,
                              turn_status: "running", variant_status: "running",
                              run_status: "running", approval_mode: "bypass", approval_rules: nil)
    actor = Speakers::Resolve.member(account: conversation.account, user: acting_user)
    position ||= conversation.timeline_position_head
    turn = ConversationTurn.create!(
      account: conversation.account, conversation: conversation, position: position,
      kind: "direct_reply", role: "assistant", status: turn_status,
      speaker: actor, control_owner_user: acting_user,
      answering_user: answering_user || conversation.answering_user
    )
    variant = ConversationTurnVariant.create!(
      account: conversation.account, conversation_turn: turn,
      position: 0, status: variant_status, source: "run"
    )
    turn.update!(active_variant: variant)
    conversation.update!(active_turn: turn, timeline_position_head: position + 1)
    agent_run = AgentRun.create!(
      workspace: conversation.workspace, creating_user: acting_user,
      status: run_status, conversation_turn_variant: variant,
      approval_mode: approval_mode, approval_rules: approval_rules
    )
    RunBackedTurn.new(turn: turn, variant: variant, agent_run: agent_run)
  end

  # A synthetic retained first-write capture for reader tests. Real claim and
  # settlement writers are exercised separately. `metadata::none` leaves
  # `result_metadata` null; `claimed: false` leaves
  # the row unclaimed; `role: nil` is a kernel row (nobody addressed, nobody claims).
  def runner_tool_row(agent_run, key, kind: "write", role: "runner", claimed: true,
                      claimed_by: SecureRandom.uuid, metadata: :none, tool_name: "write")
    node = agent_run.agent_run_tasks.create!(
      node_key: key, type: "AgentRunTasks::ToolTask", tool_name: tool_name, tool_input: {},
      authored_by: "author"
    )
    columns = {
      addressed_role: role,
      effect_profile: { "kind" => kind, "destructive" => kind == "write", "effect_scope" => "closed",
                        "idempotency" => "none", "reconciliation" => "none" },
    }
    if claimed
      claimed_at = Time.current
      columns.merge!(claimed_at: claimed_at, claimed_by_executor_public_id: claimed_by)
      if role == "runner" && kind == "write"
        capture = {
          "execution_generation" => node.execution_generation,
          "runner_executor_public_id" => claimed_by, "claimed_at" => claimed_at.utc.iso8601(6),
        }
        capture["checkpoint"] = metadata.fetch("checkpoint") if metadata != :none && metadata.to_h.key?("checkpoint")
        columns[:first_runner_write] = capture
      end
    end
    columns[:result_metadata] = metadata unless metadata == :none
    node.update_columns(columns)
    node
  end

  # THE DISCRIMINATING SHAPE for every eligibility site: a loop-backed loop a SPEAKER authored on a
  # conversation ANSWERED by another User, grown by `steps` and its rows started — the principal
  # every executor is judged for is the answerer, never the speaker; the speaker's write standing
  # still keeps the loop writing. Needs the authoring vocabulary and ActiveJob's helper, as the
  # executor suites have.
  def create_answered_loop(*steps, conversation:, acting_user:, answering_user: nil)
    seam = create_run_backed_turn(conversation: conversation, acting_user: acting_user,
      answering_user: answering_user)
    grow!(seam.agent_run, *steps) if steps.any?
    AgentRuns::ScheduleReady.call(agent_run_id: seam.agent_run.id)
    clear_enqueued_jobs
    seam.agent_run
  end
end
