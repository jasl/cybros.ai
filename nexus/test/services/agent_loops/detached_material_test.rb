require "test_helper"

class AgentLoops::DetachedMaterialTest < ActiveJob::TestCase
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "a detached model follows its placement dependency without reading it or joining the enclosing fan" do
    agent_loop = seed(
      parallel(
        [tool("A", "read_file"), detached(model("C", "prompt" => "Background brief"))],
        tool("B", "read_file")
      ),
      model("D", "prompt" => "Combine A and B", "results" => %w[A B])
    )
    started = AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    assert_predicate started, :accepted?
    schedule_loop!(agent_loop)

    assert_equal %w[dispatched dispatched queued queued],
      %w[A B C D].map { |key| loop_node(agent_loop, key).status }

    settle_tool(agent_loop, "A", "A RESULT")
    schedule_loop!(agent_loop)
    assert_equal %w[running dispatched queued],
      %w[C B D].map { |key| loop_node(agent_loop, key).status }
    assert_equal ["Background brief"], request_texts(agent_loop, "C"),
      "placement waits for A, but detachment starts C with its own brief"

    settle_tool(agent_loop, "B", "B RESULT")
    schedule_loop!(agent_loop)
    assert_equal %w[running running],
      %w[C D].map { |key| loop_node(agent_loop, key).status },
      "the enclosing fan releases D while detached C still runs"
    assert_nil loop_node(agent_loop, "D").input_from_node_keys
    assert_equal %w[A B], loop_node(agent_loop, "D").result_from_node_keys, "D reads what it names"
    texts = request_texts(agent_loop, "D")
    assert_equal 3, texts.length
    assert_includes texts[0], '<task_result task="A" status="completed">'
    assert_includes texts[0], "A RESULT"
    assert_includes texts[1], '<task_result task="B" status="completed">'
    assert_includes texts[1], "B RESULT"
    assert_equal "Combine A and B", texts.last
  end

  private

    def settle_tool(agent_loop, key, content)
      result = AgentLoops::Parks::Settle.call(
        node: loop_node(agent_loop, key), trusted: true, content: content, outcome: "completed"
      )
      assert_predicate result, :applied?
    end

    def request_texts(agent_loop, key)
      round_request_entries(loop_node(agent_loop, key)).map { |entry| entry.dig("parts", 0, "text") }
    end
end
