require "test_helper"

# THE SIDE CONVERSATION'S SHARED PREFIX (S-Q): a side's first request is the parent's running
# request above ONE boundary item, byte for byte, and that boundary is stable across the side's own
# turns until a compaction cut takes the inherited turns out of the window. A plain fork renders none.
class Conversations::ContextAssemblySidePrefixTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  BOUNDARY = Conversations::ContextAssembly::ChatHistory::BOUNDARY_TEXT

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  def converge! = Conversations::Turns::Converge.call

  # Character for character — the unit a provider's prefix cache matches.
  def canonical(entries) = entries.map { |payload| Nexus::CanonicalJson.encode(payload) }

  # Each message as role and text — a merged message's texts as a list, each part its own.
  def shape(entries)
    entries.map do |payload|
      texts = payload.fetch("parts").map { |part| part["text"] }
      [payload["role"], texts.one? ? texts.sole : texts]
    end
  end

  def side_fork!(source)
    result = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: source.reload, turn_public_id: nil, variant_public_id: nil,
      acting_user: @human, title: nil, side: true
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value
  end

  def settle_reply!(conversation, text)
    _turn, agent_run = materialize_loop_reply!(conversation, agent: @agent, text: text)
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("#{text}, done"))
    converge!
    agent_run
  end

  # Two settled replies, a third RUNNING with its round one sealed — the
  # parent's request the side's first request must share.
  def running_parent!
    settle_reply!(@conversation, "read the notes")
    settle_reply!(@conversation, "and the rest")
    turn3, loop3 = materialize_loop_reply!(@conversation, agent: @agent, text: "third")
    schedule_loop!(loop3)
    assert_equal "running", turn3.reload.status
    round_request_entries(loop_node(loop3, "r1"))
  end

  def side_request_entries!(side, text)
    _turn, side_loop = materialize_loop_reply!(side, agent: @agent, text: text)
    schedule_loop!(side_loop)
    [round_request_entries(loop_node(side_loop, "r1")), side_loop]
  end

  # The shared-prefix property: with k = the parent's request length - 1 (everything but its
  # trailing user message), the side's first k entries ARE the parent's first k, byte for byte, and
  # the frozen current turn then precedes the boundary. Exact because the last settled
  # turn is a reply (the rho shape); a person's `message` turn at P would have merged with the
  # parent's prompt and the pin would compare k - 1.
  test "THE SHARED PREFIX (S-Q): a side's first request equals the parent's running request above the boundary" do
    declare_tools!(@agent)
    parent = canonical(running_parent!)
    side = side_fork!(@conversation)

    entries, _loop = side_request_entries!(side, "aside")

    k = parent.length - 1
    assert_equal parent.first(k), canonical(entries).first(k),
      "the parent's prefix bytes are shared and PINNED"
    boundary = entries.last
    assert_equal Conversations::ContextAssembly::ChatHistory::BOUNDARY_ROLE, boundary["role"],
      "user role: the Anthropic wire hoists every system-role entry into the top block"
    assert boundary.dig("parts", 0, "text").start_with?(BOUNDARY),
      "the boundary item leads the side's own words"
    assert_equal ["user", [BOUNDARY, "aside"]], shape(entries).last,
      "the boundary merges with the side's first question by the wire rule, each its own part"
    assert_includes canonical(entries).join, "third", "the running seed is retained as reference"
    assert_includes canonical(entries).join, "Parent turn reference snapshot"
    assert_equal k + 3, entries.length
  end

  test "the boundary is byte-stable across the side's own turns" do
    declare_tools!(@agent)
    running_parent!
    side = side_fork!(@conversation)
    first, side_loop = side_request_entries!(side, "aside")
    run_loop_round!(side_loop, sse_success("an aside answered"))
    converge!

    second, _loop = side_request_entries!(side, "and more")

    assert_equal canonical(first), canonical(second).first(first.length),
      "the side's turn N+1 prefix is its turn N's WHOLE request, boundary included"
    assert_equal 1, canonical(second).join.scan(BOUNDARY[0, 40]).length, "one boundary, ever"
  end

  test "a compaction cut past the boundary renders no boundary" do
    declare_tools!(@agent)
    running_parent!
    side = side_fork!(@conversation)
    _first, side_loop = side_request_entries!(side, "aside")
    run_loop_round!(side_loop, sse_success("an aside answered"))
    converge!
    summarize!(side.reload, "what the side knew")

    entries, _loop = side_request_entries!(side, "after the cut")

    refute_includes canonical(entries).join, BOUNDARY[0, 40],
      "the inherited turns left the window with the cut, and the boundary with them"
    assert_includes canonical(entries).join, "what the side knew"
  end

  test "a plain fork renders no boundary" do
    declare_tools!(@agent)
    settle_reply!(@conversation, "read the notes")
    target = @conversation.conversation_turns.order(:position).last
    result = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @conversation.reload, turn_public_id: target.public_id, variant_public_id: nil,
      acting_user: @human, title: nil
    ))
    assert_predicate result, :accepted?, result.outcome.inspect

    entries, _loop = side_request_entries!(result.value, "onward")

    refute_includes canonical(entries).join, BOUNDARY[0, 40]
    assert_includes canonical(entries).join, "read the notes"
  end

  # A settled between-turn summary at the head, as the compaction lane
  # leaves one (kind + status are what the cut reads).
  def summarize!(conversation, text)
    actor = Speakers::Resolve.member(account: @account, user: @human)
    position = conversation.timeline_position_head
    turn = ConversationTurn.create!(
      account: @account, conversation: conversation, position: position,
      kind: Conversations::ContextAssembly::ChatHistory::COMPACTION_KIND, role: "user",
      status: "completed", speaker: actor, control_owner_user: @human
    )
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn, position: 0, status: "completed", source: "inference"
    )
    ContentBodies::Replace.call(owner: variant, role: "content", entries: [{ "text" => text }], seal: true)
    turn.update!(active_variant: variant)
    conversation.update!(timeline_position_head: position + 1)
  end
end
