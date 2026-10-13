require "test_helper"

# THE WORLD AT A FORK POINT: the PHYSICAL rule — the first runner-claimed write-kind call strictly
# above the position over every loop of every variant of every turn in the source's reach,
# candidates, activation and concealment ignored — as ONE statement.
class Conversations::RunnerEffectsAtTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @runner_id = "01900000-0000-7000-8000-0000000000e1"
    @actor = Speakers::Resolve.member(account: @account, user: @human)
  end

  def runner_tool_row(*args, claimed_by: @runner_id, **options) = super(*args, claimed_by: claimed_by, **options)

  # A settled loop-backed turn at `position`, the active pointer released.
  def seam!(conversation = @conversation, position: nil)
    seam = create_run_backed_turn(conversation: conversation.reload, acting_user: @human, position: position,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
    conversation.reload.update!(active_turn: nil)
    seam
  end

  def message!(conversation = @conversation, position:)
    turn = ConversationTurn.create!(
      account: @account, conversation: conversation, position: position,
      kind: "message", role: "user", status: "completed",
      speaker: @actor, control_owner_user: @human
    )
    conversation.update!(timeline_position_head: position + 1)
    turn
  end

  # A second, non-active candidate behind the seam's turn, with its own loop.
  def sibling_loop!(seam)
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: seam.turn, position: 1, status: "completed", source: "run"
    )
    AgentRun.create!(workspace: @workspace, creating_user: @human, status: "completed",
      conversation_turn_variant: variant, approval_mode: "bypass")
  end

  def runner_effects_at(conversation, position) = Conversations::RunnerEffectsAt.call(conversation: conversation, position: position)

  test "nothing claimed above the position is untouched, a write AT the position included" do
    message!(position: 0)
    own = seam!(position: 1)
    runner_tool_row(own.agent_run, "r1t0")

    assert_equal({ status: "untouched", runners: [] }, runner_effects_at(@conversation, 1), "N's own loop's writes stand")
    assert_equal({ status: "untouched", runners: [] }, runner_effects_at(@conversation, 5), "nothing above the tail")
  end

  test "the first write in a later turn names that loop, its claimant and its record" do
    message!(position: 0)
    seam!(position: 1)
    later = seam!(position: 2)
    runner_tool_row(later.agent_run, "r1t0", kind: "read_only")
    write = runner_tool_row(later.agent_run, "r2t0", claimed_by: "01900000-0000-7000-8000-0000000000e1",
      metadata: { "checkpoint" => { "hash" => "h2", "store" => "s" } })
    runner_tool_row(later.agent_run, "r3t0", metadata: { "checkpoint" => { "hash" => "later" } })

    fact = runner_effects_at(@conversation, 0)
    assert_equal "touched", fact.fetch(:status)
    assert_equal later.agent_run.public_id, fact.fetch(:runners).first.fetch(:run_public_id)
    assert_equal write.claimed_by_executor_public_id, fact.fetch(:runners).first.fetch(:runner_executor_public_id)
    assert_equal({ "hash" => "h2", "store" => "s" }, fact.fetch(:runners).first.fetch(:checkpoint))
  end

  test "a NON-ACTIVE candidate's loop that wrote first is the runner_effects, not the active one's" do
    message!(position: 0)
    seam = seam!(position: 1)
    old_candidate = sibling_loop!(seam)
    runner_tool_row(old_candidate, "r1t0", metadata: { "checkpoint" => { "hash" => "old" } })
    runner_tool_row(seam.agent_run, "r1t0", metadata: { "checkpoint" => { "hash" => "active" } })
    assert_equal seam.variant.id, seam.turn.reload.active_variant_id, "the active candidate wrote second"

    fact = runner_effects_at(@conversation, 0)
    assert_equal old_candidate.public_id, fact.fetch(:runners).first.fetch(:run_public_id), "the physical rule: the lowest write, whoever renders"
    assert_equal({ "hash" => "old" }, fact.fetch(:runners).first.fetch(:checkpoint))
  end

  test "a CONCEALED turn above the position still counts: the overlay is a view rule" do
    message!(position: 0)
    concealed = seam!(position: 1)
    runner_tool_row(concealed.agent_run, "r1t0", metadata: { "checkpoint" => { "hash" => "hidden" } })
    visible = seam!(position: 2)
    runner_tool_row(visible.agent_run, "r1t0", metadata: { "checkpoint" => { "hash" => "shown" } })
    concealed.turn.update!(deleted_at: Time.current)
    assert_equal [0, 2], @conversation.reload.timeline.entries(surface: :timeline).map(&:position),
      "the timeline hides the concealed turn"

    assert_equal({ "hash" => "hidden" }, runner_effects_at(@conversation, 0).fetch(:runners).first.fetch(:checkpoint))
  end

  test "an inherited position reads the ancestor's rows to its bound and the child's own above it" do
    message!(position: 0)
    early = seam!(position: 1)
    runner_tool_row(early.agent_run, "r1t0", metadata: { "checkpoint" => { "hash" => "early" } })
    boundary = seam!(position: 2)
    beyond = seam!(position: 3)
    runner_tool_row(beyond.agent_run, "r1t0", metadata: { "checkpoint" => { "hash" => "beyond" } })

    forked = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @conversation, turn_public_id: boundary.turn.public_id, variant_public_id: nil,
      acting_user: @human, title: nil
    ))
    assert_predicate forked, :accepted?
    child = forked.value
    local = seam!(child, position: 3)
    runner_tool_row(local.agent_run, "r1t0", metadata: { "checkpoint" => { "hash" => "local" } })

    assert_equal({ "hash" => "early" }, runner_effects_at(child, 0).fetch(:runners).first.fetch(:checkpoint), "the ancestor's row below its bound")
    assert_equal({ "hash" => "local" }, runner_effects_at(child, 1).fetch(:runners).first.fetch(:checkpoint),
      "above the bound the ancestor's rows are outside the child's reach — the child's own write is first")
    assert_equal({ "hash" => "local" }, runner_effects_at(child, 2).fetch(:runners).first.fetch(:checkpoint))
    assert_equal({ status: "untouched", runners: [] }, runner_effects_at(child, 3))
    assert_equal({ "hash" => "beyond" }, runner_effects_at(@conversation, 2).fetch(:runners).first.fetch(:checkpoint), "the source reads its own")
  end

  test "a side fork's point — the newest settled turn — has nothing above it" do
    message!(position: 0)
    settled = seam!(position: 1)
    runner_tool_row(settled.agent_run, "r1t0")

    assert_equal({ status: "untouched", runners: [] }, runner_effects_at(@conversation, @conversation.reload.timeline_position_head - 1))
  end

  test "one statement over the reach at 200 rounds across 40 branches, the count independent of size" do
    small = statements_for { runner_effects_at(@conversation, 0) }

    message!(position: 0)
    source = @conversation
    conversations = [source]
    # A chain of 30 forks (under the closure's depth cap) and 10 siblings
    # off the last: 40 branches, every one with a settled loop-backed turn
    # of five claimed writes — 200 write-kind rounds, the deepest's reach
    # holding 155 of them across 31 conversations.
    39.times do |index|
      parent = index < 30 ? conversations.last : conversations[30]
      seam = seam!(parent, position: parent.reload.timeline_position_head)
      5.times { |round| runner_tool_row(seam.agent_run, "r#{round}t0") }
      forked = Conversations::Fork.call(Conversations::Fork::Command.new(
        conversation: parent, turn_public_id: seam.turn.public_id, variant_public_id: nil,
        acting_user: @human, title: nil
      ))
      assert_predicate forked, :accepted?, forked.outcome.to_s
      conversations << forked.value
    end
    deepest = conversations[30]
    seam = seam!(deepest, position: deepest.reload.timeline_position_head)
    5.times { |round| runner_tool_row(seam.agent_run, "r#{round}t0") }
    assert_equal 30, deepest.conversation_ancestries.count
    assert_equal 200, AgentRunTask.where.not(first_runner_write: nil).count

    large = statements_for { runner_effects_at(deepest, 0) }
    assert_equal small.length, large.length, "the count never follows the size: #{large}"
    assert_equal 1, large.count { |sql| sql.include?("agent_run_tasks") },
      "ONE read over the reach — the other is the reach's own ancestry list"
    assert_equal "touched", runner_effects_at(deepest, 0).fetch(:status)
  end

  def statements_for
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
