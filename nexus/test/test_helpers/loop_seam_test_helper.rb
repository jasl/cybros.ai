# Build a loop-backed turn directly when a test needs control over its turn, variant, and loop
# states. The conversation-turn binding is immutable, so the loop receives it at creation.
module LoopSeamTestHelper
  LoopBackedTurn = Data.define(:turn, :variant, :agent_loop)

  # `answering_user` is the TURN's answerer: the conversation's stored one unless the test addresses
  # another — the loop derives from it.
  def create_loop_backed_turn(conversation:, acting_user:, position: nil, answering_user: nil,
                              turn_status: "running", variant_status: "running",
                              loop_status: "running", approval_mode: "bypass", approval_rules: nil)
    actor = Actors::Resolve.member(account: conversation.account, user: acting_user)
    position ||= conversation.timeline_position_head
    turn = ConversationTurn.create!(
      account: conversation.account, conversation: conversation, position: position,
      kind: "direct_reply", role: "assistant", status: turn_status,
      speaker_actor: actor, control_owner_user: acting_user,
      answering_user: answering_user || conversation.answering_user
    )
    variant = ConversationTurnVariant.create!(
      account: conversation.account, conversation_turn: turn,
      position: 0, status: variant_status, source: "agent_loop"
    )
    turn.update!(active_variant: variant)
    conversation.update!(active_turn: turn, timeline_position_head: position + 1)
    agent_loop = AgentLoop.create!(
      workspace: conversation.workspace, creating_user: acting_user,
      status: loop_status, conversation_turn_variant: variant,
      approval_mode: approval_mode, approval_rules: approval_rules
    )
    LoopBackedTurn.new(turn: turn, variant: variant, agent_loop: agent_loop)
  end

  # A TOOL ROW AS THE WORLD READS IT: a runner-addressed tool call with the effect profile frozen at
  # dispatch, claimed by an executor, carrying the runner's `metadata` verbatim — the columns
  # `AgentLoops::World` derives from, written by hand because execution reads rows the runner need
  # not have written yet. `metadata::none` leaves `result_metadata` null; `claimed: false` leaves
  # the row unclaimed; `role: nil` is a kernel row (nobody addressed, nobody claims).
  def runner_tool_row(agent_loop, key, kind: "write", role: "runner", claimed: true,
                      claimed_by: SecureRandom.uuid, metadata: :none, tool_name: "write")
    node = agent_loop.agent_loop_nodes.create!(
      node_key: key, type: "AgentLoopNodes::ToolTask", tool_name: tool_name, tool_input: {},
      authored_by: "author"
    )
    columns = {
      addressed_role: role,
      effect_profile: { "kind" => kind, "destructive" => kind == "write", "world" => "closed",
                        "idempotency" => "none", "reconciliation" => "none" },
    }
    if claimed
      columns.merge!(claimed_at: Time.current, claimed_by_executor_public_id: claimed_by)
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
    seam = create_loop_backed_turn(conversation: conversation, acting_user: acting_user,
      answering_user: answering_user)
    grow!(seam.agent_loop, *steps) if steps.any?
    AgentLoops::ScheduleReady.call(agent_loop_id: seam.agent_loop.id)
    clear_enqueued_jobs
    seam.agent_loop
  end
end
