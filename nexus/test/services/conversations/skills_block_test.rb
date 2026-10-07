require "test_helper"

# The sealed skill catalog identifies each callable and source, keeps source
# precedence for kernel skills and fits whole descriptions within one byte bound.
# Each assembly caller passes its own declarations, which select the catalog.
class Conversations::SkillsBlockTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  SkillsBlock = Conversations::ContextAssembly::SkillsBlock
  HEADER = Nexus::Skills::CATALOG_HEADER
  SKILL_ENTRY = { "name" => "skill", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }.freeze
  SKILL_ALIAS = { "type" => "function", "function" => { "name" => "Skill" }, "canonical" => "nexus.skill.load",
                  "params" => { "skill" => { "maps_to" => "name", "description" => "The skill name." } } }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @owner = users(:owner)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  def row!(path, description, user: nil, content: "body")
    anchor = Scopes::Anchor.call(path: path, workspace: @workspace, user: user)
    MemoryDocument.transaction do
      anchor.lockable.lock!
      result = MemoryDocuments::Write.call(anchor: anchor, expected: memory_expectation_at(anchor), content: content, description: description)
      assert_predicate result, :written?, result.outcome.to_s
      result.document
    end
  end

  def note!(path, content, by: @human)
    result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation, path: path, by: by), conversation: @conversation, path: path, content: content, by: by)
    assert_predicate result, :accepted?, result.outcome.inspect
  end

  def document(name, description) = { "name" => name, "description" => description }

  # A runner announcing one document, bound to the conversation: the
  # announced tier of the merge.
  def bind_announcing_runner!(documents)
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY], documents: documents), :accepted?
    @conversation.update!(default_runner_executor: runner)
    runner
  end

  def routed_skill(runner, name = "runner_skill")
    Nexus::Tools::SKILL.deep_dup.tap do |entry|
      entry.fetch("function")["name"] = name
      entry["route"] = { "kind" => "runner", "runner_executor_public_id" => runner.public_id, "tool_name" => "skill" }
    end
  end

  def block(tools:, principal: @human, conversation: @conversation, **rest)
    SkillsBlock.call(conversation: conversation, principal: principal, tools: tools, **rest)
  end

  def text_of(block) = block.segments.sole.parts.map(&:text).join

  # ── the gate ─────────────────────────────────────────────────────────────

  test "no block and no query when the turn's tool set lacks nexus.skill.load" do
    row!("workspace/skills/commit-style", "How we commit.")
    assert_no_queries do
      assert_predicate block(tools: [READ_TOOL]), :empty?
      assert_predicate block(tools: nil), :empty?
      assert_predicate block(tools: []), :empty?
    end
  end

  test "a plain skill entry and an alias of it both declare the block" do
    row!("workspace/skills/commit-style", "How we commit.")
    assert_equal 1, block(tools: [Nexus::Tools::SKILL]).included
    assert_equal 1, block(tools: [READ_TOOL, SKILL_ALIAS]).included, "found by canonical, before wire strips the alias"
  end

  test "an empty merge is no block at all" do
    assert_predicate block(tools: [Nexus::Tools::SKILL]), :empty?
  end

  test "deferred skill catalogs stay out of the prefix while a narrowed set keeps eager fallback" do
    runner = bind_announcing_runner!([document("deploy-notes", "Deploy this environment")])
    row!("workspace/skills/commit-style", "How we commit.")
    skills = [routed_skill(runner), Nexus::Tools::SKILL, SKILL_ALIAS].map { |entry| entry.merge("defer_loading" => true) }
    pair = %w[tool_search tool_call].map { |name| Nexus::ToolRegistry.function_definition(name) }
    assert_no_queries do
      assert_predicate block(tools: [*pair, *skills]), :empty?
    end
    assert_equal 3, block(tools: skills).included
    assert_equal 3, block(tools: [pair.first, *skills]).included
  end

  # ── the bytes ────────────────────────────────────────────────────────────

  test "the block identifies each callable document and Runner source" do
    runner = bind_announcing_runner!([document("deploy-notes", "How this project is deployed.\nUse before any deploy step.")])
    row!("workspace/skills/deploy-notes", "The workspace's copy.")
    row!("workspace/skills/commit-style", "How this team writes commit messages.")
    row!("user/skills/review-checklist", "Review:   how I check\n\n  a change.", user: @human)
    row!("user/skills/commit-style", "My own commits — must lose.", user: @human)

    rendered = block(tools: [routed_skill(runner), Nexus::Tools::SKILL])
    assert_equal [4, 0], [rendered.included, rendered.omitted]
    assert_equal "user", rendered.segments.sole.role
    assert_equal <<~TEXT.chomp, text_of(rendered)
      #{HEADER}
      - runner_skill / deploy-notes [#{runner.public_id}]: How this project is deployed. Use before any deploy step.
      - skill / commit-style: How this team writes commit messages.
      - skill / deploy-notes: The workspace's copy.
      - skill / review-checklist: Review: how I check a change.
    TEXT
    assert_equal Nexus::Skills::CATALOG_TITLE, text_of(rendered)[/\A[^.]+/]
  end

  test "the same sources render the same bytes; a rewritten description moves exactly its line" do
    row!("workspace/skills/commit-style", "How we commit.")
    row!("workspace/skills/deploy-notes", "How we deploy.")
    first = text_of(block(tools: [Nexus::Tools::SKILL]))
    assert_equal first, text_of(block(tools: [Nexus::Tools::SKILL])), "deterministic"

    row!("workspace/skills/commit-style", "How we commit NOW.")
    second = text_of(block(tools: [Nexus::Tools::SKILL]))
    changed = first.lines.zip(second.lines).select { |before, after| before != after }
    assert_equal [["- skill / commit-style: How we commit.\n", "- skill / commit-style: How we commit NOW.\n"]], changed
  end

  test "the user rung is the TURN's principal's: two speakers, two fronts" do
    row!("user/skills/mine", "The member's.", user: @human)
    row!("user/skills/theirs", "The owner's.", user: @owner)

    assert_includes text_of(block(tools: [Nexus::Tools::SKILL], principal: @human)), "- skill / mine: The member's."
    refute_includes text_of(block(tools: [Nexus::Tools::SKILL], principal: @human)), "theirs"
    assert_includes text_of(block(tools: [Nexus::Tools::SKILL], principal: @owner)), "- skill / theirs: The owner's."
    refute_includes text_of(block(tools: [Nexus::Tools::SKILL], principal: @owner)), "mine"
  end

  test "the block ignores a nexus.memory override: a skill is the kernel's instruction row" do
    row!("workspace/skills/commit-style", "How we commit.")
    provider = connect_provider(identifier: "mem", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    set = Workspaces::SetToolProviderOverrides.call(
      workspace: @workspace, by: @owner, lock_version: @workspace.reload.lock_version,
      overrides: { "nexus.memory" => provider.public_id }
    )
    assert_equal :updated, set.outcome
    assert_equal 1, block(tools: [Nexus::Tools::SKILL], conversation: @conversation.reload).included
  end

  # ── the bound ────────────────────────────────────────────────────────────

  test "past skill_catalog_bound the complete block includes one bounded omission count" do
    budget = Nexus::SizeBounds.fetch(:skill_catalog_bound)
    names = (0..19).map { |index| format("skill-%02d", index) }
    names.each { |name| row!("workspace/skills/#{name}", "d" * Nexus::Skills::DESCRIPTION_MAX_LENGTH) }

    rendered = block(tools: [Nexus::Tools::SKILL])
    assert_equal 20, rendered.included + rendered.omitted
    assert_operator rendered.omitted, :>, 0, "twenty kilobyte-descriptions cannot all fit in #{budget}"
    text = text_of(rendered)
    tails = text.lines.select { |line| line.start_with?(SkillsBlock::OMITTED) }
    assert_equal ["#{SkillsBlock::OMITTED} #{rendered.omitted} skills."], tails.map(&:chomp)
    shown = text.lines.select { |line| line.start_with?("- ") }
    assert_equal names.first(rendered.included), shown.map { |line| line[/\A- skill \/ ([^:]+):/, 1] }, "a prefix of the merge"
    assert_operator text.bytesize, :<=, budget, "the header, descriptions and omission count all fit"
    next_line = SkillsBlock.line(AgentRuns::Skills::Catalog::Entry.new(name: names[rendered.included],
      description: "d" * Nexus::Skills::DESCRIPTION_MAX_LENGTH, callable: "skill", source: "workspace", executor_public_id: nil))
    next_tail = "#{SkillsBlock::OMITTED} #{rendered.omitted - 1} skills."
    with_next = [HEADER, *shown.map(&:chomp), next_line, next_tail].join("\n")
    assert_operator with_next.bytesize, :>, budget, "the first omitted line would cross the whole-block bound"
  end

  test "multiple Runner catalogs preserve source-qualified Unicode lines within the total bound" do
    description = "读" * 75
    documents = 24.times.map { |index| document(format("skill-%02d", index), description) }
    runners = 3.times.map do |index|
      runner = connect_runner(manager: @owner, registration_identifier: "catalog-runner-#{index}",
        assignment_scope: :account_wide).executor_access_token.task_executor
      assert_predicate runner.announce(tools: [SKILL_ENTRY], documents: documents), :accepted?
      runner
    end
    tools = runners.each_with_index.map { |runner, index| routed_skill(runner, "runner_skill_#{index}") }

    rendered = block(tools: tools)
    text = text_of(rendered)
    assert_equal 72, rendered.included + rendered.omitted
    assert_operator rendered.omitted, :>, 0
    assert_operator rendered.included, :>, 24, "the prefix includes distinct Runner sources"
    assert_operator text.bytesize, :<=, Nexus::SizeBounds.fetch(:skill_catalog_bound)
    assert_predicate text, :valid_encoding?
    expected = runners.each_with_index.flat_map do |runner, index|
      documents.map { |entry| "- runner_skill_#{index} / #{entry.fetch("name")} [#{runner.public_id}]: #{description}" }
    end
    assert_equal expected.first(rendered.included), text.lines.grep(/\A- /).map(&:chomp)
    assert_equal "#{SkillsBlock::OMITTED} #{rendered.omitted} skills.", text.lines.last.chomp
    assert_equal text, text_of(block(tools: tools)), "identical source catalogs preserve the sealed prefix"
  end

  # ── through the assembler ────────────────────────────────────────────────

  test "under default the block follows memory in the leading user item; a memory row under skills/ never renders there" do
    note!("workspace/notes.md", "gate code 4471")
    row!("workspace/skills/commit-style", "How we commit.", content: "SECRET BODY")
    assembled = Conversations::ContextAssembly.assemble(
      conversation: @conversation.reload, principal: @human, prompt: "now what",
      declaring_profile: @agent, tools: [READ_TOOL, Nexus::Tools::SKILL]
    )

    memory_text = "#{Conversations::ContextAssembly::MemoryBlock::HEADER}\n\n## workspace/notes.md\ngate code 4471"
    skills_text = "#{HEADER}\n- skill / commit-style: How we commit."
    assert_equal [[memory_text, skills_text, "now what"]],
      assembled.messages.map { |message| message.parts.map(&:text) }, "memory, skills and the words: ONE user item, each its own part"
    refute_includes assembled.messages.to_s, "SECRET BODY", "the memory block never renders a skills/ row"
    assert_equal 1, assembled.skills.included
    skills_row = assembled.blocks.find { |evidence| evidence.key == "skills" }
    assert_equal ["skills", 4, "user", "selected"], [skills_row.type, skills_row.index, skills_row.role, skills_row.state]

    without = Conversations::ContextAssembly.assemble(
      conversation: @conversation, principal: @human, prompt: "now what", declaring_profile: @agent, tools: [READ_TOOL]
    )
    assert_predicate without.skills, :empty?
    refute_includes without.messages.to_s, HEADER, "a turn without the tool has no catalog"
    assert_equal "empty", without.blocks.find { |evidence| evidence.key == "skills" }.state
  end

  test "an assembly template without a skills block renders none, whatever the tools" do
    row!("workspace/skills/commit-style", "How we commit.")
    template = PromptTemplate.parse(
      "blocks" => [{ "type" => "memory" }, { "type" => "history" }, { "type" => "input" }]
    )
    assembled = Conversations::ContextAssembly.assemble(
      conversation: @conversation, principal: @human, prompt: "now what",
      declaring_profile: @agent, tools: [Nexus::Tools::SKILL], template: template
    )
    assert_predicate assembled.skills, :empty?
    refute_includes assembled.messages.to_s, HEADER
    assert_equal %w[memory history input], assembled.blocks.map(&:key)
  end

  # The seed step's declarations select the catalog sealed once at create.
  test "a standalone Run's seed carries the declared Runner and workspace catalogs frozen at create" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY],
      documents: [document("deploy-notes", "How this project is deployed.")]), :accepted?
    row!("workspace/skills/commit-style", "How we commit.")

    with_tool = seed(model("seed", "prompt" => "find the bug", "tools" => [routed_skill(runner), Nexus::Tools::SKILL]),
      prompt_mechanism: "default", creating_user: @agent, default_runner_executor_public_id: runner.public_id)
    seed_texts = Array(with_tool.agent_run_tasks.find_by!(node_key: "seed").input_value)
      .flat_map { |message| message.parts.map(&:text) }
    assert_includes seed_texts, "#{HEADER}\n- runner_skill / deploy-notes [#{runner.public_id}]: How this project is deployed.\n- skill / commit-style: How we commit."
    assert_equal "find the bug", seed_texts.last, "the words last, their own part: #{seed_texts.inspect}"

    row!("workspace/skills/commit-style", "How we commit NOW.")
    frozen = Array(with_tool.reload.agent_run_tasks.find_by!(node_key: "seed").input_value)
      .flat_map { |message| message.parts.map(&:text) }
    assert_equal seed_texts, frozen, "a source move after create is the next Run's fact"

    without = seed(model("seed", "prompt" => "find the bug", "tools" => [READ_TOOL]),
      prompt_mechanism: "default", creating_user: @agent, default_runner_executor_public_id: runner.public_id)
    refute_includes Array(without.agent_run_tasks.find_by!(node_key: "seed").input_value).to_s, HEADER
  end

  # THE LOOP-BACKED TURN: the declaring profile's set narrowed to the
  # input's `tool_names` is what the seed round declares, and what decides
  # the block — the same expression `ApplyNext#seed_round` uses.
  test "a loop-backed turn's seed round seals the block; narrowed away from skill, none" do
    row!("workspace/skills/commit-style", "How we commit.")
    declare_tools!(@agent, tools: [READ_TOOL, Nexus::Tools::SKILL])

    _turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent)
    schedule_loop!(agent_run)
    texts = round_request_entries(loop_node(agent_run, "r1")).map { |entry| Array(entry["parts"]).map { |part| part["text"] }.join }
    assert texts.any? { |text| text.include?("#{HEADER}\n- skill / commit-style: How we commit.") }, texts.inspect

    other = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, narrowed = materialize_loop_reply!(other, agent: @agent, tool_names: ["read_file"])
    schedule_loop!(narrowed)
    narrowed_texts = round_request_entries(loop_node(narrowed, "r1")).map { |entry| Array(entry["parts"]).map { |part| part["text"] }.join }
    refute narrowed_texts.any? { |text| text.include?(HEADER) }, "the turn narrowed skill away: no catalog"
  end

  # THE ESTIMATE SURFACE shows what the send sends: the answerer's declared set.
  test "the rendered estimate carries the block the send would seal" do
    row!("workspace/skills/commit-style", "How we commit.")
    declare_tools!(@agent, tools: [READ_TOOL, Nexus::Tools::SKILL])
    result = Conversations::ContextEstimate.call(Conversations::ContextEstimate::Command.new(
      conversation: @conversation, acting_user: @human, provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: nil, request_options: nil, prompt: "so?", history_max_entries: nil,
      history_token_budget_share: nil, reasoning_replay_mode: nil, inline: nil, render: true
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    rendered = result.value.rendered
    assert_equal "selected", rendered.blocks.find { |evidence| evidence.key == "skills" }.state
    assert rendered.entries.any? { |entry| entry["parts"].any? { |part| part["text"].to_s.include?("- skill / commit-style: How we commit.") } },
      rendered.entries.inspect
  end
end
