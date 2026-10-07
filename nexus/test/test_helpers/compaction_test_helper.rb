# Shared fixtures and execution drivers for both compaction hosts. The calls
# exercise acceptance, scheduling, sealing and convergence with the fake transport.
module CompactionTestHelper
  extend ActiveSupport::Concern
  include InvocationHarness
  include RunLaneTestHelper
  include ActiveRecord::Assertions::QueryAssertions

  included do
    setup do
      @account = accounts(:cybros)
      @human = users(:member)
      @agent = users(:agent)
      @workspace = workspaces(:shared)
      DevModelLane.ensure_enabled!(@account)
      @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    end
  end

  # Sized against the mock model's real 8192-token window and the real
  # tiktoken counter: five of these turns pack to ~7.0k, and the prompt
  # beside them (~1.75k) is what tips the total over. Both numbers are
  # well under the window ALONE — the wall belongs to the combination,
  # which is the only wall a summary can repair — and the history is
  # what the summarizer can read in ONE request, so the pins below can
  # ask for the oldest exchange and the newest in the same material.
  # The larger history a summarizer cannot read whole is its own case.
  HISTORY_TURNS = 5
  TURN_HEX = 1_200
  PROMPT_HEX = 1_500
  # The e2e journey's shape (`conversation_turn_test.rb`): five turns
  # that do NOT fit the summarizer's own window when rendered together.
  UNREADABLE_TURN_HEX = 2_000

  # THE WALL, REACHED HONESTLY, loop side. Two rounds, each comfortably
  # inside every authoring bound, whose COMPOSITION is not: round two
  # re-sends round one's sealed request verbatim and adds its own prompt.
  # That is the real shape of the problem — no single round is too big,
  # and the conversation still stops fitting.
  BULK = ("the quick brown fox files a report. " * 600).freeze

  # An agent's own spelling of the kernel's `wait`: the model sees `AwaitWork`, the row runs as
  # `wait`.
  WAIT_ALIAS = {
    "type" => "function", "function" => { "name" => "AwaitWork" }, "canonical" => "nexus.graph.wait",
  }.freeze

  def declared(name)
    { "type" => "function", "function" => { "name" => name, "parameters" => { "type" => "object" } } }
  end

  # ── Conversation-side helpers ────────────────────────────────────────

  def accept!(kind: "message", text: "hello", **overrides)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: @conversation, acting_user: @human, kind: kind,
      role: "user", entries: [{ "text" => text }],
      visible_in_context: true, delivery_mode: "queue", context_mode: nil,
      context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
    assert_predicate result, :accepted?
    result.value
  end

  # A reply that claims the whole window for history — the wall, stated as
  # an intent rather than engineered by a fixture.
  def ask_greedily!(text: "and now what #{SecureRandom.hex(PROMPT_HEX)}", **overrides)
    accept!(**{
      kind: "direct_reply", text: text, provider_id: "dev", model_ref: "mock-text",
      context_options: { "history" => { "token_budget_share" => 1.0 } },
    }.merge(overrides))
  end

  def drain! = Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

  def build_history!(turns: HISTORY_TURNS, hex: TURN_HEX)
    turns.times { |n| accept!(text: "turn#{n} #{SecureRandom.hex(hex)}") }
    drain!
  end

  def mock_text_selection
    ModelSelection.resolve(
      account: @account, workload: "text_generation",
      submitted: Nexus::SubmittedModelSelection.new(model: "dev/mock-text", reasoning_effort: nil),
      configuration: InferenceRequests::CoerceConfiguration.call({}),
      port: ModelSelection::Resolver.new
    ).selection
  end

  # A direct reply's invocation is on the CONVERSATION's queue; a summary
  # loop's step is on its loop's (`loop_attempt`), and carries no conversation.
  def reply_attempt
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.conversation_id == @conversation.id
    end
    raise "nothing admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end

  def summary_turn
    @conversation.conversation_turns.find_by(kind: "compaction_summary")
  end

  def summary_loop = summary_turn.active_variant.agent_run

  # The shape `ContentBodies::Replace` answers when the body will not fit.
  def refused_request
    Data.define(:accepted, :refusal) do
      def accepted? = accepted
    end.new(accepted: false, refusal: Nexus::SizeBounds::REJECTION)
  end

  # Settle the direct reply in flight and let the converger run.
  def settle_reply!(text, usage: nil)
    apply_via(reply_attempt, sse_success(text, **{ usage: usage }.compact))
    Conversations::Turns::Converge.call
  end

  # Text at prose's own token rate (about four bytes a token on the real
  # tiktoken counter), so a size below reads as tokens on the mock window.
  def prose(bytes) = ("the quick brown fox files a report. " * (bytes / 36.0).ceil).byteslice(0, bytes)

  # Settle the summary loop in flight the way a deployment does: the
  # scheduler mints the one step, the harness applies it, the loop
  # converges and completes, and the converger settles the turn.
  def settle_summary!(text)
    agent_run = summary_loop
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success(text))
    Conversations::Turns::Converge.call
  end

  # Spend the summarizer's whole budget on a non-transient refusal: the
  # attempt, its two node retries, then `absorb` — and the hold that follows.
  def fail_summary!
    agent_run = summary_loop
    schedule_loop!(agent_run)
    (Conversations::Compaction::Summarizer::RETRIES + 1).times do
      apply_via(loop_attempt(agent_run), json_response(400, { "error" => "bad" }))
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule_loop!(agent_run)
    end
    Conversations::Turns::Converge.call
  end

  def summarize!
    result = Conversations::Compaction::Request.call(
      Conversations::Compaction::Request::Command.new(
        conversation: @conversation, acting_user: @human, model: "dev/mock-text"
      )
    )
    assert_predicate result, :accepted?
    settle_summary!("THE SUMMARY")
  end

  # ROWS of `conversation_turns` actually fetched — the cost under test,
  # and deliberately not a count of QUERIES: the old walk was one query
  # too, it just returned the entire conversation.
  def turns_read(&)
    rows = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      next unless sql.start_with?("SELECT") && sql.include?("conversation_turns")
      next if sql.include?("COUNT(")

      rows += payload[:row_count].to_i
    end
    ApplicationRecord.uncached(&)
    rows
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # ── Loop-side helpers ────────────────────────────────────────────────

  # BOTH ROUNDS ARE AUTHORED UP FRONT. A loop whose only task completes
  # is finished; the history this test needs has to exist before the
  # first round settles.
  def create_loop!(*steps, creating_user: @human)
    agent_run = seed(*steps, creating_user: creating_user)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: creating_user
    ))
    schedule!(agent_run)
    agent_run
  end

  def schedule!(agent_run) = AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

  def compact(agent_run, key)
    AgentRuns::Tasks::Compact.call(AgentRuns::Tasks::Compact::Command.new(
      agent_run: agent_run, task_key: key, acting_user: @human
    ))
  end

  # A PROVIDER LENGTH REFUSAL, driven through the real apply path: the
  # attempt fails the way OpenRouter's does — a 400 whose message is the
  # only signal — and the converger applies it.
  def overflow!(agent_run, key)
    apply_via(step_attempt(agent_run, key), json_response(400, {
      "error" => { "code" => 400,
                   "message" => "This endpoint's maximum context length is 8192 tokens. " \
                                "However, you requested about 12000 tokens." },
    }))
    AgentRuns::ConvergeTerminalSteps.call
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def step_attempt(agent_run, key)
    invocation_id = node(agent_run, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def run!(agent_run, key, text)
    settle!(agent_run, key, text)
    schedule!(agent_run)
  end

  # The answer lands and converges, and NOTHING is scheduled — so a test
  # that cares which pass does what can own that pass itself. `usage` is
  # what the provider reports for the request, when the case is about that.
  def settle!(agent_run, key, text, usage: nil)
    apply_via(step_attempt(agent_run, key), sse_success(text, **{ usage: usage }.compact))
    AgentRuns::ConvergeTerminalSteps.call
  end

  # A second round, so there is a history to compact at all. `tools` is
  # the repaired round's declared set, when a case is about the names.
  def loop_with_history(compaction: nil, creating_user: @human, tools: nil)
    round1 = model("round1", "instructions" => "be useful", "prompt" => "start the work #{BULK}",
      "compaction" => compaction)
    round2 = model("round2", "prompt" => "keep going #{BULK}", "compaction" => compaction,
      **{ "tools" => tools }.compact)
    agent_run = create_loop!(round1, round2, creating_user: creating_user)
    run!(agent_run, "round1", "here is what I found")
    agent_run
  end

  # The same two rounds, stopped one pass EARLIER: round one has settled
  # and nothing has been scheduled since, so the caller's own `schedule!`
  # is the pass that reaches the wall and arms the repair.
  def loop_at_the_wall(compaction: nil, bulk: BULK, retry_budget: nil, usage: nil, creating_user: @human)
    round1 = model("round1", "instructions" => "be useful", "prompt" => bulk)
    round2 = model("round2", "prompt" => bulk, "retry" => retry_budget, "compaction" => compaction)
    agent_run = create_loop!(round1, round2, creating_user: creating_user)
    schedule!(agent_run)
    settle!(agent_run, "round1", "here is what I found", usage: usage)
    agent_run
  end

  # A loop-backed reply whose first round read one file through the real
  # chain: the fan settled with `body`, the continuation queued on it.
  def run_backed_read!(body:, words: "reading the index", compaction_policy: nil, text: nil,
                        is_error: false, outcome: "completed", **over)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, compaction_policy: compaction_policy)
    post_input!(conversation, acting_user: @human, text: "read the index")
    turn, agent_run = materialize_loop_reply!(conversation, agent: @agent, text: text, **over)
    schedule_loop!(agent_run)
    read!(agent_run, "call_a", "docs/index.txt", words, body, is_error: is_error, outcome: outcome)
    [conversation, turn, agent_run]
  end

  # The running round reads one file: it calls, the fan settles with
  # `body`, and the continuation queues on it. `is_error` is the
  # envelope's flag on a tool that RAN (data); `outcome` is the runner's
  # word on whether it ran at all (control).
  def read!(agent_run, call_id, path, words, body, is_error: false, outcome: "completed")
    call_read!(agent_run, call_id, path, words)
    AgentRuns::Parks::Settle.call(
      node: agent_run.agent_run_tasks.find_by!(tool_call_id: call_id), trusted: true,
      content: body, is_error: is_error, outcome: outcome
    )
  end

  # The call alone: the fan parks on its runner, the continuation queues.
  def call_read!(agent_run, call_id, path, words)
    run_loop_round!(agent_run, sse_success(words, tool_calls: [
      { id: call_id, name: "read_file", arguments: %({"path":"#{path}"}) },
    ]))
  end

  # Two rounds that each read a file, the third queued behind the second
  # fan: the wall is whatever the four sizes add up to, and the tail rule
  # is whatever the two renderings weigh.
  def run_backed_two_reads!(first_words:, first_body:, second_words:, second_body:, **over)
    conversation, turn, agent_run = run_backed_read!(body: first_body, words: first_words, **over)
    schedule_loop!(agent_run)
    assert_equal "running", loop_node(agent_run, "r2").status, "round two fits — the wall is round three's"
    read!(agent_run, "call_b", "docs/notes.txt", second_words, second_body)
    [conversation, turn, agent_run]
  end

  # The one narrated compaction on a host's feed.
  def compacted_item(host)
    host.conversation_event_items.where(item_type: "context_compacted").sole
  end

  def request_texts(node)
    round_request_entries(node).map do |payload|
      case payload["type"]
      when "tool_result_item" then ["result", payload.dig("payload", "output")]
      when "tool_call_item" then ["call", payload.dig("payload", "call_id")]
      else [payload["role"], payload.dig("parts", 0, "text")]
      end
    end
  end

  def continuation_of(agent_run)
    agent_run.agent_run_tasks.where(continuation_source: "round").order(:id).last
  end

  # A result body whose head is a value a summariser would love to
  # "preserve": the fabricated first lines of the ledger were exactly this.
  def read_result(bytes: 46_080)
    "first line: #{SecureRandom.hex(16)}\n".ljust(bytes, "x")
  end

  # A coding round's own shape: `Serialize#pointer` embeds a call's
  # arguments as JSON inside a string, so every quote doubles when the
  # tool_input is encoded. Pure ASCII, so a byte slice never splits a
  # character.
  def escaping_transcript(bytes)
    text = (1..4_000).map do |i|
      arguments = { "command" => "sed -n '#{i},#{i + 40}p' app/services/conversations/compaction/serialize.rb",
                    "timeout_ms" => 30_000 }.to_json
      "## Round r#{i}\n\nTool bash (completed, ok): #{arguments} -> #{1_234 + i} bytes, " \
        "not carried; re-read it if needed\n"
    end.join("\n")
    assert_operator text.bytesize, :>=, bytes
    text.byteslice(0, bytes)
  end
end
