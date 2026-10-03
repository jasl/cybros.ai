require_relative "../test_helper"
require_relative "../support/ops_harness"

# Following loops and conversations through the pushed event and transcript feeds.
class OpsFollowTest < Minitest::Test
  include RhoTest::OpsHarness

  # THE PUSHED CHANNEL, which had a live journey and no route test — the
  # exact gap that let a 500 ship on the transcript read. What matters
  # here is the refusal, the ending, and that a reader leaves nothing
  # behind on the run it was watching. The stream ends with the TURN
  # (`turn_settled?`): a conversation's follow outlives it, a reader's does not.
  def follow_request(daemon, query) = query_request("/loops/follow?#{query}", token: bearer(daemon))

  # `transcript` is a one-cell box rather than a flag: the settle landing
  # WHILE a reader is open is the property under test, so a test has to be
  # able to move it.
  def followed_run(public_id, complete:, listeners:, text: nil, transcript: [true], stopped: [false])
    run = fake_run(public_id, host: true)
    run.define_singleton_method(:snapshot) do
      row = { public_id: public_id, tasks: [] }
      row = row.merge(text: text, text_length: text.bytesize) if text
      Struct.new(:to_h, :complete).new(row, complete)
    end
    run.define_singleton_method(:turn_settled?) { complete }
    run.define_singleton_method(:stopped?) { stopped.first }
    # THE OTHER FEED'S ENDING: a settled turn whose text has
    # not settled yet is a reader that must stay open.
    run.define_singleton_method(:transcript_settled?) { transcript.first }
    run.define_singleton_method(:listen) { |&handler| listeners << handler; :token }
    run.define_singleton_method(:forget) { |_token| listeners.clear }
    run
  end

  # Draining only while a chunk is queued: reading an OPEN body with nothing
  # in it blocks, and a CLOSED one is ready forever while answering nil —
  # either way a naive drain hangs the suite rather than failing it.
  def drain(body)
    frames = +""
    while body.ready?
      chunk = body.read
      break if chunk.nil?

      frames << chunk
    end
    frames
  end

  def follow_ready(daemon, run)
    one_shot_ready(daemon)
    daemon.lineage.install_run(daemon.lineage.credentials, run)
    daemon
  end

  def test_following_a_loop_this_daemon_does_not_hold_says_to_attach_first
    daemon = boot

    response = request(daemon, :get, "/loops/follow?public_id=al-nope", token: bearer(daemon))
    assert_equal "404", response.code
    assert_equal "loop_not_followed", JSON.parse(response.body).dig("error", "code")
    assert_match(/attach/, JSON.parse(response.body).dig("error", "message"),
      "the answer has to say what to do about it")

    assert_equal "400", request(daemon, :get, "/loops/follow", token: bearer(daemon)).code
  end

  # A finished turn has nothing further to say, and a socket held open
  # until the first heartbeat makes it look like one still working.
  def test_a_settled_turn_is_handed_its_snapshot_and_an_end
    listeners = []
    daemon = follow_ready(boot, followed_run("al-1", complete: true, listeners: listeners,
      text: "what it said"))

    response = request(daemon, :get, "/loops/follow?public_id=al-1", token: bearer(daemon))

    assert_equal "200", response.code
    assert_equal "text/event-stream", response["content-type"]
    assert_includes response.body, %(event: snapshot\ndata: {"public_id":"al-1")
    # THE ACCUMULATED PARTIAL RIDES THE FRAME THE ROUTE ALREADY SENDS:
    # no new frame type, so a reader joining a reply already
    # in flight renders what was said before it arrived.
    assert_includes response.body, %("text":"what it said","text_length":12)
    assert_includes response.body, %(event: closed\ndata: {"reason":"turn_settled"})
    assert_empty listeners, "nothing may be left registered on a run nobody is watching"
  end

  # ENDING TAKES BOTH FEEDS. The events feed's terminal can
  # beat the transcript feed's settle by milliseconds, and a reader that
  # closed on the first ended before the reply reached it — `rho follow`
  # printed nothing while `rho watch` printed the whole answer. The settle's
  # own frames come through the listener, so the last word printed is the
  # one that ends the stream.
  def test_a_reader_stays_open_until_the_text_has_settled_too
    listeners = []
    settled = [false]
    daemon = follow_ready(boot, followed_run("al-1", complete: true, listeners: listeners,
      text: "half an", transcript: settled))

    response = route(daemon, "GET", "/loops/follow").call(follow_request(daemon, "public_id=al-1"))

    assert_equal 200, response.status
    assert_equal 1, listeners.length, "the events terminal alone must not end a reader"
    refute_includes drain(response.body), "event: closed"

    settled[0] = true
    listeners.first.call(Struct.new(:type, :payload).new("text_delta", { "text" => " answer" }))

    frames = drain(response.body)
    assert_includes frames, %(event: text_delta\ndata: {"text":" answer"}\n\n)
    assert_includes frames, %(event: closed\ndata: {"reason":"turn_settled"})
  end

  # A SETTLE THAT IS NOT COMING — a lost tail, a host that never streamed —
  # must not hold a terminal open: past the grace the reader ends anyway,
  # with the same word and nothing left registered on the run.
  def test_a_transcript_that_never_settles_is_ended_by_the_grace
    listeners = []
    run = followed_run("al-1", complete: true, listeners: listeners, transcript: [false])
    stream = Rho::LoopStream.new(public_id: "al-1")
    run.listen { |_event| nil }

    Rho::Extensions::Ops::LoopRoutes.send(:tend_stream, run, stream, :token, grace: 0, poll: 0)

    assert_includes drain(stream.body), %(event: closed\ndata: {"reason":"turn_settled"})
    refute_predicate stream, :open?
    assert_empty listeners, "nothing may be left registered on a run nobody is watching"
  end

  def test_an_ended_host_closes_all_its_readers_without_settling_the_turn
    listeners = []
    ended = [false]
    run = followed_run("c-1", complete: false, listeners: listeners, stopped: ended)
    daemon = follow_ready(boot, run)
    responses = []
    capturing_spawns(daemon) do |spawned|
      2.times do
        responses << route(daemon, "GET", "/loops/follow").call(follow_request(daemon, "public_id=c-1"))
      end
      ended[0] = true
      listeners.dup.each { |listener| listener.call(Struct.new(:type, :payload).new("conversation_ended", {})) }
      responses.each do |response|
        frames = drain(response.body)
        assert_includes frames, %(event: conversation_ended\n)
        assert_includes frames, %(event: closed\ndata: {"reason":"host_ended"})
        assert_nil response.body.read
      end
      spawned.each(&:call)
    end
    refute_predicate run, :turn_settled?
    assert_empty listeners
  end

  def test_a_host_lost_without_an_event_closes_the_reader_on_the_next_poll
    listeners = []
    run = followed_run("c-1", complete: false, listeners: listeners, stopped: [true])
    stream = Rho::LoopStream.new(public_id: "c-1")
    run.listen { |_event| nil }

    Rho::Extensions::Ops::LoopRoutes.send(:tend_stream, run, stream, :token, poll: 0)

    assert_includes drain(stream.body), %(event: closed\ndata: {"reason":"host_ended"})
    refute_predicate stream, :open?
    assert_empty listeners
  end

  # ---- the events terminal AHEAD of the settle ----

  FeedPage = Data.define(:items, :next_after, :watermark)
  FeedEvent = Data.define(:sequence, :cursor, :public_id, :type, :payload)

  # One scripted transcript socket whose `each` runs a hook BETWEEN two
  # items: the interleaving under test is "a delta streamed, then the
  # events feed's terminal and a reader joining, then the settle", and a
  # socket that yields everything at once cannot put the other pump in
  # the middle.
  class InterleavedSocket
    def initialize(before, between, after)
      @before = before
      @between = between
      @after = after
    end

    def each(&block)
      @before.each(&block)
      @between.call
      @after.each(&block)
      raise StopIteration
    end

    def unsubscribe = nil
  end

  # A conversation host's two feeds, scripted: the events feed as replay
  # pages, the transcript feed as the one socket above.
  class ScriptedHost
    def initialize(pages, socket)
      @pages = pages
      @socket = socket
    end

    def feed(realtime: nil, items: nil, **options)
      pages = @pages
      CybrosAgent::KernelFeed.new(
        replay: ->(_cursor) { pages.shift || FeedPage.new(items: [], next_after: nil, watermark: 0) }, **options
      )
    end

    def transcript(realtime:)
      socket = @socket
      -> { socket }
    end

    # The events feed is replay pages alone here: no socket is ever opened.
    def realtime_opener(_realtime, items: nil) = nil
  end

  def transcript_item(type, **payload)
    CybrosAgent::Api::TranscriptItem.new(
      type: type, turn_public_id: "t-1", variant_public_id: "v-1", agent_loop_public_id: nil,
      task_key: nil, turn: nil, payload: payload.transform_keys(&:to_s)
    )
  end

  # The settled turn as the kernel publishes it (`TranscriptStream.settled_turn`):
  # the whole sealed body on the active variant, and no reasoning body —
  # `turn_snapshot` reads the content role alone.
  def settled_turn_item(content)
    variant = CybrosAgent::Api::ConversationVariant.new(
      public_id: "v-1", source: "model", status: "completed", model: nil,
      content_preview: content[0, 8], content: content, active: true
    )
    turn = CybrosAgent::Api::ConversationTurn.new(
      public_id: "t-1", position: 1, kind: "direct_reply", role: "assistant", status: "completed",
      visibility: "visible", inherited: false, sender_conversation_public_id: nil,
      active_variant: variant, created_at: nil, answering_user_public_id: "0199-user"
    )
    CybrosAgent::Api::TranscriptItem.new(
      type: "turn", turn_public_id: "t-1", variant_public_id: nil, agent_loop_public_id: nil,
      task_key: nil, turn: turn, payload: {}
    )
  end

  def terminal_page
    FeedPage.new(items: [FeedEvent.new(sequence: 1, cursor: "c1", public_id: "e1", type: "turn_status",
      payload: { "status" => "completed", "turn_public_id" => "t-1", "variant_public_id" => "v-1",
                 "agent_loop_public_id" => "al-1" })], next_after: "c1", watermark: 1)
  end

  # THE ORDERING PIN. A REAL follower on a conversation host, its two pumps driven by hand
  # in the order the residue named: the model's words half streamed on the transcript feed
  # (text, and reasoning on its own channel); then the EVENTS feed's terminal —
  # `turn_settled?` true with the transcript box empty — and a reader joining on it; then
  # the transcript feed's settled turn. The reader must see the join-time partial, the
  # settle's REMAINDER as a `text_delta`, and only then `closed` — the frame carrying the
  # last word is the one that ends it. The reactor's `tend_stream` is held back until the
  # settle has landed, so the close is the listener path's own; run afterwards, it finds
  # the stream closed and forgets the listener, as its `ensure` does on the daemon.
  def test_a_reader_joining_on_the_events_terminal_still_gets_the_settles_remainder_before_the_close
    daemon = one_shot_ready(boot)
    realtime = Object.new
    realtime.define_singleton_method(:rebind) { true }
    realtime.define_singleton_method(:close) { nil }
    run = nil
    response = nil
    frames_before_settle = nil
    socket = InterleavedSocket.new(
      [transcript_item("reasoning_delta", kind: "reasoning_text", text: "thinking"),
       transcript_item("text_delta", text: "half an")],
      lambda do
        assert_raises(StopIteration) { run.follow }
        assert_predicate run, :turn_settled?, "the events feed's terminal landed first"
        refute_predicate run, :transcript_settled?, "and the transcript box is empty"
        response = route(daemon, "GET", "/loops/follow").call(follow_request(daemon, "public_id=c-1"))
        assert_equal 200, response.status
        frames_before_settle = drain(response.body)
      end,
      [settled_turn_item("half an answer")]
    )
    run = Rho::HostRun.new(host: Rho::Host::Conversation.new(public_id: "c-1"),
      context: ScriptedHost.new([terminal_page], socket), realtime: realtime,
      sleeper: ->(_seconds) { raise StopIteration }, turn: "t-1", loop: "al-1")
    daemon.lineage.install_run(daemon.lineage.credentials, run)

    capturing_spawns(daemon) do |spawned|
      assert_raises(StopIteration) { run.follow_transcript }
      assert_equal 1, spawned.length, "the route spawned its tender"
      spawned.each(&:call)
    end

    assert_includes frames_before_settle, %("text":"half an","text_length":7)
    assert_includes frames_before_settle, %("reasoning":"thinking")
    refute_includes frames_before_settle, "event: closed", "the events terminal alone must not end the reader"
    frames = drain(response.body)
    remainder = frames.index(%(event: text_delta\ndata: {"text":" answer"}\n\n))
    closed = frames.index(%(event: closed\ndata: {"reason":"turn_settled"}))
    refute_nil remainder, "the settle's remainder reached the reader: #{frames.inspect}"
    refute_nil closed, "and the reader was ended: #{frames.inspect}"
    assert_operator remainder, :<, closed, "the remainder is written before the close"
    refute_includes frames, "stream_reset", "a settle that continues what was streamed disowns nothing"
    refute_predicate run, :listeners?, "nothing may be left registered on a run nobody is watching"
  end

  def test_a_live_loop_pushes_each_event_as_its_own_named_frame
    listeners = []
    daemon = follow_ready(boot, followed_run("al-1", complete: false, listeners: listeners))

    response = route(daemon, "GET", "/loops/follow").call(follow_request(daemon, "public_id=al-1"))
    assert_equal 200, response.status
    assert_equal 1, listeners.length, "a live loop keeps the reader registered"

    event = Struct.new(:type, :payload).new("task_status", { "task_key" => "r1", "status" => "running" })
    listeners.first.call(event)

    # Draining only while a chunk is queued: reading an open body with
    # nothing in it BLOCKS, which would hang the suite rather than fail it.
    frames = +""
    frames << response.body.read.to_s while response.body.ready?

    assert_includes frames, %(event: snapshot\n)
    assert_includes frames, %(event: task_status\ndata: {"task_key":"r1","status":"running"}\n\n)
  end

  # A LOOP-GRAIN VERB GIVEN A CONVERSATION ID acts on the loop backing its
  # current turn: the store row resolves it, and a loop
  # id passes through untouched.
  def test_a_loop_grain_verb_resolves_a_conversation_id_to_its_backing_loop
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = member_ready(boot, api)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", turn: "t-1", loop: "al-9")

    response = request(daemon, :post, "/loops/retry",
      token: bearer(daemon), body: { public_id: "c-1", task_key: "round1" })

    assert_equal "200", response.code, response.body
    assert(api.requests.any? { |path, _| path.end_with?("/agent_loops/al-9/tasks/round1/retry") },
      "the verb reached the BACKING loop: #{api.requests.map(&:first).inspect}")
    assert_equal "200", request(daemon, :post, "/loops/retry",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "round1" }).code
  end

  def test_attach_follows_a_loop_this_daemon_did_not_place_and_remembers_it
    trace = NexusDoubles::HALTED_TRACE.merge("status" => "running", "attention" => nil)
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(trace: trace))

    response = request(daemon, :post, "/loops/attach",
      token: bearer(daemon), body: { public_id: "al-9" })

    assert_equal "200", response.code, response.body
    assert_equal "al-9", JSON.parse(response.body).dig("loop", "public_id")
    followed = JSON.parse(request(daemon, :get, "/loops", token: bearer(daemon)).body)
    assert_equal ["al-9"], followed.fetch("loops").map { |row| row.fetch("public_id") }
    assert_equal %w[al-9],
      host_store(daemon).rows.map(&:host_public_id)
  end

  # THE CONVERSATION ARM: `attach`
  # takes a LOOP id and 404s on a conversation's, and the store is bounded
  # (`HostStore::MAX_ROWS`), so a thread an editor reopens weeks later may
  # be a row this daemon forgot. `host_type: "conversation"` follows the
  # conversation's OWN feed — the kernel's conversation read first, so an
  # unknown id is its 404 — remembers it, fetches no loop, and answers
  # the conversation beside the run; any other word is refused by name.
  def test_attach_with_the_conversation_arm_follows_the_conversations_own_feed_and_remembers_it
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/loops/attach",
      token: bearer(daemon), body: { public_id: "c-7", host_type: "conversation" })

    assert_equal "200", response.code, response.body
    answer = JSON.parse(response.body)
    assert_equal({ "public_id" => "c-7" }, answer.fetch("conversation"))
    refute answer.key?("loop"), "no loop was fetched or named"
    assert_equal %w[c-7 conversation], answer.fetch("run").values_at("public_id", "host_type")
    assert(api.requests.any? { |path, _| path.end_with?("/conversations/c-7") }, "the conversation was read")
    refute(api.requests.any? { |path, _| path.include?("/agent_loops/") }, "no loop fetch: #{api.requests.map(&:first)}")
    followed = JSON.parse(request(daemon, :get, "/loops", token: bearer(daemon)).body).fetch("loops")
    assert_equal [%w[c-7 conversation]], followed.map { |row| row.values_at("public_id", "host_type") }
    row = host_store(daemon).rows.fetch(0)
    assert_equal ["conversation", "c-7", nil], [row.host_type, row.host_public_id, row.loop]

    again = request(daemon, :post, "/loops/attach", token: bearer(daemon), body: { public_id: "c-7", host_type: "conversation" })
    assert_equal "200", again.code, "attaching twice answers the standing run"
    assert_equal 1, daemon.lineage.runs.length

    refused = request(daemon, :post, "/loops/attach", token: bearer(daemon), body: { public_id: "c-7", host_type: "thread" })
    assert_equal ["400", "malformed_body"], [refused.code, JSON.parse(refused.body).dig("error", "code")]
  end

  # THE ROW STAYS WHEN THE REPLAYED TURN SETTLES: a
  # fresh follower replays the conversation's feed from the start, so the
  # last turn's settle lands moments after the attach — and a conversation
  # OUTLIVES its turns, so that settle must not forget the row `say` looks
  # up by the conversation's id (`Loops#adopt_run`'s own rule). Before this
  # pin the arm's follower forgot the host at every turn terminal, and
  # `rho say` after a successful `rho attach --conversation` read "not
  # following — attach it first".
  def test_the_conversation_arm_keeps_the_row_after_the_replayed_turn_settles
    events = [
      { "public_id" => "ev-1", "sequence" => 1, "cursor" => "c1", "type" => "turn_status",
        "resource" => { "type" => "conversation", "public_id" => "c-7" }, "occurred_at" => "2026-09-17T00:00:00Z",
        "payload" => { "status" => "running", "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" } },
      { "public_id" => "ev-2", "sequence" => 2, "cursor" => "c2", "type" => "turn_status",
        "resource" => { "type" => "conversation", "public_id" => "c-7" }, "occurred_at" => "2026-09-17T00:00:01Z",
        "payload" => { "status" => "completed", "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" } },
    ]
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, conversation_events: events)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/loops/attach",
      token: bearer(daemon), body: { public_id: "c-7", host_type: "conversation" })
    assert_equal "200", response.code, response.body
    run = daemon.lineage.runs.find { |candidate| candidate.public_id == "c-7" }
    refute_nil run
    wait_for { run.snapshot.complete }

    rows = host_store(daemon).rows
    assert_equal [%w[conversation c-7]], rows.map { |row| [row.host_type, row.host_public_id] },
      "the settle of a replayed turn is not the conversation's end"
    followed = JSON.parse(request(daemon, :get, "/loops", token: bearer(daemon)).body).fetch("loops")
    assert_equal ["c-7"], followed.map { |row| row.fetch("public_id") }
  end

  def test_attaching_to_a_finished_loop_says_there_is_nothing_to_follow
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(
      trace: NexusDoubles::HALTED_TRACE.merge("status" => "completed")))

    response = request(daemon, :post, "/loops/attach",
      token: bearer(daemon), body: { public_id: "al-9" })

    assert_equal "409", response.code
    assert_equal "loop_terminal", JSON.parse(response.body).dig("error", "code")
  end
end
