require "test_helper"

# THE WORLD ON THE VARIANT BLOCK: a loop-backed variant carries the derived fact through
# `loop_blocks` — one more windowed query per page — and every other source carries none; the SSE
# snapshot is the page's own shape, so the two can never render one turn two ways.
class AgentAPI::ConversationPresenterWorldTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @actor = Actors::Resolve.member(account: @account, user: @human)
  end

  def seam!(position: nil)
    seam = create_loop_backed_turn(conversation: @conversation.reload, acting_user: @human, position: position,
      turn_status: "completed", variant_status: "completed", loop_status: "completed")
    @conversation.reload.update!(active_turn: nil)
    seam
  end

  def plain_turn!(position:, source:)
    turn = ConversationTurn.create!(
      account: @account, conversation: @conversation, position: position,
      kind: "direct_reply", role: "assistant", status: "completed",
      speaker_actor: @actor, control_owner_user: @human
    )
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn, position: 0, status: "completed", source: source
    )
    turn.update!(active_variant: variant)
    @conversation.update!(timeline_position_head: position + 1)
    turn
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

  test "loop_blocks costs four batched statements for the loops, rounds, worlds and current models" do
    touched = seam!
    runner_tool_row(touched.agent_loop, "r1t0", claimed_by: "01900000-0000-7000-8000-0000000000e1",
      metadata: { "checkpoint" => { "hash" => "h1", "store" => "s1" } })
    untouched = seam!(position: 1)
    variant_ids = [touched.variant.id, untouched.variant.id, plain_turn!(position: 2, source: "inference").active_variant_id]

    statements = statements_for { @blocks = AgentAPI::ConversationPresenter.loop_blocks(variant_ids) }
    assert_equal 4, statements.length, statements.join("\n")
    assert_equal 1, statements.count { |sql| sql.include?("ROW_NUMBER() OVER (PARTITION BY agent_loop_nodes.agent_loop_id") },
      "the world is one windowed query, `first_writes`"

    assert_equal [touched.variant.id, untouched.variant.id].sort, @blocks.keys.sort, "no block for an inference variant"
    assert_equal(
      { status: "touched", loop: touched.agent_loop.public_id, runner: "01900000-0000-7000-8000-0000000000e1",
        checkpoint: { "hash" => "h1", "store" => "s1" } },
      @blocks.fetch(touched.variant.id).world
    )
    assert_equal({ status: "untouched" }, @blocks.fetch(untouched.variant.id).world)

    extra = seam!(position: 3)
    expanded = statements_for do
      @blocks = AgentAPI::ConversationPresenter.loop_blocks(variant_ids + [extra.variant.id])
    end
    assert_equal statements.length, expanded.length, "more loops do not add per-loop reads\n#{expanded.join("\n")}"
    assert_equal [touched.variant.id, untouched.variant.id, extra.variant.id].sort, @blocks.keys.sort
    empty = statements_for do
      assert_equal({}, AgentAPI::ConversationPresenter.loop_blocks([]))
    end
    assert_empty empty, "an empty page costs nothing"
  end

  test "world rides a loop-backed variant on every read and is absent on inference, edit and fork variants" do
    touched = seam!
    runner_tool_row(touched.agent_loop, "r1t0", metadata: { "checkpoint" => "c1" })
    inference = plain_turn!(position: 1, source: "inference")
    edit = plain_turn!(position: 2, source: "edit")
    fork = plain_turn!(position: 3, source: "fork")

    entries = @conversation.reload.timeline.entries(surface: :timeline)
    page = AgentAPI::ConversationPresenter.turn_entries(entries).index_by { |block| block.fetch(:public_id) }
    loop_backed = page.fetch(touched.turn.public_id).fetch(:active_variant)
    assert_equal "touched", loop_backed.dig(:world, :status)
    assert_equal "c1", loop_backed.dig(:world, :checkpoint), "verbatim, a placeholder included"
    [inference, edit, fork].each do |turn|
      block = page.fetch(turn.public_id).fetch(:active_variant)
      assert_not block.key?(:world), "no loop behind a #{block.fetch(:source)} variant, no world"
      assert_not block.key?(:agent_loop_public_id)
    end

    # The deck's read, the swipe's read and the 202 all go through `variant`
    # with the same block; one shape.
    deck = AgentAPI::ConversationPresenter.variant(
      touched.variant, body: nil, active: true, loop: AgentAPI::ConversationPresenter.loop_block(touched.variant)
    )
    assert_equal loop_backed.fetch(:world), deck.fetch(:world)
    assert_not AgentAPI::ConversationPresenter.variant(edit.active_variant, body: nil, active: true).key?(:world)
  end

  test "the SSE turn snapshot carries the world in the page's own shape" do
    touched = seam!
    runner_tool_row(touched.agent_loop, "r1t0", metadata: { "checkpoint" => { "hash" => "h1", "store" => "s1" } })

    entries = @conversation.reload.timeline.entries(surface: :timeline)
    page = AgentAPI::ConversationPresenter.turn_entries(entries).sole
    snapshot = AgentAPI::ConversationPresenter.turn_snapshot(touched.turn.reload)
    assert_equal page, snapshot, "one projection, two transports"
    assert_equal({ "hash" => "h1", "store" => "s1" }, snapshot.dig(:active_variant, :world, :checkpoint))

    published = []
    ActionCable.server.stub(:broadcast, ->(stream, payload) { published << [stream.to_s, payload] }) do
      ApplicationRecord.transaction do
        Conversations::TranscriptStream.settled_turn(touched.turn,
          variant: touched.variant, agent_loop: touched.agent_loop)
      end
    end
    settled = published.map { |_, payload| payload.fetch(:event) }.find { |event| event[:type] == "turn" }
    assert_equal snapshot, settled.fetch(:turn), "the feed's settled item is the snapshot, world included"
  end
end
