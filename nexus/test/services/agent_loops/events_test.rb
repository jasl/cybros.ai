require "test_helper"

# The loop narrates on the one hosted plane: a standalone loop on itself, a loop-backed loop on its
# conversation — driven through the REAL execution chain, so a follower reading only the stream can
# reconstruct where the loop and every task stand, without ever seeing a node id, a countdown, or a
# generation.
class AgentLoops::EventsTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  def run_step!(agent_loop)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.agent_loop_id == agent_loop.id
    end
    raise "step not admitted" if admitted.nil?

    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("the answer"))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
  end

  def items(host) = host.conversation_event_items.order(:sequence).to_a

  def types(host) = items(host).map(&:item_type)

  def conversation!
    Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  test "a whole run narrates itself: birth, start, step, round, usage, completion" do
    agent_loop = seed(model("only", "prompt" => "answer me"))
    assert_equal %w[task_status], types(agent_loop),
      "the seed batch narrates its newborn task"
    assert_equal "waiting", items(agent_loop).sole.payload.fetch("status"),
      "queued is the engine's word — the stream speaks the product's"

    start!(agent_loop)
    run_step!(agent_loop)

    stream = types(agent_loop)
    # NO APPROVAL STAGE ON A ROUND: a round is admitted by the admission plane and goes `waiting →
    # running` in one item; the stage is the tool call's alone (the test below).
    assert_equal %w[
      task_status turn_status task_status task_status round_result usage turn_status
    ], stream

    payloads = items(agent_loop).map(&:payload)
    assert_equal "running", payloads[1].fetch("loop_status")
    assert_equal "running", payloads[1].fetch("status"),
      "a standalone loop is its own host: the turn-shaped status rides the same write"
    assert_equal agent_loop.public_id, payloads[1].fetch("agent_loop_public_id")
    assert_not payloads[1].key?("turn_public_id"), "no turn row, no turn id"
    assert_equal "running", payloads[2].fetch("status"), "the task started, with no stage to cross"
    assert_equal "completed", payloads[3].fetch("status")
    assert_equal "only", payloads[4].fetch("task_key")
    assert_equal "dev/mock-text", payloads[4].fetch("model")
    assert_operator payloads[5].fetch("total_tokens"), :>, 0, "the round's cost rides along"
    assert_equal "completed", payloads[6].fetch("loop_status"), "and the loop settles"
    assert_equal "completed", payloads[6].fetch("status")

    assert_equal (1..stream.length).to_a, items(agent_loop).map(&:sequence),
      "sequences are host-local, start at 1 and are CONTIGUOUS — a follower " \
      "detects a gap by arithmetic"
  end

  # The approval stage on a TOOL task, under bypass: the row crosses `needs_approval` and is
  # dispatched in ONE transaction — the two items land in one flush, back to back, and nothing rests
  # in between.
  test "a tool task crosses needs_approval into dispatched in one flush under bypass" do
    agent_loop = seed(tool("call", "read_file"))
    start!(agent_loop)

    statuses = items(agent_loop)
      .select { |item| item.item_type == "task_status" && item.payload["task_key"] == "call" }
      .map { |item| item.payload.fetch("status") }
    assert_equal %w[waiting needs_approval dispatched], statuses
    assert_equal "dispatched", agent_loop.agent_loop_nodes.sole.reload.status, "nothing rests under bypass"

    # THE FACT RIDES THE STREAM: the crossing is a grant — this row was AUTHORED through the append
    # door, so its origin is `author` under every mode; a model-composed row under bypass reads
    # `mode` — the origin and the time, nobody named — on the `dispatched` item alone; the earlier
    # items carry no block.
    items = items(agent_loop)
      .select { |item| item.item_type == "task_status" && item.payload["task_key"] == "call" }
    assert_equal [nil, nil], items.first(2).map { |item| item.payload["approval"] }
    approval = items.last.payload.fetch("approval")
    assert_equal "author", approval.fetch("origin")
    assert_not_nil Time.iso8601(approval.fetch("decided_at"))
    assert_not approval.key?("decided_by"), "an author grant names nobody: authored_by already says who"
    assert_equal %w[decided_at origin], approval.keys.sort
  end

  test "a hold narrates the status and the call to act, with the blocked keys" do
    agent_loop = seed(model("brittle"))
    start!(agent_loop)

    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.agent_loop_id == agent_loop.id
    end
    apply_via(admitted.attempt, json_response(400, { "error" => "bad" }))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)

    round = items(agent_loop).select { |item| item.item_type == "round_result" }.sole.payload
    assert_equal "provider_http_error", round.fetch("error_key")
    assert_equal "HTTP 400: bad", round.fetch("error_detail"),
      "the feed says what the provider answered, not only that it refused (12a F-5)"

    attention = items(agent_loop).select { |item| item.item_type == "attention_required" }.sole
    assert_equal "halt_failure", attention.payload.fetch("reason")
    assert_equal ["brittle"], attention.payload.fetch("blocked_task_keys")
    assert_not attention.payload.key?("expires_at"),
      "the ask has no clock - it names the reason and the work, not a deadline"
    held = items(agent_loop).select { |i| i.item_type == "turn_status" }.last.payload
    assert_equal "needs_attention", held.fetch("loop_status")
    assert_equal "failed", held.fetch("status"), "a hold is a failed turn"
    assert_equal "halt_failure", held.fetch("failure_reason_key")
  end

  test "a loop-backed loop narrates on its conversation, naming its turn and never its status" do
    conversation = conversation!
    seam = create_loop_backed_turn(conversation: conversation, acting_user: @human)
    appended = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.authored(
      agent_loop: seam.agent_loop, steps: [model("only")]
    ))
    assert_predicate appended, :applied?
    AgentLoops::Transition.agent_loop(seam.agent_loop, status: "paused", paused_at: Time.current)

    assert_empty seam.agent_loop.conversation_event_items,
      "a loop-backed loop hosts nothing of its own"
    assert_equal %w[task_status turn_status], types(conversation)
    rendered = ConversationEventItem::PublicProjection.render(items(conversation).first)
    assert_equal({ type: "conversation", public_id: conversation.public_id }, rendered[:resource])

    status = items(conversation).last.payload
    assert_equal seam.turn.public_id, status.fetch("turn_public_id")
    assert_equal seam.agent_loop.public_id, status.fetch("agent_loop_public_id")
    assert_equal "paused", status.fetch("loop_status")
    assert_equal "direct_reply", status.fetch("turn_kind"),
      "and the turn's kind, so a follower tells a summary's loop from a reply's (2026-09-18)"
    assert_not status.key?("status"),
      "under the loop lock the turn's row is unknown; only settle says where the turn is"
    assert_not status.key?("failure_reason_key")
  end

  test "the flush groups by host: two loops on one conversation land as one envelope" do
    conversation = conversation!
    # A settled first turn, so the second can land at the top of the timeline.
    first = create_loop_backed_turn(conversation: conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed")
    second = create_loop_backed_turn(conversation: conversation, acting_user: @human)
    before = conversation.conversation_events.count

    ApplicationRecord.transaction do
      AgentLoops::Transition.agent_loop(first.agent_loop, status: "paused", paused_at: Time.current)
      AgentLoops::Transition.agent_loop(second.agent_loop, status: "paused", paused_at: Time.current)
    end

    assert_equal before + 1, conversation.conversation_events.count,
      "one transaction, one host, one envelope"
    envelope = conversation.conversation_events.order(:id).last
    assert_equal [first.agent_loop.public_id, second.agent_loop.public_id],
      envelope.conversation_event_items.order(:sequence).map { |i| i.payload.fetch("agent_loop_public_id") }
    assert_equal (1..items(conversation).length).to_a, items(conversation).map(&:sequence)
  end

  test "a loop is born with its cursor, and a whole run never needs the backstop" do
    agent_loop = seed(model("only"))

    cursor = agent_loop.conversation_event_cursor
    assert_not_nil cursor, "one row per host aggregate, at create"
    assert_equal agent_loop.account_id, cursor.account_id
    assert_equal 2, cursor.next_sequence, "the seed batch's one item already allocated"
    assert_equal 1, ConversationEventCursor.where(host: agent_loop).count
  end

  test "no item ever carries an engine identifier" do
    agent_loop = seed(model("a"), parallel(tool("t1"), tool("t2"), until: "any", key: "j"), model("b"))
    start!(agent_loop)
    run_step!(agent_loop)

    forbidden = %w[node_id remaining_dependencies execution_generation
                   agent_loop_node_id selected_model_invocation_id]
    items(agent_loop).each do |item|
      rendered = ConversationEventItem::PublicProjection.render(item).to_json
      forbidden.each do |key|
        assert_not_includes rendered, key, "#{item.item_type} leaked #{key}"
      end
      assert_match(/\A[0-9a-f-]{36}\z/, item.public_id)
    end
  end

  test "the append is idempotent under its key and never partially writes" do
    agent_loop = seed(model("only"))
    before = items(agent_loop).length

    ConversationEvent::Append.call(
      host: agent_loop, idempotency_key: "same",
      items: [{ type: "turn_status", payload: { "loop_status" => "running" } }]
    )
    ConversationEvent::Append.call(
      host: agent_loop, idempotency_key: "same",
      items: [{ type: "turn_status", payload: { "loop_status" => "running" } },
              { type: "turn_status", payload: { "loop_status" => "paused" } }]
    )

    assert_equal before + 1, items(agent_loop).length,
      "the replay returns the standing envelope and writes nothing more"
  end

  test "one plane, one replay prefix: a loop item's cursor is the conversation stream's" do
    agent_loop = seed(model("only"))

    rendered = ConversationEventItem::PublicProjection.render(items(agent_loop).sole)
    assert_equal({ type: "agent_loop", public_id: agent_loop.public_id }, rendered[:resource])
    assert_equal 1, ConversationEventItem::ReplayCursor.decode(rendered[:cursor])
    assert_equal 0, ConversationEventItem::ReplayCursor.decode(nil),
      "a blank cursor is the start of the stream, not an error"
  end

  test "lifecycle items go out twice and stream items once, on the loop's own channel" do
    agent_loop = seed(model("only"))
    channels = []
    ActionCable.server.stub(:broadcast, ->(channel, _payload) { channels << channel }) do
      ConversationEvent::Append.call(
        host: agent_loop,
        items: [{ type: "turn_status", payload: { "loop_status" => "running" } },
                { type: "task_status", payload: { "task_key" => "only" } },
                { type: "attention_required", payload: { "reason" => "halt_failure" } }]
      )
    end

    base = "agent_api:v1:agent_loop:#{agent_loop.public_id}"
    assert_equal ["#{base}:events", "#{base}:lifecycle", "#{base}:events",
                  "#{base}:events", "#{base}:lifecycle"], channels,
      "where the loop IS, and the one call to act, also reach the lifecycle feed; " \
      "a task transition does not"
  end

  test "one transaction narrates ONE envelope, and the cursor is its last lock" do
    agent_loop = seed(
      tool("probe", "shell"),
      model("after-it"),
    )
    start!(agent_loop)

    # The scheduling pass failed the tool task AND minted a model step: the
    # inversion the buffer exists to prevent (narrate, then seal a request
    # body) — both narrations land in one envelope written at the end.
    envelopes = agent_loop.conversation_events.count
    assert_equal 3, envelopes, "create, start, and the whole schedule pass"
    pass = agent_loop.conversation_events.order(:id).last
    assert_operator pass.conversation_event_items.count, :>=, 2,
      "the failed tool and the started model ride the same envelope"
    assert_equal (1..items(agent_loop).length).to_a, items(agent_loop).map(&:sequence)
  end

  test "narration inside a rolled-back append writes nothing" do
    agent_loop = seed(model("seed"))
    before = items(agent_loop).length

    agent_loop.agent_loop_nodes.find_by!(node_key: "seed").update_columns(status: "completed", completed_at: Time.current)
    refused = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.authored(
      agent_loop: agent_loop, steps: [tool("fresh"), model("seed")]
    ))
    assert_equal :duplicate_task_key, refused.outcome

    assert_equal before, items(agent_loop).length,
      "the savepoint took its own narration down with it"
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "fresh")
  end

  test "the one reaper ages a loop's items out and leaves the trace standing" do
    agent_loop = seed(model("only"))
    ConversationEventItem.where(host: agent_loop).update_all(created_at: 40.days.ago)

    ConversationEventItems::ReapJob.perform_now

    assert_equal 0, items(agent_loop).length
    assert_equal 1, agent_loop.agent_loop_nodes.count,
      "items are replay evidence; the tasks are the durable record"
  end

  # The items keep their FK to the envelope, so the host's cascade must
  # take the envelopes (and through them the items) before the cursor —
  # a wrong order raises on the FK instead of leaving orphans.
  test "destroying the host takes envelopes first, then items and the cursor" do
    agent_loop = seed(model("only"))
    assert_operator ConversationEventItem.where(host: agent_loop).count, :>, 0

    # A fresh row, as the reaper and the collector both lock-refetch theirs.
    AgentLoops::Reap.destroy_aggregate(AgentLoop.find(agent_loop.id))

    assert_equal 0, ConversationEvent.where(host: agent_loop).count
    assert_equal 0, ConversationEventItem.where(host: agent_loop).count
    assert_equal 0, ConversationEventCursor.where(host: agent_loop).count
  end

  # `after` RIDES EVERY TASK ITEM: the authored list the trace row already shows, on the item a
  # follower actually holds — so a watcher can indent a branch under the call key it hangs from and
  # say what a waiting round waits on, without a trace read per tick.
  test "a task item names what it was authored after; a root names nothing" do
    agent_loop = seed(model("only"), model("next"))

    birth = items(agent_loop).map(&:payload)
    assert_equal %w[only next], birth.map { |payload| payload.fetch("task_key") }
    assert_not birth[0].key?("after"), "a root reads none, and an absent key is how it says so"
    assert_equal ["only"], birth[1].fetch("after")
  end

  # A BRANCH FORWARDS ONTO ITS CONSUMER: the splice adds an edge from the branch root, then from
  # every branch round, into the waiting round. No status moves, so without a word here the
  # follower's `after` would stay at birth — the fan — and its derived `waiting_on` would go empty
  # the moment the `task` call settled. The consumer is re-narrated at each splice, `after` grown.
  test "a consumer's item is re-narrated with its `after` grown as a branch forwards onto it" do
    agent_loop = seed(model("round1", "prompt" => "dig", "tools" => [Nexus::Tools::TASK, READ_FILE]))
    start!(agent_loop)
    fan!(agent_loop, "round1", ["task", { prompt: "dig in", wait: true }])

    assert_equal [%w[r1t0], %w[r1t0 r1t0-model-1]], afters_of(agent_loop, "r1"),
      "birth names the fan; the splice names the branch root too"
    assert_equal %w[waiting waiting], task_items(agent_loop, "r1").map { |payload| payload.fetch("status") },
      "the consumer did not move — only what it waits on did"
    assert_equal [%w[r1t0]], afters_of(agent_loop, "r1t0-model-1").uniq,
      "the root hangs from the call, on every one of its status items"

    fan!(agent_loop, "r1t0-model-1", ["read_file", { path: "a" }])

    assert_equal %w[r1t0 r1t0-model-1 r2], afters_of(agent_loop, "r1").last,
      "each branch round's splice grows the consumer's `after` by that round"
    assert_equal [%w[r1t0-model-1]], afters_of(agent_loop, "r2t0").uniq
    assert_equal [%w[r2t0]], afters_of(agent_loop, "r2").uniq,
      "a branch round hangs from its fan, as a spine round does"
  end

  READ_FILE = { "type" => "function",
                "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }.freeze

  def task_items(agent_loop, key)
    items(agent_loop).select { |item| item.item_type == "task_status" && item.payload["task_key"] == key }
      .map(&:payload)
  end

  def afters_of(agent_loop, key) = task_items(agent_loop, key).map { |payload| payload["after"] }

  # The running round answers with a fan of flat-tool calls and the
  # kernel's jobs run, as `branch_closure_test` drives it.
  def fan!(agent_loop, key, *calls)
    tool_calls = calls.each_with_index.map do |(name, fields), index|
      { id: "call_#{key}_#{index}", name: name, arguments: fields.to_json }
    end
    node = agent_loop.agent_loop_nodes.find_by!(node_key: key)
    ModelInvocations::AdmitQueuedWork.call
    attempt = ModelInvocationAttempt.where(model_invocation_id: node.selected_model_invocation_id).order(:id).last
    apply_via(attempt, sse_success("calling", tool_calls: tool_calls))
    AgentLoops::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    agent_loop.reload
  end
end
