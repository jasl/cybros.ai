require "test_helper"
require "test_helpers/compose_test_helper"

class AgentLoops::ComposedExamplesTest < ActiveJob::TestCase
  include InvocationHarness
  include ComposeTestHelper

  EXAMPLES = Rails.root.join("test/fixtures/composed_examples")
  READ_NOTE = {
    "type" => "function", "function" => { "name" => "ReadNote" },
    "canonical" => "nexus.memory.read",
    "params" => { "location" => { "maps_to" => "path" } },
  }.freeze

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "an authored parameterized review composes parallel chains with explicit result reads" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, EXAMPLES.join("parameterized_reviews.js").read,
      { "paths" => %w[alpha.txt beta.txt] }, wait: true)

    assert_composed(agent_loop, count: 5)
    %w[alpha.txt beta.txt].each_with_index do |path, index|
      source = node(agent_loop, "r1t0-source#{index}")
      review = node(agent_loop, "r1t0-review#{index}")
      assert_equal({ "path" => path }, source.tool_input)
      assert_equal [source.node_key], review.result_from_node_keys
      assert_equal ["dev", "mock-text"], [review.provider_id, review.model_ref]
    end
    assert_equal %w[r1t0-review0 r1t0-review1], node(agent_loop, "r1t0-summary").result_from_node_keys
    assert_equal %w[round1 call_c r1t0-summary], read_by(agent_loop, "r1")
  end

  test "an authored reader retains its declared alias and maps parameters when it calls the tool" do
    agent_loop = seed(model("round1", "prompt" => "Read a note.",
      "tools" => [Nexus::Compose::DEFINITION, READ_NOTE]))
    start!(agent_loop)
    compose_round!(agent_loop, EXAMPLES.join("aliased_memory.js").read,
      { "path" => "workspace/notes/plan.md" }, wait: true)

    assert_composed(agent_loop, count: 2)
    reader = node(agent_loop, "r1t0-reader")
    assert_equal ["ReadNote"], reader.tool_definitions.map { |tool| Nexus::ToolDeclarations.name_of(tool) }
    assert_equal [reader.node_key], node(agent_loop, "r1t0-summary").result_from_node_keys

    apply_via(step_attempt(agent_loop, reader.node_key), sse_success("Reading the note.", tool_calls: [
      { id: "call_note", name: "ReadNote", arguments: { location: "workspace/notes/plan.md" }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    schedule!(agent_loop)
    note = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_note")
    assert_equal "memory_read", note.tool_name
    assert_equal "ReadNote", note.tool_alias
    assert_equal({ "path" => "workspace/notes/plan.md" }, note.tool_input)
  end

  private

    def assert_composed(agent_loop, count:)
      call = node(agent_loop, "r1t0")
      assert_equal "completed", call.status
      refute call.output_summary&.dig("is_error"), tool_result(agent_loop, "r1t0")
      assert_equal count, agent_loop.agent_loop_nodes.where("node_key LIKE 'r1t0-%'").count
    end
end
