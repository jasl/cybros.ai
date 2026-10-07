require "test_helper"

# THE STANDALONE LOOP UNDER `default` / `assembly`: the seed is compiled ONCE at create by the one
# assembler over a standalone Source — the creator's slots, the room's and the creator's memory, no
# history — with no model resolved (no window, no allocator), sealed in place of the seed step's
# authored body, and replayed by every round as the prefix; the template is the CREATOR's under the
# SHELL's word; memory is frozen at create; the summarizer reads the creator's words, never the
# slots. No second assembly path anywhere.
class AgentRuns::StandaloneSeedTest < ActiveJob::TestCase
  include InvocationHarness

  SYSTEM_PROMPT = "I am the agent.".freeze
  CHARACTER = "This is the room.".freeze
  PERSONA = "This is the person.".freeze
  PROMPT = "find the bug".freeze
  TEMPLATE = {
    "blocks" => [
      { "type" => "slot", "slot" => "system_prompt" },
      { "type" => "inline", "role" => "user", "text" => "Scene: {{scene}}." },
      { "type" => "slot", "slot" => "persona" },
      { "type" => "memory" },
      { "type" => "history" },
      { "type" => "input" },
    ],
    "variables" => { "scene" => "an ordinary day" },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @owner = users(:owner)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    # A conversation in the room: the writer of the room's memory, and the
    # owner of rows a standalone loop must never read.
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    register!("system_prompt", SYSTEM_PROMPT, on: @agent, role: "developer")
    register!("character", CHARACTER, on: @workspace)
    register!("persona", PERSONA, on: @owner, role: "user")
    write_memory!("workspace/notes.md", "workspace fact")
    travel 1.minute
    write_memory!("conversation/private.md", "conversation fact")
    travel 1.minute
    write_memory!("user/mine.md", "user fact", by: @owner)
  end

  def register!(slot, content, on:, role: nil)
    anchor = on.is_a?(Workspace) ? { workspace: on } : { user: on }
    result = PromptDocuments::Write.call(anchor: anchor, slot: slot, content: content, role: role)
    assert_predicate result, :written?, result.outcome.inspect
  end

  def write_memory!(path, content, by: @human)
    result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation, path: path, by: by), conversation: @conversation, path: path, content: content, by: by)
    assert_predicate result, :accepted?, result.outcome.inspect
  end

  def declare!(mechanism, template: nil)
    outcome = Users::DeclareConfiguration.call(user: @agent,
      tool_definitions: [], approval_mode: nil, approval_rules: nil, prompt_mechanism: mechanism,
      prompt_template: template, compaction_policy: nil
    )
    assert_equal :declared, outcome.outcome, @agent.errors.full_messages.inspect
  end

  def memory_block
    "#{Conversations::ContextAssembly::MemoryBlock::STANDALONE_HEADER}\n\n" \
      "## user/mine.md\nuser fact\n\n## workspace/notes.md\nworkspace fact"
  end

  def seed_node(agent_run) = agent_run.agent_run_tasks.find_by!(node_key: "seed")

  def seed_body(agent_run) = seed_node(agent_run).content_bodies.find_by!(role: "input")

  # [role, text] per message of the node's own input body, read back
  # through the one inverse (`ModelTask#input_value`).
  # A merged item's texts as a list, each segment its own part: the wire merges, nothing folds.
  def seed_shape(agent_run)
    Array(seed_node(agent_run).input_value).map do |message|
      texts = message.parts.map(&:text)
      [message.role, texts.one? ? texts.sole : texts]
    end
  end

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: agent_run.creating_user))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def step_attempt(agent_run, key)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.index_by { |candidate| candidate.attempt.model_invocation_id }
    clear_enqueued_jobs
    admitted.fetch(agent_run.agent_run_tasks.find_by!(node_key: key).selected_model_invocation_id).attempt
  end

  def payloads_of(body) = body.content_body_entries.map { |entry| entry.content_fragment.payload }

  # FACT 1 + 2: the Source (the creator's slots, the room's memory, no
  # history) compiled once at create with no model resolved, sealed as
  # the seed step's ONE input body under the built-in order and the merge
  # rule: persona, memory and the words are adjacent user segments — one item,
  # each its own part.
  test "under default the seed is the creator's slots, the room's memory and the words, sealed once at create" do
    agent_run = seed(model("seed", "prompt" => PROMPT), prompt_mechanism: "default", creating_user: @agent)

    assert_equal "default", agent_run.prompt_mechanism
    refute_predicate agent_run, :raw?, "the kernel summarizer is admitted on a default standalone loop"
    assert_equal [
      ["developer", SYSTEM_PROMPT],
      ["system", CHARACTER],
      ["user", [PERSONA, memory_block, "Work environment: Runner #{agent_run.default_runner.public_id}.", PROMPT]],
    ], seed_shape(agent_run)
    body = seed_body(agent_run)
    assert_predicate body, :sealed?
    assert_equal 1, seed_node(agent_run).content_bodies.where(role: "input").count, "ONE input body, the authored one replaced"
    assert_equal PROMPT, body.readable_text, "the creator's words are the body's readable text — the summarizer's and the task read's"
    refute_includes seed_shape(agent_run).to_s, "conversation fact", "the room's conversations' own rows are not the loop's"
  end

  # FACT 2: no selection exists at create, so no window sizes the seed —
  # a slot a model's window could never fund still seals whole; the
  # exact window gate is the scheduler's, later.
  test "the seed compiles with no model resolved: a slot past any window seals whole" do
    register!("character", "The room is enormous. " * 2_000, on: @workspace)

    agent_run = seed(model("seed", "prompt" => PROMPT), prompt_mechanism: "default", creating_user: @agent)

    _role, text = seed_shape(agent_run)[1]
    assert_equal "The room is enormous. " * 2_000, text, "the whole slot, nothing trimmed"
  end

  # FACT 3: the template is the CREATOR profile's, under the SHELL's word
  # — the shell IS the loop's declaration, so `assembly` reads the stored
  # template whatever the profile's standing word, `default` the built-in
  # order whatever the profile declares, and a creator with no template
  # (a Human, or an agent that stored none) refuses `prompt_template_missing`.
  test "the shell's word wins over the profile's standing word, and a missing template is refused by name" do
    declare!("assembly", template: TEMPLATE)
    templated = seed(model("seed", "prompt" => PROMPT), prompt_mechanism: "assembly", creating_user: @agent)
    assert_equal [
      ["developer", SYSTEM_PROMPT],
      ["user", ["Scene: an ordinary day.", PERSONA, memory_block, PROMPT]],
    ], seed_shape(templated), "the template's order with the variable's default; no character slot placed"
    assert_equal "assembly", templated.prompt_mechanism

    built_in = seed(model("seed", "prompt" => PROMPT), prompt_mechanism: "default", creating_user: @agent)
    assert_equal [["developer", SYSTEM_PROMPT], ["system", CHARACTER],
                  ["user", [PERSONA, memory_block, "Work environment: Runner #{built_in.default_runner.public_id}.", PROMPT]]],
      seed_shape(built_in), "the shell's default is the built-in order on an assembly-standing profile"

    declare!("default", template: TEMPLATE)
    stored = seed(model("seed", "prompt" => PROMPT), prompt_mechanism: "assembly", creating_user: @agent)
    assert_equal ["Scene: an ordinary day.", PERSONA, memory_block, PROMPT], seed_shape(stored)[1][1],
      "the shell's assembly reads the stored template on a default-standing profile"

    declare!("default", template: nil)
    refused = create_loop(model("seed", "prompt" => PROMPT), prompt_mechanism: "assembly", creating_user: @agent)
    assert_equal :prompt_template_missing, refused.outcome
    assert_equal :prompt_template_missing,
      create_loop(model("seed", "prompt" => PROMPT), prompt_mechanism: "assembly", creating_user: @human).outcome,
      "a Human creator declares no template"
    assert_equal 3, AgentRun.where(workspace_id: @workspace.id).count, "nothing born refused"

    human = seed(model("seed", "prompt" => PROMPT), prompt_mechanism: "default", creating_user: @human)
    room_memory = "#{Conversations::ContextAssembly::MemoryBlock::STANDALONE_HEADER}\n\n## workspace/notes.md\nworkspace fact"
    assert_equal [["system", CHARACTER],
                  ["user", [room_memory, "Work environment: Runner #{human.default_runner.public_id}.", PROMPT]]], seed_shape(human),
      "a Human creator's default: the room's character and memory, no system_prompt, no persona written, its own rung empty"
  end

  # The seed step's `instructions` is the raw seed's system field (the
  # system channel rides the sealed list under the assembled words), and
  # the compiled seed goes into ONE model step's body.
  test "instructions and a non-model first step are refused by name under an assembled word" do
    refused = create_loop(model("seed", "prompt" => PROMPT, "instructions" => "be terse"),
      prompt_mechanism: "default", creating_user: @agent)
    assert_equal :invalid_steps, refused.outcome
    assert_equal [{ "code" => "instructions_raw_only", "path" => "steps[0].instructions" }], refused.errors

    refused = create_loop(ask("first"), model("seed", "prompt" => PROMPT), prompt_mechanism: "default", creating_user: @agent)
    assert_equal :invalid_steps, refused.outcome
    assert_equal [{ "code" => "seed_not_a_model_step", "path" => "steps[0]" }], refused.errors

    assert_equal 0, AgentRun.where(workspace_id: @workspace.id).count, "nothing born refused"
    raw = seed(model("seed", "prompt" => PROMPT, "instructions" => "be terse"), prompt_mechanism: "raw", creating_user: @agent)
    assert_equal "be terse", seed_node(raw).system_instructions, "raw keeps its system field"
    assert_equal PROMPT, seed_node(raw).input_value, "raw keeps the prompt as the request"
  end

  # FACT 4 + 5 + 6: round one SENDS the sealed seed (the composer replays
  # it as the prefix; nothing is re-assembled at schedule), memory written
  # after create never reaches it, and the summarizer reads the creator's
  # words — never the slots, never the memory header (pointers, never values).
  test "round one sends the seed as sealed, memory is frozen at create, and the summarizer reads the words alone" do
    agent_run = seed(model("seed", "prompt" => PROMPT), prompt_mechanism: "default", creating_user: @agent)
    sealed = payloads_of(seed_body(agent_run))
    write_memory!("workspace/later.md", "written after create")

    start!(agent_run)
    attempt = step_attempt(agent_run, "seed")
    request = ModelInvocation.find(attempt.model_invocation_id).content_bodies.find_by!(role: "request")
    assert_equal sealed, payloads_of(request), "the request is the seed, entry for entry"
    refute_includes payloads_of(request).to_s, "written after create", "memory is frozen at create"
    refute ModelInvocation.find(attempt.model_invocation_id).request_options.key?("instructions"),
      "the system channel rode the list"

    apply_via(attempt, sse_success("done"))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    # The round as a later round's summarizer reads it (`Serialize#chain`
    # renders a continuation's SOURCES): the creator's words and the answer.
    rendered = Conversations::Compaction::Serialize.render_round(seed_node(agent_run).reload, {})
    assert_includes rendered, "User:\n#{PROMPT}"
    assert_includes rendered, "Assistant:\nMock: done"
    refute_includes rendered, SYSTEM_PROMPT, "no slot text reaches a summary"
    refute_includes rendered, "workspace fact", "no memory value reaches a summary"
    refute_includes rendered, Conversations::ContextAssembly::MemoryBlock::STANDALONE_HEADER
  end
end
