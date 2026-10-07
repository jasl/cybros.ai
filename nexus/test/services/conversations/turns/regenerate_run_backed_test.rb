require "test_helper"

# REGENERATE ON A LOOP-BACKED TURN, through the real chain: the origin loop's seed round rebuilt
# behind a new candidate with its own loop — the sealed input entry-copied when the model is the
# same (byte-identical: the same fragments), re-assembled strictly below the turn when it is not;
# the trio the origin's unless the caller re-asked; the approval freeze the ORIGIN LOOP's, whatever
# the profile says today.
class Conversations::Turns::RegenerateRunBackedTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  RULES = [{ "tool" => "bash", "path" => "command", "match" => "*rm -rf /*", "verdict" => "deny" }].freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, approval_mode: "ask", approval_rules: RULES)
    post_input!(@conversation, acting_user: @human, text: "the question")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
  end

  # The origin: a loop-backed reply, its loop completed and converged. A `text` is the reply's own
  # prompt: sealed into the seed, kept on the variant, and placed after history when the request is
  # rebuilt.
  def settled_origin!(text: nil)
    turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: text)
    clear_enqueued_jobs
    AgentRuns::Transition.agent_run(agent_run, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    [turn, agent_run]
  end

  def regenerate!(turn, **overrides)
    Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(**{
      conversation: @conversation.reload, turn_public_id: turn.public_id,
      acting_user: @human, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
  end

  def seed_of(agent_run) = agent_run.agent_run_tasks.find_by!(node_key: "r1")
  def input_of(node) = node.content_bodies.find_by!(role: "input")
  def fragments_of(body) = body.content_body_entries.order(:position).pluck(:content_fragment_id, :position)
  def payloads_of(body) = body.content_body_entries.map { |entry| entry.content_fragment.payload.to_json }.join

  FROZEN_COLUMNS = %w[provider_id model_ref reasoning_effort tool_definitions request_options
                      system_instructions compaction transcript_visibility lifetime].freeze

  test "the clone path: the seed's sealed input is entry-copied byte for byte, the trio and the freeze copied" do
    turn, origin_loop = settled_origin!
    origin_seed = seed_of(origin_loop)
    origin_input = input_of(origin_seed)
    assert_predicate origin_input, :sealed?
    assert_not_empty fragments_of(origin_input)
    # The profile of the day changes; the turn's freeze must not follow it.
    declare_tools!(@agent, approval_mode: "bypass", approval_rules: nil)

    result = regenerate!(turn)

    assert_predicate result, :accepted?, result.outcome.to_s
    sibling = result.value
    new_loop = sibling.agent_run
    new_seed = seed_of(new_loop)
    new_input = input_of(new_seed)
    assert_predicate new_input, :sealed?
    assert_equal fragments_of(origin_input), fragments_of(new_input), "the same fragments in the same order"
    assert_equal [origin_input.readable_text, origin_input.byte_size], [new_input.readable_text, new_input.byte_size]
    assert_equal origin_input.content_body_uploads.pluck(:content_upload_id),
      new_input.content_body_uploads.pluck(:content_upload_id)
    assert_equal origin_seed.attributes.slice(*FROZEN_COLUMNS), new_seed.attributes.slice(*FROZEN_COLUMNS),
      "the origin seed's frozen configuration and its trio, rebuilt"
    assert_equal "kernel", new_seed.authored_by
    assert_equal ["ask", RULES, origin_loop.prompt_mechanism],
      [new_loop.approval_mode, new_loop.approval_rules, new_loop.prompt_mechanism],
      "the ORIGIN LOOP's freeze, not today's profile"
    assert_equal [origin_loop.approval_mode, origin_loop.approval_rules], [new_loop.approval_mode, new_loop.approval_rules]
    assert_equal [turn.active_variant.provider_id, turn.active_variant.model_ref, turn.active_variant.reasoning_effort],
      [sibling.provider_id, sibling.model_ref, sibling.reasoning_effort]
    assert_equal "running", new_loop.status
    assert_equal new_loop.deliverable_node_id, new_seed.id, "the seed is the deliverable, as the drain's is"
    assert_enqueued_with(job: AgentRuns::ScheduleJob, args: [new_loop.id])
  end

  test "the reassembly path: another model re-asks the context strictly below the turn under the same freeze" do
    turn, origin_loop = settled_origin!(text: "answer in verse")
    origin_input = input_of(seed_of(origin_loop))
    assert_includes payloads_of(origin_input), "answer in verse", "the origin's seed carried the reply's own prompt"
    written = PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt",
      content: "The current instructions.", role: nil)
    assert_predicate written, :written?

    result = regenerate!(turn, provider_id: "dev", model_ref: "mock-priced")

    assert_predicate result, :accepted?, result.outcome.to_s
    new_loop = result.value.agent_run
    new_seed = seed_of(new_loop)
    new_input = input_of(new_seed)
    assert_predicate new_input, :sealed?
    assert_not_equal fragments_of(origin_input), fragments_of(new_input),
      "not the origin's bytes: a foreign model gets a fresh assembly"
    assert_includes payloads_of(new_input), "the question", "the history below the turn is the question"
    assert_includes payloads_of(new_input), "answer in verse", "the reply's own question rides after the history"
    assert_includes payloads_of(new_input), "The current instructions."
    assert_equal ["dev", "mock-priced"], [new_seed.provider_id, new_seed.model_ref], "the caller's trio on the seed"
    assert_equal ["dev", "mock-priced"], [result.value.provider_id, result.value.model_ref]
    assert_equal seed_of(origin_loop).tool_definitions, new_seed.tool_definitions
    assert_equal ["ask", RULES], [new_loop.approval_mode, new_loop.approval_rules]
    assert_equal 1, ConversationTurnVariant.where(conversation_turn: turn).count - 1, "one sibling"
  end

  test "the rebuilt round runs: the scheduler mints it and the new candidate lands through the converger" do
    turn, = settled_origin!
    result = regenerate!(turn)
    assert_predicate result, :accepted?
    new_loop = result.value.agent_run

    schedule_loop!(new_loop)
    run_loop_round!(new_loop, sse_success("a second answer"))
    Conversations::Turns::Converge.call

    assert_equal "completed", new_loop.reload.status
    assert_equal result.value.id, turn.reload.active_variant_id, "a completed sample becomes the rendered one"
    assert_equal "completed", turn.status
    assert_includes turn.active_variant.content_bodies.find_by!(role: "content").effective_text, "a second answer"
  end

  # THE TURN'S QUESTION includes the per-turn text it carried: a regenerated sibling keeps the
  # origin's preface on both branches — the copied request already holds it, the rebuilt one lays it
  # where the origin's request placed it — so the next turn renders the sibling it adopted exactly as
  # that sibling's loop sent it.
  test "a regenerated variant keeps the turn's preface on both branches, and the next turn extends it" do
    lead = "Relative paths resolve against /w."
    turn, origin_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "answer in verse",
      context_options: { "inline" => [{ "role" => "developer", "position" => "lead", "text" => lead }] })
    schedule_loop!(origin_loop)
    run_loop_round!(origin_loop, sse_success("the first verse"))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    preface = turn.active_variant.content_bodies.find_by!(role: "preface").entry_payloads
    assert_equal [{ "role" => "developer", "parts" => [{ "type" => "text", "text" => lead }], "block" => "lead" }], preface

    # The same model copies the sealed request; another (free) one re-asks it.
    [{}, { provider_id: "dev", model_ref: "mock-text-only" }].each do |over|
      result = regenerate!(turn, **over)
      assert_predicate result, :accepted?, result.outcome.to_s
      sibling = result.value
      assert_equal preface, sibling.content_bodies.find_by!(role: "preface").entry_payloads,
        "#{over.empty? ? "the clone" : "the reassembly"} branch carries the origin's preface"
      sibling_loop = sibling.agent_run
      schedule_loop!(sibling_loop)
      sent = round_request_entries(loop_node(sibling_loop, "r1"))
      assert_equal [["developer", lead], ["user", "answer in verse"]],
        sent.last(2).map { |payload| [payload["role"], payload.dig("parts", 0, "text")] },
        "the re-asked question rides behind its preface, as the origin's did"
      run_loop_round!(sibling_loop, sse_success("another verse"))
      Conversations::Turns::Converge.call
      assert_equal sibling.id, turn.reload.active_variant_id
    end

    last = round_request_entries(loop_node(turn.active_variant.agent_run, "r1"))
    _turn2, loop2 = materialize_loop_reply!(@conversation, agent: @agent, text: "and next")
    schedule_loop!(loop2)
    second = round_request_entries(loop_node(loop2, "r1"))
    canonical = ->(list) { list.map { |payload| Nexus::CanonicalJson.encode(payload) } }
    assert_equal canonical.(last), canonical.(second).first(last.length),
      "the next turn opens with the regenerated loop's request whole, its preface included"
    assert_equal [["assistant", "Mock: another verse"], ["user", "and next"]],
      second.drop(last.length).map { |payload| [payload["role"], payload.dig("parts", 0, "text")] }
  end
end
