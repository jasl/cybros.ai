require "test_helper"

# THE KERNEL'S TOOLS AND THE AGENT'S SPELLING OF THEM. `definitions_for`
# fetches the catalog's bytes (a kernel tool is declared byte-identical);
# `alias` builds the ONE other shape a kernel tool may be declared in —
# the agent's own name for it with a parameter map — as a
# compact entry the kernel renders at declaration. The SDK builds the
# shape and nothing more: the kernel is the one validator and renderer.
class ApiToolCatalogTest < Minitest::Test
  TASK = { "canonical_name" => "nexus.graph.delegate_task", "name" => "delegate_task",
           "effect_profile" => { "kind" => "write" },
           "definition" => { "type" => "function", "function" => { "name" => "delegate_task", "parameters" => {} } } }.freeze

  def client(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: @transport)
  end

  def test_definitions_for_fetches_the_catalog_bytes_in_the_order_asked
    catalog = [200, {}, { "tools" => [TASK] }]
    tools = client([catalog, catalog]).tools
    assert_equal [TASK.fetch("definition")], tools.definitions_for(["nexus.graph.delegate_task"])
    assert_equal "/agent_api/v1/tools", @transport.requests.fetch(0).fetch(:path)
    assert_raises(CybrosAgent::Api::UnknownKernelTool) { tools.definitions_for(["nexus.graph.spawn"]) }
  end

  # THE TEMPLATE: `GET /tools` serves the
  # macro-bearing SOURCE of each description beside the plain render, so a
  # pack's `recut` edits the kernel's bytes rather than a copy of them
  # (`CybrosAgent::ModelAdaptations`). The field is read by name and is
  # nil from a kernel that does not serve it.
  def test_list_reads_the_template_beside_the_plain_render
    served = TASK.merge("template" => "Give one bounded job to {{delegate_task}}.")
    entries = client([[200, {}, { "tools" => [served, TASK] }]]).tools.list

    assert_equal "Give one bounded job to {{delegate_task}}.", entries.fetch(0).template
    assert_equal "nexus.graph.delegate_task", entries.fetch(0).canonical_name
    assert_equal TASK.fetch("definition"), entries.fetch(0).definition
    assert_nil entries.fetch(1).template, "a kernel that serves no template"
    assert_equal({ "nexus.graph.delegate_task" => "Give one bounded job to {{delegate_task}}." },
      entries.first(1).to_h { |entry| [entry.canonical_name, entry.template] }, "the templates a pack's recuts render against")
  end

  def test_assembly_uses_the_current_profile_and_sends_an_explicit_empty_runner_selection
    environment = { "default_runner_executor_public_id" => nil, "executors" => [], "runner_candidates" => [] }
    body = { "tool_definitions" => [TASK.fetch("definition")], "environment" => environment }
    assembly = client([[200, {}, body]]).tools.assemble
    request = @transport.requests.fetch(0)

    assert_equal :post, request.fetch(:method)
    assert_equal "/agent_api/v1/tools/assembly", request.fetch(:path)
    assert_equal({ "default_runner_executor_public_id" => nil }, request.fetch(:body))
    assert_instance_of CybrosAgent::Api::ToolAssembly, assembly
    assert_equal body.fetch("tool_definitions"), assembly.tool_definitions
    assert_equal environment, assembly.environment
    assert_predicate assembly.tool_definitions, :frozen?
    assert_predicate assembly.environment, :frozen?
    assert_predicate assembly.environment.fetch("runner_candidates"), :frozen?
  end

  def test_assembly_preserves_explicit_configuration_and_selected_runner
    selected = "01900000-0000-7000-8000-000000000052"
    configuration = {
      "tool_definitions" => [], "kernel_tools" => ["nexus.graph.delegate_task"],
      "runner_executor_public_ids" => [selected, "01900000-0000-7000-8000-000000000051"],
      "runner_tool_names" => [],
    }
    environment = { "default_runner_executor_public_id" => selected, "executors" => [], "runner_candidates" => [] }
    client([[200, {}, { "tool_definitions" => [], "environment" => environment }]]).tools.assemble(
      configuration: configuration, default_runner_executor_public_id: selected
    )

    assert_equal({ "configuration" => configuration, "default_runner_executor_public_id" => selected },
      @transport.requests.fetch(0).fetch(:body))
  end

  def test_assembly_requires_both_result_fields
    [{ "tool_definitions" => [] }, { "environment" => {} }].each do |body|
      assert_raises(CybrosAgent::Api::MalformedResponse) { client([[200, {}, body]]).tools.assemble }
    end
  end

  def test_alias_builds_the_compact_entry_and_drops_what_is_empty
    tools = client([]).tools
    entry = tools.alias(name: "Agent", canonical: "nexus.graph.delegate_task",
      params: { run_in_background: { maps_to: "wait", invert: true, description: "true: background" } })

    assert_equal(
      { "type" => "function", "function" => { "name" => "Agent" }, "canonical" => "nexus.graph.delegate_task",
        "params" => { "run_in_background" => { "maps_to" => "wait", "invert" => true,
                                               "description" => "true: background" } } },
      entry
    )
    assert_equal({ "type" => "function", "function" => { "name" => "AskUserQuestion" }, "canonical" => "nexus.human.ask" },
      tools.alias(name: "AskUserQuestion", canonical: "nexus.human.ask"))
    assert_equal(
      { "type" => "function", "function" => { "name" => "spawn_agent" }, "canonical" => "nexus.graph.delegate_task",
        "omit" => ["wait"], "description" => "No wait verb: {{delegate_task}} answers later." },
      tools.alias(name: "spawn_agent", canonical: "nexus.graph.delegate_task", omit: [:wait],
        description: "No wait verb: {{delegate_task}} answers later.")
    )
  end

  def test_declare_configuration_sends_an_alias_entry_verbatim
    api = client([[200, {}, { "member" => { "public_id" => "019f", "handle" => "h", "kind" => "agent",
                                            "role" => "member", "display_name" => "H" },
                              "credential" => { "plane" => "member", "expires_at" => nil },
                              "configuration" => { "tool_definitions" => [], "kernel_tools" => [],
                                                   "runner_executor_public_ids" => [], "runner_tool_names" => nil },
                              "measured_at" => "2026-09-09T00:00:00Z" }]])
    entry = api.tools.alias(name: "Agent", canonical: "nexus.graph.delegate_task", defer_loading: true)
    api.profile.declare_configuration(tool_definitions: [entry], approval_mode: "bypass", approval_rules: nil,
      prompt_mechanism: "default", compaction_policy: nil)

    assert_equal [entry], @transport.requests.fetch(0).dig(:body, "configuration", "tool_definitions")
    assert_equal true, entry.fetch("defer_loading")
    assert_equal false, api.tools.alias(name: "Agent", canonical: "nexus.graph.delegate_task",
      defer_loading: false).fetch("defer_loading")
  end
end
