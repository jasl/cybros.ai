require "test_helper"

# THE MERGE AND THE PRESENCE RULE: `Skills::Catalog.for` is one pure derivation of the skills a turn
# can load — announced (the bound runner, then the agent address, by announcement presence alone) >
# the workspace's `skills/` rows > the controlling Human's, a clash resolved in that order — and
# `declared` is the wire's one reader: the `skill` entry of a round's stored declaration is found by
# canonical FIRST and OMITTED from the provider-bound set while the loop's merge is empty; no
# entry's bytes are ever touched.
class AgentLoops::SkillsCatalogTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  Catalog = AgentLoops::Skills::Catalog

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
                   "tools" => [Nexus::Compose::DEFINITION, entry] } }
  end

  def start!(agent_loop, acting_user: @human)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: acting_user))
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
    agent_loop
  end

  # The sealed record of the round's wire (`ModelInvocation.request_options`).
  def wired_tools(agent_loop, key = "round1")
    node = agent_loop.agent_loop_nodes.find_by!(node_key: key)
    ModelInvocation.find(node.selected_model_invocation_id).request_options.fetch("tools")
  end

  # ── the merge ────────────────────────────────────────────────────────────

  test "for merges the three sources in precedence order and resolves a clash to the announced entry" do
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

    merged = Catalog.for(runner: runner, address: address, workspace_id: @workspace.id, human: users(:owner))
    assert_equal %w[deploy-notes zeta alpha commit-style review-checklist], names(merged),
      "runner, then address, then the workspace rung by name, then the user rung by name"
    assert_equal "The runner's.", merged.first.description, "announced > workspace; the runner precedes the address"
    assert_equal "The team's commits.", merged.find { |entry| entry.name == "commit-style" }.description,
      "workspace > user"
    assert_equal Catalog::Entry.new(name: "review-checklist", description: "How I review."), merged.last
    assert_equal %w[name description], Catalog::Entry.members.map(&:to_s), "no source field"

    without_human = Catalog.for(runner: runner, address: address, workspace_id: @workspace.id, human: nil)
    assert_equal %w[deploy-notes zeta alpha commit-style], names(without_human), "no Human, no user rung"
    kernel_only = Catalog.for(runner: nil, address: nil, workspace_id: @workspace.id, human: users(:owner))
    assert_equal %w[commit-style deploy-notes review-checklist], names(kernel_only)
    assert_equal "The workspace's.", kernel_only.fetch(1).description, "the workspace row wins once nobody announces"
  end

  test "an announcer contributes by presence alone: a revoked one contributes nothing, an unready one still does" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS, documents: [document("deploy-notes")]), :accepted?
    assert_equal %w[deploy-notes], names(Catalog.for(runner: runner, address: nil, workspace_id: @workspace.id, human: nil))
    assert Catalog.announces?(runner, "deploy-notes")
    assert_not Catalog.announces?(runner, "commit-style")
    assert_not Catalog.announces?(nil, "deploy-notes")

    runner.update!(status: :revoked)
    assert_empty Catalog.for(runner: runner, address: nil, workspace_id: @workspace.id, human: nil)
    assert_not Catalog.announces?(runner, "deploy-notes")
  end

  # ── presence and the wire ────────────────────────────────────────────────

  test "declared derives nothing without the canonical, drops the skill entry on an empty merge, and keeps the set otherwise" do
    agent_loop = seed(skill_model)
    plain = [Nexus::Compose::DEFINITION, Nexus::Tools::TASK]
    assert_no_queries { assert_same plain, Catalog.declared(plain, agent_loop) }

    with_skill = [Nexus::Compose::DEFINITION, Nexus::Tools::SKILL]
    assert_not Catalog.present?(agent_loop)
    assert_equal [Nexus::Compose::DEFINITION], Catalog.declared(with_skill, agent_loop)
    aliased = [Nexus::Compose::DEFINITION, SKILL_ALIAS]
    assert_equal [Nexus::Compose::DEFINITION], Catalog.declared(aliased, agent_loop), "an alias is found by canonical"
    assert_nil Catalog.declared(nil, agent_loop).first

    row!("workspace/skills/commit-style", "The team's commits.")
    assert Catalog.present?(agent_loop)
    assert_same with_skill, Catalog.declared(with_skill, agent_loop), "the stored set, untouched"
    assert_same aliased, Catalog.declared(aliased, agent_loop)
  end

  test "present? reads announcement presence first, then one EXISTS per kernel rung" do
    agent_loop = seed(skill_model, creating_user: @agent)
    assert_not Catalog.present?(agent_loop)

    row!("user/skills/mine", "Mine.", user: users(:owner))
    assert Catalog.present?(agent_loop), "the creating agent's steward's user/ rung"
    MemoryDocument.skills.for_user(users(:owner).id).delete_all
    assert_not Catalog.present?(agent_loop)

    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS, documents: [document("deploy-notes")]), :accepted?
    agent_loop.reload
    # An announced document decides presence before any rung is asked.
    assert_no_queries_match(/memory_documents/) { assert Catalog.present?(agent_loop) }
  end

  test "the wire omits the skill entry on an empty merge and sends the stored set byte for byte otherwise" do
    empty = start!(seed(skill_model))
    node = empty.agent_loop_nodes.find_by!(node_key: "round1")
    assert_equal [Nexus::Compose::DEFINITION, Nexus::Tools::SKILL], node.tool_definitions, "the store keeps the entry"
    assert_equal Nexus::ToolDeclarations.wire([Nexus::Compose::DEFINITION]), wired_tools(empty),
      "absent, not disabled: the one entry omitted, nothing else shaped"

    row!("workspace/skills/commit-style", "The team's commits.")
    full = start!(seed(skill_model))
    assert_equal Nexus::ToolDeclarations.wire(full.agent_loop_nodes.find_by!(node_key: "round1").tool_definitions),
      wired_tools(full), "the structural pin: the stored set, byte for byte"
    assert_equal "skill", wired_tools(full).last.dig("function", "name")
    assert_equal Nexus::ToolRegistry.entry("skill").description, wired_tools(full).last.dig("function", "description")

    aliased = start!(seed(skill_model(entry: SKILL_ALIAS)))
    stored = aliased.agent_loop_nodes.find_by!(node_key: "round1").tool_definitions
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
