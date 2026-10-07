require "test_helper"
require "cgi/escape"
require "fileutils"
require "securerandom"
require "tmpdir"
require "async"
require "support/actor_provisioning"
require "support/ceremony"
require "support/printed_envelope"
require "support/realtime_lane"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# A MULTI-TURN CONVERSATION, THROUGH A DEPLOYED SYSTEM, DRIVEN BY THE SDK.
#
# The one-shot lanes prove a single call end to end. This proves the plane
# that is not a single call: nothing here is authored directly — a caller
# enqueues an INPUT, the kernel materializes it into a TURN at a boundary,
# and the answer arrives on a timeline the caller reads back. Four
# processes have to agree for that to happen (Puma accepts, the queue
# worker drains and converges, a host executes, the cable narrates), and
# no in-process test can put them in the same room.
#
# WHAT THIS PROVES THAT NOTHING ELSE DOES:
#   - the SDK's conversation surface against the real wire, top to bottom:
#     create, enqueue, timeline, deck, feeds
#   - the QUEUE BOUNDARY: a reply materializes because a job ran in another
#     process, not because this one called a service
#   - the TRANSCRIPT FEED crossing a process boundary — the settled turn
#     published by the converger and read by a subscriber attached to Puma
#
# It deliberately does NOT assert the transcript DELTAS. Only the model
# runner narrates them and `Wake` gives neither host a tiebreaker, so with
# both running they are a coin toss — the same reason the one-shot turn
# lane does not assert which host executed it. The delta half is pinned
# in-process by `Conversations::TranscriptStreamTest`, and the cross-
# process cable itself by `InferenceRequestStreamTest`; what is left for here is
# the half that is deterministic and that only a deployment can show.
class ConversationTurnTest < Minitest::Test
  include E2E::RealtimeLane

  MODEL = "dev/mock-text".freeze
  TURN_TIMEOUT = 60
  # 120 requests a minute per identity, and a journey that polls faster
  # than that gets 429s of its own making.
  POLL = 1.0
  # THE rho ROW'S PADDING (the between-turn compaction through `rho say`):
  # a message turn of this many hex bytes is 8 000 characters, 2 000
  # tokens as the kernel prices a turn since the last reading
  # (`ContextAssembly::FillCost`, four bytes to the token with no exact
  # counter; the fake's own usage prices the opening turn the same way);
  # five of them are over the dev window (8 192, the first row's own pin)
  # whatever the opening turn cost, so the say's arrival arms the summary
  # by the kernel's own number and never by luck.
  ARMING_HEX = 4_000
  # `rho turns`' line, by its documented columns: the position, the id,
  # the role, the kind, the status, `run ID` when the turn minted one,
  # the words in quotes.
  TURN_LINE = /\A\s*(?<position>\d+)\s{2}(?<id>\S+)\s{2}(?<role>\S+)\s{2}(?<kind>\S+)\s{2}(?<status>\S+)(?:\s{2}run (?<run>\S+))?(?:\s{2}"(?<words>.*)")?\z/
  LOG_TAIL_LINES = 80

  def setup
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    E2E.hosts.start
    @workspace = @client.workspaces.create(
      name: "Conversation #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    )
    @conversations = @client.workspace(@workspace.public_id).conversations
  end

  # Only the rho row boots a daemon; the rest of the file has none to stop.
  def teardown
    return if @daemon.nil?

    unless passed?
      warn_log(@daemon.log_path, "rho daemon stdout")
      warn_log(File.join(@rho_home, "log", "rho.log"), "rho structured log")
    end
  rescue StandardError => error
    warn "Could not capture rho diagnostics: #{error.class}: #{error.message}"
  ensure
    if (result = @daemon&.dispose_connection)
      output, status = result
      assert_predicate status, :success?, "rho disconnect failed during cleanup:\n#{output}"
    end
    [@rho_home, @project].compact.each { |dir| FileUtils.rm_rf(dir) }
  end

  def test_a_person_holds_a_conversation_and_the_deployment_answers
    response = nil
    transport = CybrosAgent::HttpTransport.new(base_url: @base_url)
    client = CybrosAgent::Client.new(
      base_url: @base_url, credential: @actor.member_token,
      transport: ->(path, **options) { response = transport.call(path, **options) }
    )
    conversations = client.workspace(@workspace.public_id).conversations
    create_key = SecureRandom.uuid
    created = conversations.create(title: "Deployment check", idempotency_key: create_key)
    assert_equal 201, response.status
    refute_predicate created, :replayed?, "a fresh key is new work, not a receipt"
    replayed = conversations.create(title: "Deployment check", idempotency_key: create_key)
    assert_equal 201, response.status, "receipt replay preserves the creation status"
    assert_predicate replayed, :replayed?
    assert_equal created.public_id, replayed.public_id
    chat = conversations.conversation(created.public_id)

    conversation = chat.fetch
    assert_equal "Deployment check", conversation.title
    refute_predicate conversation, :busy?
    assert_equal 0, conversation.input_queue.held
    assert_nil conversation.context, "no turn has settled, so there is no honest occupancy yet"
    assert_equal 0, conversation.usage_summary.request_count
    assert_equal 0, conversation.usage_summary.total_tokens
    assert_equal "0.0", conversation.usage_summary.cost_amount
    assert conversation.usage_summary.cost_complete

    # WHAT IT WOULD COST, before it costs anything. Assembly is kernel-side,
    # so this is the only way a caller can see the size of what it is about
    # to send.
    estimate = chat.estimate_input(model: MODEL, prompt: "say hi")
    assert_operator estimate.input_tokens, :>, 0
    assert_predicate estimate, :tokenizer_exact?
    assert_equal 0, estimate.history.selected, "an empty timeline has no history to carry"

    # TWO ROWS INTO THE WAITING ROOM. Neither is a turn yet: the queue
    # drains in another process, and that indirection is the whole
    # concurrency story of this plane.
    said = chat.inputs.create(text: "remember the number 41", idempotency_key: SecureRandom.uuid)
    assert_equal 0, said.queue_position
    reply_input = {
      kind: "direct_reply", model: MODEL, text: "what number did I ask you to remember",
      idempotency_key: SecureRandom.uuid,
    }
    asked = chat.inputs.create(**reply_input)
    accepted_body = response.body
    assert_equal 202, response.status
    refute_predicate asked, :replayed?
    assert_equal "pending", asked.state
    refute_predicate asked, :blocked?

    # NOTHING IN THIS PROCESS DRAINS IT. Reaching a settled reply at all is
    # the assertion: a job ran elsewhere, a host claimed the work, and the
    # converger walked it back onto the timeline.
    page = await_settled_reply(chat)
    reply = page.items.last
    assert_equal "direct_reply", reply.kind
    assert_equal "assistant", reply.role
    assert_equal "completed", reply.status
    # THE ANSWER PROVES ASSEMBLY, not just delivery. The mock echoes what
    # it was sent, and what it was sent is the TIMELINE plus the prompt —
    # merged into one user message, because adjacent same-role segments
    # join before the wire. So this one string is the evidence that the
    # kernel compiled history the caller never had to assemble.
    assert reply.text.start_with?("Mock: "),
      "the answer must be the one the fake provider composed, over the wire"
    assert_includes reply.text, "remember the number 41",
      "the earlier turn rode the request — the kernel assembled it, the caller did not"
    assert_includes reply.text, "what number did I ask you to remember",
      "and so did the prompt"
    assert_equal "dev", reply.active_variant.model.provider_id
    assert_predicate reply.active_variant, :active?

    said_turn = page.items.first
    assert_equal "message", said_turn.kind
    assert_equal "remember the number 41", said_turn.text
    refute_predicate said_turn, :inherited?

    # A retry still recovers its original acceptance after the input was consumed.
    replayed_input = chat.inputs.create(**reply_input)
    assert_equal 202, response.status, "receipt replay preserves the acceptance status"
    assert_predicate replayed_input, :replayed?
    assert_equal asked.public_id, replayed_input.public_id
    assert_equal accepted_body, response.body

    # The queue emptied by draining, not by being cleared.
    assert_equal 0, chat.inputs.list.length
    assert_equal 2, chat.turns.list.length, "replaying a consumed input creates no extra turn"
    settled = chat.fetch
    refute_predicate settled, :busy?, "the lane released when the reply settled"
    # OCCUPANCY IS PROVIDER TRUTH, never a local re-count — so the numbers
    # are asserted as facts about the path (a receipt exists, it names the
    # model that answered, it sits against that model's real window) and
    # not as a fixture's arithmetic this journey does not control.
    refute_nil settled.context, "a settled turn reports provider-counted occupancy"
    assert_operator settled.context.input_tokens, :>, 0
    assert_equal "dev", settled.context.as_of_model.provider_id
    assert_equal "mock-text", settled.context.as_of_model.model_ref
    assert_equal 8192, settled.context.window_tokens
    assert_equal 1, settled.usage_summary.request_count,
      "replaying a consumed input does not count another model attempt"
    assert_equal settled.context.input_tokens, settled.usage_summary.input_tokens
    assert_equal settled.context.output_tokens, settled.usage_summary.output_tokens
    assert_equal settled.context.used_tokens, settled.usage_summary.total_tokens
    assert_operator settled.context_revision, :>=, 2

    # THE REPLAY WINDOW a follower resumes from, and the lifecycle story it
    # tells: the reply was created, ran, and completed.
    events = chat.events
    assert_operator events.watermark, :>, 0
    statuses = events.select { |item| item.type == "turn_status" }
      .map { |item| item.payload.fetch("status") }
    assert_equal %w[running completed], statuses.last(2),
      "the durable stream tells the whole run story"
  end

  # COMPACTION, THROUGH A DEPLOYMENT. The in-process test proves the
  # repair; only a deployed run proves the LOOP it steps into — the head
  # keeps its place, the summary turn settles in another process, the
  # converger drains the lane again without anyone asking, and the reply
  # goes out against a history that now begins at the summary. Nothing in
  # this process does any of that.
  #
  # The wall is reached the way a caller actually reaches it: by claiming the whole window for
  # history. The kernel's own default self-trims and never walls.
  #
  # THE SUMMARY IS SCRIPTED SHORT, because the fake echoes and a summarizer is the one request an
  # echo can prove nothing about: the kernel fits the summarizer's material to its model's window,
  # so an echoed "summary" is by construction as large as the history it stands in for, and the
  # retry could never fit behind it. The newest history turn carries the script; it is the LAST
  # `!mock` line of the summarizer's request and of nothing else (the greedy prompt carries its own,
  # and the summary replaces the turn).
  def test_a_context_that_will_not_fit_is_repaired_and_the_reply_goes_out
    chat = @conversations.conversation(
      @conversations.create(idempotency_key: SecureRandom.uuid).public_id
    )
    5.times do |n|
      script = n == 4 ? "!mock reply=#{CGI.escape("THE SUMMARY")} -- " : ""
      chat.inputs.create(text: "#{script}turn#{n} #{SecureRandom.hex(2_000)}",
                         idempotency_key: SecureRandom.uuid)
    end
    await("five materialized turns") do
      page = chat.turns.list
      page if page.length == 5
    end

    greedy = chat.inputs.create(
      kind: "direct_reply", model: MODEL, text: "!mock -- and now #{SecureRandom.hex(1_500)}",
      history: { "token_budget_share" => 1.0 }, idempotency_key: SecureRandom.uuid
    )

    summary = await("a summary turn") do
      chat.turns.list.items.find { |turn| turn.compaction_summary? }
    end
    assert_equal "user", summary.role, "a summary is material, never instruction"

    reply = await("a reply that settles behind the repair") do
      last = chat.turns.list.items.last
      last if last.kind == "direct_reply" && last.status == "completed"
    end
    assert reply.text.start_with?("Mock: ")
    assert_includes reply.text, "THE SUMMARY",
      "the reply went out AGAINST the summary: its echo carries the summary's text"
    assert_equal 1, chat.turns.list.items.count(&:compaction_summary?),
      "compacting a compaction is a loop, not a repair"

    # THE HEAD WAS REPAIRED, NEVER PARKED — the claim this whole round
    # turns on, and the durable stream is where it is provable: a blocked
    # head is a narrated fact, so its ABSENCE beside a `context_compacted`
    # is the evidence that the wall was answered rather than reported.
    types = chat.events.map(&:type)
    assert_includes types, "context_compacted"
    refute_includes types, "input_blocked"
    assert_equal 0, chat.inputs.list.length,
      "and the queue emptied because the lane drained ITSELF once the repair settled"

    # ASSEMBLY NOW BEGINS AT THE SUMMARY, and reports it as CARRIED rather
    # than lost.
    estimate = chat.estimate_input(model: MODEL, prompt: "next")
    assert_predicate estimate.history, :compacted?

    # The next compaction must read the kernel-authored summary as well
    # as the ordinary turns since it, then leave another usable cut.
    next_message = "!mock reply=#{CGI.escape("THE SECOND SUMMARY")} -- a new fact after the repair"
    chat.inputs.create(text: next_message, idempotency_key: SecureRandom.uuid)
    await("the new message after the first summary") do
      chat.turns.list.items.find { |turn| turn.kind == "message" && turn.text == next_message }
    end

    compacted = chat.compact(model: MODEL)
    refute_predicate compacted, :mid_turn?
    second_summary = await("a second completed summary") do
      turn = chat.turns.list.items.find { |item| item.public_id == compacted.turn_public_id }
      turn if turn&.status == "completed"
    end
    assert_predicate second_summary, :compaction_summary?
    assert_includes second_summary.text, "THE SECOND SUMMARY"
    assert_equal 2, chat.turns.list.items.count(&:compaction_summary?)

    chat.inputs.create(
      kind: "direct_reply", model: MODEL, text: "!mock -- continue after the second summary",
      idempotency_key: SecureRandom.uuid
    )
    continued = await("a reply using the second summary") do
      last = chat.turns.list.items.last
      last if last.kind == "direct_reply" && last.public_id != reply.public_id && last.status == "completed"
    end
    assert_includes continued.text, "THE SECOND SUMMARY"
    refute_includes continued.text, "THE SUMMARY"
    sealed = chat.turns.request(continued.public_id, continued.active_variant.public_id)
    texts = sealed.entries.flat_map { |entry| entry.fetch("parts", []) }
      .filter_map { |part| part["text"] }.join("\n")
    assert_includes texts, "THE SECOND SUMMARY"
    refute_includes texts, "THE SUMMARY", "the second summary replaces the first cut in the real request"

    # WHAT THIS LANE DELIBERATELY DOES NOT ASSERT: what the summarizer READ.
    # The summarizer's request is the kernel's — the serialized history
    # under the one INSTRUCTIONS, fitted to the model's window — and its
    # bytes, the pointer rule and the re-read frame are pinned in-process
    # by `Conversations::CompactionTest` against a history that actually
    # shrinks. What only a deployment can show is everything above: the
    # wall, the repair, the summary loop's step minted and settled in
    # another process, the converger adopting it onto the turn, and the
    # lane draining itself.
  end

  # `rho say` BEHIND A BETWEEN-TURN COMPACTION: the row above, driven through rho. The row above
  # reaches the wall with a greedy budget the SDK can state; `rho say` states none, so the arm here
  # is the kernel's OWN number (apply_next `over_usage`: the opening turn's provider-reported usage
  # plus the turns since it, priced as assembly prices them): rho opens the conversation, five
  # padded message turns ride the SDK onto its timeline — ARMING_HEX each, the newest scripting the
  # summary short exactly as above (its `!mock` line is the last of the summarizer's request, whose
  # tail never yields) — and the say's arrival arms the summary. The feed then narrates the
  # `compaction_summary` turn FIRST, and before the follower used turn_kind rho's wait answered the
  # first loop that was not the bar: `rho say` printed the SUMMARIZER's loop as `loop:` (read as
  # `k1(model_task/completed)`). The kernel's `turn_status` now carries `turn_kind`, the follower
  # reads past a summary's loop, and the printed `loop:` backs the PERSON's turn: its tasks include
  # the one scripted call, `rho turns` lists a `compaction_summary` turn immediately before it, and
  # the reply's echo carries the summary. THE PADDING RULE: the fake's clock is the tool answers in
  # the whole input; the message turns make no call and the summary replaces them, so the say's
  # script is ONE call. A say the summary outran (`pending:` with the compaction line) is NOT
  # accepted here: past rho's 30 s bound the loop path is this row's only answer, and the printed
  # text is what flunks it (the step-1 rule — a word queued behind a turn in flight answers pending
  # — is the port rows'; here the lane is idle when the word arrives).
  def test_rho_say_behind_a_between_turn_compaction_names_the_persons_loop_never_the_summarizers
    boot_rho!
    seed = "seed #{SecureRandom.hex(4)}"
    File.write(File.join(@project, "seed.txt"), "#{seed}\n", encoding: Encoding::UTF_8)
    conversation, first_loop = rho_open("!mock -- the conversation opens")
    await_rho_loop(first_loop, "completed")
    await_follower(conversation, loop: first_loop)

    chat = steward_conversation(conversation)
    5.times do |n|
      script = n == 4 ? "!mock reply=#{CGI.escape("THE SUMMARY")} -- " : ""
      chat.inputs.create(text: "#{script}turn#{n} #{SecureRandom.hex(ARMING_HEX)}",
                         idempotency_key: SecureRandom.uuid)
    end
    await("the five padded message turns behind rho's opening turn") do
      page = chat.turns.list
      page if page.length == 6
    end

    said, status = @daemon.cli("say", conversation,
      "!mock tool_call=read:#{CGI.escape(JSON.generate("path" => "seed.txt"))} -- read the seed")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    loop_id = said[/^run:\s+(\S+)/, 1]
    refute_nil loop_id, "rho say printed no loop: the person's turn is this row's only answer, a summary that " \
      "outran the bound (`pending:` with the compaction line) is not accepted here:\n#{said}"

    row = await_rho_loop(loop_id, "completed")
    read = row.tasks.find { |task| task.tool_name == "read" }
    refute_nil read, "the printed loop never called read — a summary loop is k1(model_task) alone: " \
      "#{row.tasks.map { |task| "#{task.key}(#{task.kind}/#{task.status})" }.join(" ")}"
    assert_equal "completed", read.status, read.to_h.inspect
    detail = rho_loops.run(loop_id).task(read.key)
    assert_includes [detail.output, *Array(detail.content).map { |block| block["text"] }].compact.join, seed,
      "the call ran on the person's turn, under the bound root"

    listed, status = @daemon.cli("turns", conversation)
    assert_predicate status, :success?, "rho turns failed:\n#{listed}"
    rows = turn_rows(listed)
    index = rows.index { |turn| turn[:run] == loop_id }
    refute_nil index, "rho turns never listed the printed loop's turn:\n#{listed}"
    assert_operator index, :>, 0, listed
    assert_equal "direct_reply", rows[index][:kind], listed
    summary = rows[index - 1]
    assert_equal %w[user compaction_summary completed], summary.values_at(:role, :kind, :status),
      "a compaction_summary turn immediately before the person's:\n#{listed}"
    refute_equal summary[:run], loop_id, "the summary's run is never the printed one:\n#{listed}"
    assert_includes summary[:words].to_s, "THE SUMMARY", "the scripted summary, spoken short:\n#{listed}"
    assert_equal 1, rows.count { |turn| turn[:kind] == "compaction_summary" },
      "compacting a compaction is a loop, not a repair:\n#{listed}"

    reply = await("the reply that settles behind the repair") do
      last = chat.turns.list.items.last
      last if last.kind == "direct_reply" && last.status == "completed"
    end
    assert_equal loop_id, reply.active_variant.run_public_id, "the timeline's last turn is the printed loop's"
    assert_includes reply.text, "THE SUMMARY", "the reply went out AGAINST the summary: its echo carries it"

    # WHAT LET rho ANSWER: the kernel names the kind on the summary's
    # `turn_status` and on the person's, on the durable stream a follower
    # reads — the one fact the wait reads past a summary's loop by.
    kinds = chat.events.select { |item| item.type == "turn_status" }
      .map { |item| [item.payload["run_public_id"], item.payload["turn_kind"]] }.uniq
    assert_includes kinds, [summary[:run], "compaction_summary"], kinds.inspect
    assert_includes kinds, [loop_id, "direct_reply"], kinds.inspect
  end

  def test_rho_say_names_its_own_turn_when_an_older_blocked_input_is_repaired
    boot_rho!
    conversation, first_loop = rho_open("!mock -- the conversation opens")
    await_rho_loop(first_loop, "completed")
    await_follower(conversation, loop: first_loop)
    chat = steward_conversation(conversation)

    arguments = CGI.escape(JSON.generate("command" => "sleep 5"))
    head = chat.inputs.create(kind: "direct_reply", model: "dev/no-such-model",
      text: "!mock tool_call=bash tool_args=#{arguments} -- the older request",
      delivery_mode: "queue", idempotency_key: SecureRandom.uuid)
    blocked = await("the older input to block on its unknown model") do
      row = chat.inputs.list.items.find { |input| input.public_id == head.public_id }
      row if row&.blocked?
    end
    assert_equal "unknown_model", blocked.blocked_reason

    words = "!mock reply=the-new-answer -- the new request #{SecureRandom.hex(4)}"
    caller = Thread.new { @daemon.cli("say", conversation, words, "--mode", "queue") }
    tail = await("rho's input to queue behind the blocked head") do
      chat.inputs.list.items.find { |input| input.text == words }
    end
    assert_equal [head.public_id, tail.public_id], chat.inputs.list.items.map(&:public_id)

    # A second sender repairs their older request while rho awaits its
    # own. The ordinary shell call keeps that older turn visible long
    # enough for the follower to read it before the queued input runs.
    chat.inputs.update(head.public_id, model: MODEL)
    assert caller.join(TURN_TIMEOUT), "rho say did not return within #{TURN_TIMEOUT} seconds"
    said, status = caller.value
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    assert_equal tail.public_id, said[/^queued:\s+(\S+)/, 1], said

    landed = await("both inputs to materialize on the public feed") do
      events = chat.events(limit: 200).items.select { |event| event.type == "input_materialized" }
      own = events.find { |event| event.payload["input_public_id"] == tail.public_id }
      events if own
    end
    older = landed.find { |event| event.payload["input_public_id"] == head.public_id }.payload
    own = landed.find { |event| event.payload["input_public_id"] == tail.public_id }.payload
    own_turn = chat.turns.list.items.find { |turn| turn.public_id == own.fetch("turn_public_id") }
    own_loop = own_turn.active_variant.run_public_id
    await_rho_loop(own_loop, "completed")
    assert_equal own.fetch("turn_public_id"), said[/^turn:\s+(\S+)/, 1],
      "rho must name its own input's turn, not the repaired head's #{older.inspect}:\n#{said}"
    assert_equal own_loop, said[/^run:\s+(\S+)/, 1],
      "rho must name its own input's loop:\n#{said}"
  ensure
    caller&.join(TURN_TIMEOUT)
  end

  def test_reused_task_keys_keep_each_turns_branch_result_in_later_history
    boot_rho!
    first_args = CGI.escape(JSON.generate("prompt" => "!mock reply=first-result -- first branch", "wait" => true))
    conversation, first_loop = rho_open("!mock reply=first-delivered tool_call=delegate_task:#{first_args} -- first")
    first = await_rho_loop(first_loop, "completed")
    await_follower(conversation, loop: first_loop)

    second_args = CGI.escape(JSON.generate("prompt" => "!mock reply=second-result -- second branch", "wait" => true))
    # The fake's clock includes the first turn's one tool result.
    said, status = @daemon.cli("say", conversation,
      "!mock reply=second-delivered tool_call=delegate_task:#{second_args},delegate_task:#{second_args} -- second")
    assert_predicate status, :success?, said
    second_loop = said[/^run:\s+(\S+)/, 1]
    refute_nil second_loop, said
    second = await_rho_loop(second_loop, "completed")
    await_follower(conversation, loop: second_loop)
    assert_equal ["r2t0", "r2t0"], [first, second].map { |row| row.tasks.find { |task| task.tool_name == "delegate_task" }&.key }

    said, status = @daemon.cli("say", conversation, "!mock reply=remembered -- recall both branches")
    assert_predicate status, :success?, said
    third_loop = said[/^run:\s+(\S+)/, 1]
    refute_nil third_loop, said
    await_rho_loop(third_loop, "completed")
    request = @steward_client.workspace(@rho_workspace)
      .run_task(run_public_id: third_loop, task_key: "r1").request
    results = request.entries.filter_map do |entry|
      entry.dig("payload", "output") if entry["type"] == "tool_result_item"
    end
    assert_equal 2, results.length
    assert_includes results.first, "Mock: first-result"
    refute_includes results.first, "Mock: second-result"
    assert_includes results.last, "Mock: second-result"
    refute_includes results.last, "Mock: first-result"
  end

  # THE WAITING ROOM'S STEER, through a deployment. A steer is a redirect and needs something to
  # redirect: with the lane IDLE the kernel falls back to the queue — the words are still worth
  # delivering — and they ride the timeline as a message the next reply reads. With a reply in
  # flight the row binds `steering` to that turn and, when the reply settles, is RELEASED to the
  # queue (`input_edited{reason: steer_target_settled}`) rather than dropped. The mock's slow
  # ceiling is 0.2s, so the in-flight half is attempted rather than arranged: whichever state the
  # row got, the words are delivered, the release is narrated when there was a binding, and the
  # queue empties.
  def test_a_steer_is_never_lost_whichever_state_it_got
    chat = @conversations.conversation(
      @conversations.create(idempotency_key: SecureRandom.uuid).public_id
    )

    idle = chat.inputs.create(text: "the number is 41", delivery_mode: "steer",
                              idempotency_key: SecureRandom.uuid)
    assert_equal "pending", idle.state, "an idle lane has nothing to redirect, so the words queue"
    await("the idle steer as a message turn") do
      page = chat.turns.list
      page if page.items.any? { |turn| turn.kind == "message" && turn.text == "the number is 41" }
    end

    chat.inputs.create(
      kind: "direct_reply", model: MODEL, text: "!mock slow=0.2 -- what number did I give you",
      idempotency_key: SecureRandom.uuid
    )
    mid_flight = chat.inputs.create(text: "and say please", delivery_mode: "steer",
                                    idempotency_key: SecureRandom.uuid)
    assert_includes %w[steering pending], mid_flight.state

    reply = await("the reply to settle") do
      chat.turns.list.items.find { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
    end
    assert_includes reply.text, "the number is 41", "the idle steer rode the timeline into the reply"
    await("the mid-flight steer delivered as a message turn") do
      page = chat.turns.list
      page if page.items.any? { |turn| turn.kind == "message" && turn.text == "and say please" }
    end
    assert_equal 0, chat.inputs.list.length, "nothing stranded: every steer left the waiting room"

    events = chat.events
    accepted = events.select { |item| item.type == "input_accepted" && item.payload["delivery_mode"] == "steer" }
    assert_equal [idle.public_id, mid_flight.public_id], accepted.map { |item| item.payload["input_public_id"] }
    return if mid_flight.state != "steering"

    released = events.find do |item|
      item.type == "input_edited" && item.payload["input_public_id"] == mid_flight.public_id
    end
    refute_nil released, "a bound steer the reply outran is released, never dropped"
    assert_equal %w[pending steer_target_settled], [released.payload["state"], released.payload["reason"]]
  end

  # THE TRANSCRIPT FEED, cross-process: the converger runs in the queue
  # worker and publishes the settled turn; a subscriber attached to Puma
  # reads it. Nothing on this feed is durable, so arriving at all is the
  # fact — and it arrives carrying the same projection a timeline page
  # serves, which is what makes "completion wins" an event rather than a
  # rule every client re-implements.
  def test_a_subscriber_watches_the_turn_settle_from_another_process
    chat = @conversations.conversation(
      @conversations.create(idempotency_key: SecureRandom.uuid).public_id
    )

    with_reactor do
      subscription = subscribe_to_transcript(chat.public_id)

      chat.inputs.create(
        kind: "direct_reply", model: MODEL, text: "!mock -- narrate me",
        idempotency_key: SecureRandom.uuid
      )

      settled = drain_until(subscription, "turn", timeout: TURN_TIMEOUT).last
      refute_nil settled, "the settled turn never crossed the process boundary"
      assert_equal "turn", settled.fetch("type")
      # ONE ROUTING KEY for every item on this feed, deltas included, so a
      # follower never has to reach into a payload whose shape depends on
      # the type it is trying to identify.
      assert_equal settled.dig("turn", "public_id"), settled.fetch("turn_public_id")
      assert_equal "completed", settled.dig("turn", "status")
      assert_equal "Mock: narrate me", settled.dig("turn", "active_variant", "content")
    end
  end

  private

    # A 429 IS A BUG IN THIS HARNESS, not weather to be waited out: these
    # lanes poll one resource at 1Hz against a 120/minute budget.
    def throttled!(throttle)
      flunk("the journey tripped the API's own rate limit (Retry-After #{throttle.retry_after}s) — " \
            "a lane that polls faster than a consumer should is testing the wrong thing")
    end

    def await_settled_reply(chat)
      await("a reply that settles") do
        page = chat.turns.list
        last = page.items.last
        page if last&.kind == "direct_reply" && last.status == "completed"
      end
    end

    def await_full_deck(chat, turn_public_id)
      await("a second sample in the deck") do
        deck = chat.turns.variants(turn_public_id)
        if deck.items.any? { |variant| %w[failed canceled].include?(variant.status) }
          flunk("regeneration ended without a completed sample: #{deck.items.map(&:status).inspect}")
        end
        deck if deck.length > 1 && deck.items.all? { |v| v.status == "completed" }
      end
    end

    def await(what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      loop do
        result = begin
          yield
        rescue CybrosAgent::Api::RateLimited => throttle
          throttled!(throttle)
        end
        return result if result
        flunk("the deployment never reached #{what}") if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end

    # ---- the rho row's plumbing (the conversation lane's, for one row) ----

    # ONE rho FOR THE ONE ROW THAT TYPES A VERB: the steward's shared
    # browser (E2E::StewardSession) signs the daemon's ceremony, the
    # daemon adopts the steward's workspace, and the project lives beside
    # the home, never under it (a protected root). The bare home gets the
    # dev set from the harness's own write.
    def boot_rho!(settings: {}, extensions: [])
      steward = E2E::ActorProvisioning.world(@base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: @base_url, human: steward)
      @rho_home = Dir.mktmpdir("conversation-turn-rho")
      @project = File.realpath(Dir.mktmpdir("conversation-turn-project"))
      plugins = settings.fetch("plugins", {}).dup
      unless extensions.empty?
        directory = File.join(@rho_home, "extensions")
        FileUtils.mkdir_p(directory)
        extensions.each do |path|
          description = path.sub(/\.rb\z/, ".json")
          id = JSON.parse(File.read(description)).fetch("id")
          FileUtils.cp([path, description], directory)
          plugins[id] = { "enabled" => true,
            "source" => { "kind" => "path", "path" => File.join(directory, File.basename(path)) } }
        end
      end
      File.write(File.join(@rho_home, "settings.json"),
        JSON.generate(E2E::RhoDaemon.dev_settings(plugins: plugins, **settings.except("plugins"))), perm: 0o600)
      @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @rho_home)
      @daemon.start
      E2E::Ceremony.confirm(actor: actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      @rho_workspace = @daemon.await("the daemon never reported workspace adopted") do
        workspace = @daemon.status["workspace"]
        flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == "adopted" ? workspace.fetch("public_id") : nil
      end
      @steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: steward.member_token)
    end

    # `rho do` on the bound project; answers the conversation and its loop.
    def rho_open(prompt, *options)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", @project, *options)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed no conversation or loop:\n#{output}"
      ids
    end

    # The code task publishes the acceptance mapping. Authored keys are local to the batch;
    # public task keys remain opaque and are read from that receipt.
    def background_code(steps, lifetime: "conversation", wake: "auto")
      input = JSON.generate("steps" => steps, "lifetime" => lifetime, "wake" => wake)
      CGI.escape(JSON.generate("code" => "const placed = await nexus.background(#{input}); return placed.structured_content.keys;"))
    end

    def background_task(context, name)
      parent = context.fetch.tasks.find { |task| task.tool_name == "code" && task.status == "completed" }
      return unless parent

      key = context.task(parent.key).structured_content.fetch(name)
      context.fetch.tasks.find { |task| task.key == key }
    end

    def result_dag_tasks(context, selectors)
      parents = context.fetch.tasks.select { |task| task.tool_name == "code" }.map(&:key)
      details = context.graph.nodes.select { |node| parents.include?(node.expansion_parent) }
        .map { |node| context.task(node.key) }
      selectors.to_h do |name, text|
        detail = details.find { |item| item.prompt == text || item.tool_input&.fetch("command", nil) == text }
        [name, detail&.task]
      end
    end

    # The steward's own view of a conversation rho opened, and of the
    # loops in rho's adopted workspace.
    def steward_conversation(public_id) = @steward_client.workspace(@rho_workspace).conversation(public_id)

    def rho_loops = @steward_client.workspace(@rho_workspace).runs

    def rho_runner_route = { "kind" => "runner", "runner_executor_public_id" => @daemon.status.fetch("identity").fetch("runner_executor_public_id") }

    def await_rho_loop(loop_id, wanted)
      await("loop #{loop_id} at #{wanted}") do
        row = rho_loops.fetch(loop_id)
        flunk "the loop #{loop_id} halted: #{row.failure_reason.inspect}" if row.status == "failed"
        row if row.status == wanted
      end
    end

    # The daemon's own follower row (`GET /followers`) once it has read the
    # turn's completed on `loop`: a say before that would queue behind a
    # turn the follower still holds in flight and answer `pending`.
    def await_follower(conversation, loop:)
      await("rho's follower reading the turn's completed on loop #{loop}") do
        row = @daemon.control(:get, "/followers").fetch("followers").find { |candidate| candidate.fetch("public_id") == conversation }
        row if row && row["run_public_id"] == loop && row["complete"]
      end
    end

    # `rho turns`' lines as rows, by TURN_LINE's columns.
    def turn_rows(listed)
      rows = listed.lines.filter_map { |line| TURN_LINE.match(line.chomp) }
      refute_empty rows, "rho turns printed no turn line:\n#{listed}"
      rows.map { |match| match.named_captures.transform_keys(&:to_sym) }
    end

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
