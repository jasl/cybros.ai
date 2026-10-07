require "test_helper"

# THE MERGE AND THE PRESENCE RULE: `Skills::Catalog.for` is one pure derivation of the skills a turn
# can load — announced (the bound runner, then the agent address, by announcement presence alone) >
# the workspace's `skills/` rows > the controlling Human's, a clash resolved in that order — and
# `declared` is the wire's one reader: the `skill` entry of a round's stored declaration is found by
# canonical FIRST and OMITTED from the provider-bound set while the loop's merge is empty; no
# entry's bytes are ever touched.
class AgentRuns::SkillsCatalogTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  Catalog = AgentRuns::Skills::Catalog

  setup do
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  SKILL_ENTRY = { "name" => "skill", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }.freeze
  SKILL_ALIAS = { "type" => "function", "function" => { "name" => "Skill" }, "canonical" => "nexus.skill.load",
                  "params" => { "skill" => { "maps_to" => "name", "description" => "The skill name." } } }.freeze

  def document(name, description = "About #{name}.") = { "name" => name, "description" => description }

  def row!(path, description, user: nil)
    anchor = Scopes::Anchor.call(path: path, workspace: @workspace, user: user)
    MemoryDocument.transaction do
      anchor.lockable.lock!
      result = MemoryDocuments::Write.call(anchor: anchor, expected: memory_expectation_at(anchor), content: "body", description: description)
      assert_predicate result, :written?, result.outcome.to_s
      result.document
    end
  end

  def names(entries) = entries.map(&:name)

  def skill_model(key = "round1", entry: Nexus::Tools::SKILL)
    { "model" => { "key" => key, "model" => MOCK_MODEL, "prompt" => "p",
                   "tools" => [Nexus::ToolRegistry.function_definition("wait"), entry] } }
  end

  def start!(agent_run, acting_user: @human)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: acting_user))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
    agent_run
  end

  # The sealed record of the round's wire (`ModelInvocation.request_options`).
  def wired_tools(agent_run, key = "round1")
    node = agent_run.agent_run_tasks.find_by!(node_key: key)
    ModelInvocation.find(node.selected_model_invocation_id).request_options.fetch("tools")
  end

  # ── the merge ────────────────────────────────────────────────────────────

  def routed_skill(runner, name = "runner_skill")
    Nexus::Tools::SKILL.deep_dup.tap do |entry|
      entry.fetch("function")["name"] = name
      entry["route"] = { "kind" => "runner", "runner_executor_public_id" => runner.public_id, "tool_name" => "skill" }
    end
  end

  test "Runner and non Runner documents keep separate callable and source identities" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY],
      documents: [document("deploy-notes", "The runner's."), document("zeta")]), :accepted?
    address = TaskExecutor.address_for(@agent)
    create_bound_credential(executor: address, name: "Lane transport")
    assert_predicate address.announce(tools: [SKILL_ENTRY],
      documents: [document("deploy-notes", "The address's."), document("alpha")]), :accepted?
    row!("workspace/skills/deploy-notes", "The workspace's.")
    row!("workspace/skills/commit-style", "The team's commits.")
    row!("user/skills/commit-style", "My commits.", user: users(:owner))
    row!("user/skills/review-checklist", "How I review.", user: users(:owner))

    tools = [routed_skill(runner), Nexus::Tools::SKILL]
    merged = Catalog.for(tools: tools, address: address, workspace_id: @workspace.id, human: users(:owner))
    assert_equal %w[deploy-notes zeta alpha deploy-notes commit-style review-checklist], names(merged)
    same_name = merged.select { |entry| entry.name == "deploy-notes" }
    assert_equal %w[runner_skill skill], same_name.map(&:callable)
    assert_equal [runner.public_id, address.public_id], same_name.map(&:executor_public_id)
    assert_equal %w[runner agent_application], same_name.map(&:source)
    assert_equal "The team's commits.", merged.find { |entry| entry.name == "commit-style" }.description
    assert_equal "user", merged.last.source

    without_human = Catalog.for(tools: tools, address: address, workspace_id: @workspace.id, human: nil)
    assert_not_includes names(without_human), "review-checklist"
    kernel_only = Catalog.for(tools: [Nexus::Tools::SKILL], address: nil,
      workspace_id: @workspace.id, human: users(:owner))
    assert_equal %w[commit-style deploy-notes review-checklist], names(kernel_only)
    assert_equal "The workspace's.", kernel_only.fetch(1).description
  end

  test "an announcer contributes by presence and its source UUID survives in the catalog" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS, documents: [document("deploy-notes")]), :accepted?
    tools = [routed_skill(runner)]
    entries = Catalog.for(tools: tools, address: nil, workspace_id: @workspace.id, human: nil)
    assert_equal %w[deploy-notes], names(entries)
    assert_equal runner.public_id, entries.sole.executor_public_id
    assert Catalog.announces?(runner, "deploy-notes")
    assert_not Catalog.announces?(runner, "commit-style")
    assert_not Catalog.announces?(nil, "deploy-notes")

    runner.update!(status: :revoked)
    assert_empty Catalog.for(tools: tools, address: nil, workspace_id: @workspace.id, human: nil)
    assert_not Catalog.announces?(runner, "deploy-notes")
  end

  test "the provider presence rule reads the frozen catalog without live queries" do
    run = seed(skill_model)
    source = run.agent_run_tasks.find_by!(node_key: "round1")
    environment = source.operation_context.fetch("environment")
    plain = [Nexus::ToolRegistry.function_definition("wait"), Nexus::Tools::DELEGATE_TASK]
    assert_no_queries { assert_same plain, Catalog.declared(plain, run, environment: environment) }
    with_skill = [Nexus::ToolRegistry.function_definition("wait"), Nexus::Tools::SKILL]
    assert_no_queries do
      assert_equal [Nexus::ToolRegistry.function_definition("wait")], Catalog.declared(with_skill, run, environment: environment)
    end
    row!("workspace/skills/commit-style", "The team's commits.")
    assert_equal [Nexus::ToolRegistry.function_definition("wait")], Catalog.declared(with_skill, run, environment: environment)
    next_run = seed(skill_model)
    next_environment = next_run.agent_run_tasks.find_by!(node_key: "round1").operation_context.fetch("environment")
    assert_no_queries { assert_same with_skill, Catalog.declared(with_skill, next_run, environment: next_environment) }
  end

  test "the wire omits the skill entry on an empty merge and sends the stored set byte for byte otherwise" do
    empty = start!(seed(skill_model))
    node = empty.agent_run_tasks.find_by!(node_key: "round1")
    assert_equal [Nexus::Tools::SKILL, Nexus::ToolRegistry.function_definition("wait")], node.tool_definitions, "the store keeps the entry"
    assert_equal Nexus::ToolDeclarations.wire([Nexus::ToolRegistry.function_definition("wait")]), wired_tools(empty),
      "absent, not disabled: the one entry omitted, nothing else shaped"

    row!("workspace/skills/commit-style", "The team's commits.")
    full = start!(seed(skill_model))
    assert_equal Nexus::ToolDeclarations.wire(full.agent_run_tasks.find_by!(node_key: "round1").tool_definitions),
      wired_tools(full), "the structural pin: the stored set, byte for byte"
    assert_equal "skill", wired_tools(full).first.dig("function", "name")
    assert_equal Nexus::ToolRegistry.entry("skill").description, wired_tools(full).first.dig("function", "description")

    aliased = start!(seed(skill_model(entry: SKILL_ALIAS)))
    stored = aliased.agent_run_tasks.find_by!(node_key: "round1").tool_definitions
    entry = stored.find { |candidate| candidate.dig("function", "name") == "Skill" }
    assert_equal "nexus.skill.load", entry.fetch("canonical"), "the round keeps the whole alias entry"
    assert_equal Nexus::ToolDeclarations.wire(stored), wired_tools(aliased)
    wired = wired_tools(aliased).find { |candidate| candidate.dig("function", "name") == "Skill" }
    assert_equal %w[type function], wired.keys, "the alias facts never reach a provider"
    assert_includes wired.dig("function", "description"), "call Skill with the exact name",
      "the kernel's text renders under the alias"
    assert_equal %w[skill], wired.dig("function", "parameters", "properties").keys
  end
end
