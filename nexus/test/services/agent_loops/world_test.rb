require "test_helper"

# THE WORLD, DERIVED: one windowed query over the rows the kernel already keeps, and a fact that
# carries the runner's own record verbatim — the kernel neither compares nor reads it.
class AgentLoops::WorldTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  # A settled loop-backed turn per loop, the active pointer released so
  # the next one may stand above it.
  def loop!(position: nil)
    seam = create_loop_backed_turn(conversation: @conversation.reload, acting_user: @human, position: position,
      turn_status: "completed", variant_status: "completed", loop_status: "completed")
    @conversation.reload.update!(active_turn: nil)
    seam.agent_loop
  end

  test "a claimed runner write is touched: the loop, the claimant, the runner's record verbatim" do
    agent_loop = loop!
    row = runner_tool_row(agent_loop, "r1t0", claimed_by: "01900000-0000-7000-8000-0000000000e1",
      metadata: { "checkpoint" => { "hash" => "abc", "store" => "s1" } })

    facts = AgentLoops::World.first_writes([agent_loop.id])
    assert_equal [agent_loop.id], facts.keys
    assert_equal row.id, facts.fetch(agent_loop.id).id
    assert_equal(
      { status: "touched", loop: agent_loop.public_id, runner: "01900000-0000-7000-8000-0000000000e1",
        checkpoint: { "hash" => "abc", "store" => "s1" } },
      AgentLoops::World.fact(facts.fetch(agent_loop.id))
    )
  end

  test "an unclaimed write, a runner read and a kernel row are untouched" do
    unclaimed = loop!
    runner_tool_row(unclaimed, "r1t0", claimed: false)
    read = loop!(position: 1)
    runner_tool_row(read, "r1t0", kind: "read_only", tool_name: "read")
    kernel = loop!(position: 2)
    runner_tool_row(kernel, "r1t0", role: nil, tool_name: "memory_write")

    facts = AgentLoops::World.first_writes([unclaimed.id, read.id, kernel.id])
    assert_empty facts, "nothing a runner claimed as a write"
    assert_equal({ status: "untouched" }, AgentLoops::World.fact(facts[unclaimed.id]))
  end

  test "the first claimed write per loop, across loops, in one statement" do
    first = loop!
    first_write = runner_tool_row(first, "r1t0")
    runner_tool_row(first, "r2t0")
    second = loop!(position: 1)
    runner_tool_row(second, "r1t0", kind: "read_only")
    second_write = runner_tool_row(second, "r2t0")
    runner_tool_row(second, "r3t0")

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    facts = AgentLoops::World.first_writes([first.id, second.id])
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_equal 1, statements.length, "ONE windowed query for the page's loops: #{statements}"
    assert_equal({ first.id => first_write.id, second.id => second_write.id }, facts.transform_values(&:id))
    assert_equal({}, AgentLoops::World.first_writes([]), "no loops, no query")
  end

  test "the fact carries any value under `checkpoint` verbatim, and none when the key is absent" do
    agent_loop = loop!
    values = {
      "r1t0" => { "checkpoint" => { "hash" => "h1", "store" => "s1", "outside" => ["/tmp/x"] } },
      "r2t0" => { "checkpoint" => { "skipped" => "tree_too_large", "bytes" => 1, "files" => 2 } },
      "r3t0" => { "checkpoint" => "c1" },
      "r4t0" => { "other" => "value" },
      "r5t0" => :none,
    }
    rows = values.to_h { |key, metadata| [key, runner_tool_row(agent_loop, key, metadata: metadata)] }
    by_key = AgentLoops::World.rows(AgentLoopNode.where(id: rows.values.map(&:id))).index_by(&:node_key)

    assert_equal({ "hash" => "h1", "store" => "s1", "outside" => ["/tmp/x"] },
      AgentLoops::World.fact(by_key.fetch("r1t0")).fetch(:checkpoint))
    assert_equal({ "skipped" => "tree_too_large", "bytes" => 1, "files" => 2 },
      AgentLoops::World.fact(by_key.fetch("r2t0")).fetch(:checkpoint))
    assert_equal "c1", AgentLoops::World.fact(by_key.fetch("r3t0")).fetch(:checkpoint),
      "a placeholder rides as stored: the kernel reads nothing inside the value"
    assert_not AgentLoops::World.fact(by_key.fetch("r4t0")).key?(:checkpoint), "no key, no member"
    assert_not AgentLoops::World.fact(by_key.fetch("r5t0")).key?(:checkpoint), "no metadata, no member"
    assert_equal %i[status loop runner], AgentLoops::World.fact(by_key.fetch("r5t0")).keys
  end
end
