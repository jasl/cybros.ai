require "test_helper"

# THE SKILL CATALOG IN CONTEXT: a `skills` block beside memory, rendered once per turn into the
# sealed seed and frozen for the loop — one line per skill in precedence order (announced >
# workspace > user), under the header the `skill` tool's own text points at, bounded by
# `skill_catalog_bound` with ONE names-only tail; rendered only when the turn's tool set names
# `nexus.skill.load` (a plain `skill` or an alias), so a turn without the tool has no catalog and
# costs no query. The four assembling callers — the seed compile, the loop-backed turn, the estimate
# — hand the block their own tool set; the memory block's exclusion keeps a `skills/` row out of the
# memory text, the catalog is its pointer.
class Conversations::SkillsBlockTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

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
    @conversation.update!(runner_executor: runner)
    runner
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

  # ── the bytes ────────────────────────────────────────────────────────────

  test "the block is the header then one line per entry, announced > workspace > user, a clash resolved, one line each" do
    bind_announcing_runner!([document("deploy-notes", "How this project is deployed.\nUse before any deploy step.")])
    row!("workspace/skills/deploy-notes", "The workspace's copy — must lose.")
    row!("workspace/skills/commit-style", "How this team writes commit messages.")
    row!("user/skills/review-checklist", "Review:   how I check\n\n  a change.", user: @human)
    row!("user/skills/commit-style", "My own commits — must lose.", user: @human)

    rendered = block(tools: [Nexus::Tools::SKILL])
    assert_equal [3, 0], [rendered.included, rendered.omitted]
    assert_equal "user", rendered.segments.sole.role, "a user item, beside memory under the stable marker"
    assert_equal <<~TEXT.chomp, text_of(rendered)
      #{HEADER}
      - deploy-notes: How this project is deployed. Use before any deploy step.
      - commit-style: How this team writes commit messages.
      - review-checklist: Review: how I check a change.
    TEXT
    assert_equal Nexus::Skills::CATALOG_TITLE, text_of(rendered)[/\A[^.]+/],
      "the header's first words are what the skill tool's text quotes"
    refute_includes text_of(rendered), "source", "no source text: the route derives its own answer"
  end

  test "the same sources render the same bytes; a rewritten description moves exactly its line" do
    row!("workspace/skills/commit-style", "How we commit.")
    row!("workspace/skills/deploy-notes", "How we deploy.")
    first = text_of(block(tools: [Nexus::Tools::SKILL]))
    assert_equal first, text_of(block(tools: [Nexus::Tools::SKILL])), "deterministic"

    row!("workspace/skills/commit-style", "How we commit NOW.")
    second = text_of(block(tools: [Nexus::Tools::SKILL]))
    changed = first.lines.zip(second.lines).select { |before, after| before != after }
    assert_equal [["- commit-style: How we commit.\n", "- commit-style: How we commit NOW.\n"]], changed
  end

  test "the user rung is the TURN's principal's: two speakers, two fronts" do
    row!("user/skills/mine", "The member's.", user: @human)
    row!("user/skills/theirs", "The owner's.", user: @owner)

    assert_includes text_of(block(tools: [Nexus::Tools::SKILL], principal: @human)), "- mine: The member's."
    refute_includes text_of(block(tools: [Nexus::Tools::SKILL], principal: @human)), "theirs"
    assert_includes text_of(block(tools: [Nexus::Tools::SKILL], principal: @owner)), "- theirs: The owner's."
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

  # Twenty rows at the agentskills maximum description — the whole proof
  # of the bound: a PREFIX of the merge fits, the rest ride ONE names-only
  # tail, and the first omitted line is exactly the one that would cross.
  test "past skill_catalog_bound the rest are named in ONE tail line" do
    budget = Nexus::SizeBounds.fetch(:skill_catalog_bound)
    names = (0..19).map { |index| format("skill-%02d", index) }
    names.each { |name| row!("workspace/skills/#{name}", "d" * Nexus::Skills::DESCRIPTION_MAX_LENGTH) }

    rendered = block(tools: [Nexus::Tools::SKILL])
    assert_equal 20, rendered.included + rendered.omitted
    assert_operator rendered.omitted, :>, 0, "twenty kilobyte-descriptions cannot all fit in #{budget}"
    text = text_of(rendered)
    tails = text.lines.select { |line| line.start_with?(SkillsBlock::OMITTED) }
    assert_equal 1, tails.length, "one tail, never two"
    assert_equal names.last(rendered.omitted), tails.sole.delete_prefix("#{SkillsBlock::OMITTED} ").strip.split(", "),
      "the tail names the omitted rows, by name, in order"
    shown = text.lines.select { |line| line.start_with?("- ") }
    assert_equal names.first(rendered.included), shown.map { |line| line[/\A- ([^:]+):/, 1] }, "a prefix of the merge"
    body = text.delete_suffix(tails.sole).chomp
    assert_operator body.bytesize, :<=, budget, "the lines shown fit the bound"
    next_line = SkillsBlock.line(AgentLoops::Skills::Catalog::Entry.new(name: names[rendered.included],
      description: "d" * Nexus::Skills::DESCRIPTION_MAX_LENGTH))
    assert_operator body.bytesize + 1 + next_line.bytesize, :>, budget, "the first omitted line is the one that would cross"
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
    skills_text = "#{HEADER}\n- commit-style: How we commit."
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

  # THE STANDALONE SEED: the seed step's compiled tools and the loop's bound runner decide the
  # block, sealed once at create.
  test "a standalone loop's seed carries the catalog its bound runner and the room can load, frozen at create" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY],
      documents: [document("deploy-notes", "How this project is deployed.")]), :accepted?
    row!("workspace/skills/commit-style", "How we commit.")

    with_tool = seed(model("seed", "prompt" => "find the bug", "tools" => [Nexus::Tools::SKILL]),
      prompt_mechanism: "default", creating_user: @agent, runner_executor_public_id: runner.public_id)
    seed_texts = Array(with_tool.agent_loop_nodes.find_by!(node_key: "seed").input_value)
      .flat_map { |message| message.parts.map(&:text) }
    assert_includes seed_texts, "#{HEADER}\n- deploy-notes: How this project is deployed.\n- commit-style: How we commit."
    assert_equal "find the bug", seed_texts.last, "the words last, their own part: #{seed_texts.inspect}"

    row!("workspace/skills/commit-style", "How we commit NOW.")
    frozen = Array(with_tool.reload.agent_loop_nodes.find_by!(node_key: "seed").input_value)
      .flat_map { |message| message.parts.map(&:text) }
    assert_equal seed_texts, frozen, "a source move after create is the next loop's fact"

    without = seed(model("seed", "prompt" => "find the bug", "tools" => [READ_TOOL]),
      prompt_mechanism: "default", creating_user: @agent, runner_executor_public_id: runner.public_id)
    refute_includes Array(without.agent_loop_nodes.find_by!(node_key: "seed").input_value).to_s, HEADER
  end

  # THE LOOP-BACKED TURN: the declaring profile's set narrowed to the
  # input's `tool_names` is what the seed round declares, and what decides
  # the block — the same expression `ApplyNext#seed_round` uses.
  test "a loop-backed turn's seed round seals the block; narrowed away from skill, none" do
    row!("workspace/skills/commit-style", "How we commit.")
    declare_tools!(@agent, tools: [READ_TOOL, Nexus::Tools::SKILL])

    _turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent)
    schedule_loop!(agent_loop)
    texts = round_request_entries(loop_node(agent_loop, "r1")).map { |entry| Array(entry["parts"]).map { |part| part["text"] }.join }
    assert texts.any? { |text| text.include?("#{HEADER}\n- commit-style: How we commit.") }, texts.inspect

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
    assert rendered.entries.any? { |entry| entry["parts"].any? { |part| part["text"].to_s.include?("- commit-style: How we commit.") } },
      rendered.entries.inspect
  end
end
