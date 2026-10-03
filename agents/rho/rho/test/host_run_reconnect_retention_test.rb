require "test_helper"

class HostRunReconnectRetentionTest < Minitest::Test
  class Api < NexusDoubles::FakeAgentApi
    attr_reader :turn_rows

    def initialize(head:, turns:, previous: nil, **options)
      @head = head
      @turn_rows = turns
      @previous = previous
      super(turns: turns, **options)
    end

    def call(path, **options)
      if @previous && path.end_with?("/turns/t-7/variants", "/agent_loops/al-7")
        @previous.call(path, **options)
      else
        response = super
        if path.end_with?("/events")
          # Retention removes items, not the host's allocated sequence head.
          response.with(body: response.body.merge(
            "pagination" => response.body.fetch("pagination").merge("watermark" => @head)))
        else
          response
        end
      end
    end
  end

  class Transport
    attr_accessor :api, :online
    attr_reader :failed_reads

    def initialize(api)
      @api = api
      @online = true
      @failed_reads = 0
    end

    def call(path, **options)
      unless @online
        @failed_reads += 1
        raise CybrosAgent::TransportError, "network unavailable"
      end
      @api.call(path, **options)
    end
  end

  class Socket
    attr_reader :items, :closed

    def initialize(items)
      @items = items
      @closed = false
      @lost = false
      @messages = []
    end

    def push(event) = @messages << { "event" => event }
    def lose = @lost = true
    def unsubscribe = @closed = true

    def each
      until @closed
        raise CybrosAgent::Realtime::ConnectionLostError if @lost

        message = @messages.shift
        message ? yield(message) : Fiber.yield
      end
    end
  end

  class Realtime
    attr_accessor :online
    attr_reader :sockets

    def initialize
      @online = true
      @sockets = []
    end

    # A disconnected cable's handshake stays pending until the network is back.
    def connect_for_feed
      Fiber.yield until @online
    end

    def subscribe(channel:, params:, timeout:)
      socket = Socket.new(params[:items])
      @sockets << socket
      socket
    end

    def current(items = nil) = @sockets.reverse.find { |socket| socket.items == items && !socket.closed }

    def disconnect
      @online = false
      @sockets.each(&:lose)
    end

    def rebind
      @sockets.each(&:lose)
      true
    end

    def close
      @sockets.each(&:unsubscribe)
      nil
    end
  end

  def setup
    @fibers = []
    @completed = []
    @realtime = Realtime.new
    @transport = Transport.new(history(status: "running", head: 2,
      events: [status_event(1, "running"), task_event(2, "running")]))
  end

  def teardown
    @transport.online = true if @transport
    @realtime.online = true if @realtime
    @run&.stop
    tick
  end

  def test_a_running_follower_recovers_completion_after_the_missing_events_have_expired
    follow
    disconnect
    @transport.api = history(status: "completed", head: 4, answer: "Finished while offline.")

    reconnect

    assert_recovered(turn: "t-7", loop_id: "al-7", answer: "Finished while offline.")
    assert_equal ["t-7"], @completed.map(&:turn)
    assert_equal "Finished while offline.", @completed.first.text
    assert_equal %w[work followup], @completed.first.tasks.map(&:task_key)
    assert_no_repeated_recovery
    assert_equal 1, @completed.length, "later empty probes must not repeat the recovered completion"

    next_turn = event(5, "turn_status", status: "running", loop_status: "running",
      turn_public_id: "t-8", variant_public_id: "v-8", agent_loop_public_id: "al-8")
    @transport.api = history(turn: "t-8", status: "running", head: 5, events: [next_turn], previous: @transport.api)
    @realtime.current.push(next_turn)
    3.times { tick }

    assert_equal ["t-8", "running"], [@run.snapshot.turn, @run.snapshot.status]
    assert_equal 5, @run.event_position.sequence
    assert_equal 0, recovery_reads, "the event immediately after the recovered head needs no second snapshot"
    assert_equal 1, @completed.length
  end

  def test_an_idle_follower_discovers_a_whole_new_turn_after_its_events_have_expired
    follow
    @transport.api = history(status: "completed", head: 4, answer: "The first answer.",
      events: [status_event(1, "running"), task_event(2, "running"), task_event(3, "completed"), status_event(4, "completed")])
    @realtime.current.push(task_event(3, "completed"))
    @realtime.current.push(status_event(4, "completed"))
    @realtime.current("transcript").push({ "type" => "turn", "turn_public_id" => "t-7",
      "variant_public_id" => "v-7", "agent_loop_public_id" => "al-7",
      "turn" => turn_document("t-7", "completed", "The first answer.") })
    tick
    assert @run.turn_settled?
    assert_equal "The first answer.", @run.snapshot.text
    assert_equal ["t-7"], @completed.map(&:turn)

    disconnect
    @transport.api = history(turn: "t-8", status: "completed", head: 8, answer: "The newer answer.",
      previous: @transport.api)
    reconnect

    assert_recovered(turn: "t-8", loop_id: "al-8", answer: "The newer answer.")
    assert_equal %w[t-7 t-8], @completed.map(&:turn)
    assert_no_repeated_recovery
    assert_equal 2, @completed.length
  end

  def test_rest_only_recovery_handles_each_new_expired_head_without_reloading_an_unchanged_head
    follow(realtime: nil)
    position = @run.event_position
    @transport.api = history(status: "completed", head: 4, answer: "The first recovered answer.")
    5.times { tick }

    assert_recovered(turn: "t-7", loop_id: "al-7", answer: "The first recovered answer.")
    assert_equal position, @run.event_position, "recovery cannot invent an event cursor for expired items"
    assert_equal ["t-7"], @completed.map(&:turn)
    assert_no_repeated_recovery

    @transport.api = history(turn: "t-8", status: "completed", head: 8, answer: "The newer recovered answer.",
      previous: @transport.api)
    5.times { tick }

    assert_recovered(turn: "t-8", loop_id: "al-8", answer: "The newer recovered answer.")
    assert_equal position, @run.event_position
    assert_equal %w[t-7 t-8], @completed.map(&:turn)
    assert_no_repeated_recovery
    assert_equal 2, @completed.length
    assert_empty @realtime.sockets, "the REST follower never needed a socket"
  end

  def test_recovery_follows_a_regenerated_candidate_on_the_same_turn
    follow
    disconnect
    @transport.api = history(status: "completed", head: 4, answer: "The original answer.")
    reconnect
    assert_recovered(turn: "t-7", loop_id: "al-7", answer: "The original answer.")
    original = @transport.api.turn_rows.last.fetch("active_variant")

    disconnect
    @transport.api = history(status: "running", head: 6, candidate: "8", active_variant: original)
    reconnect

    snapshot = @run.snapshot
    assert_equal ["t-7", "al-8", "running"], [snapshot.turn, snapshot.loop, snapshot.status]
    assert @transport.api.requests.any? { |path, *| path.end_with?("/agent_loops/al-8") },
      "recovery reads the running candidate's loop, not the still-active old answer"
    assert_equal [["work", "running"]], snapshot.tasks.map { |task| [task.task_key, task.status] }
    assert_empty snapshot.text, "the active old answer is not the new running candidate's preview"
    refute @run.turn_settled?
    refute @run.transcript_settled?
    assert_equal ["al-7"], @completed.map(&:loop)
    assert_no_repeated_recovery

    disconnect
    @transport.api = history(status: "completed", head: 8, candidate: "8", answer: "The regenerated answer.")
    reconnect

    assert_recovered(turn: "t-7", loop_id: "al-8", answer: "The regenerated answer.")
    assert_equal %w[al-7 al-8], @completed.map(&:loop), "completion is per execution, not only per turn"
    assert_equal ["The original answer.", "The regenerated answer."], @completed.map(&:text)
    assert_no_repeated_recovery
    assert_equal 2, @completed.length
  end

  private

    def follow(realtime: @realtime)
      workspace = CybrosAgent::Client.new(base_url: "https://nexus.example",
        credential: NexusDoubles::MEMBER_TOKEN, transport: @transport).workspace("ws-1")
      @run = Rho::HostRun.new(host: Rho::Host::Conversation.new(public_id: "c-7"),
        context: workspace.conversations.conversation("c-7"), realtime: realtime,
        loop_context: ->(id) { workspace.agent_loop(id) }, sleeper: ->(_seconds) { Fiber.yield },
        on_complete: ->(run) { @completed << run.snapshot })
      @run.start(->(&work) { @fibers << Fiber.new(&work) })
      tick
      assert_equal ["t-7", "running"], [@run.snapshot.turn, @run.snapshot.status]
      assert_equal [["work", "running"]], @run.snapshot.tasks.map { |task| [task.task_key, task.status] }
      assert_equal 2, @run.event_position.sequence
      assert_empty @completed
    end

    def tick
      @fibers.each { |fiber| fiber.resume if fiber.alive? }
    end

    def disconnect
      @transport.online = false
      @realtime.disconnect
      tick
      assert_operator @transport.failed_reads, :>, 0, "the same follower experienced a real HTTP transport failure"
    end

    def reconnect
      @transport.online = true
      @realtime.online = true
      5.times { tick }
      refute_nil @realtime.current, "the same follower reopened its event subscription"
      refute @realtime.current.closed
    end

    def assert_recovered(turn:, loop_id:, answer:)
      snapshot = @run.snapshot
      assert_equal [turn, loop_id, "completed"], [snapshot.turn, snapshot.loop, snapshot.status]
      assert_equal [["work", "completed"], ["followup", "completed"]],
        snapshot.tasks.map { |task| [task.task_key, task.status] }
      assert_equal answer, snapshot.text
      assert @run.turn_settled?
      assert @run.transcript_settled?, "no expired terminal transcript frame will arrive"
      refute @run.settled?, "a conversation continues following future turns"
    end

    def assert_no_repeated_recovery
      reads = recovery_reads
      assert_operator reads, :>, 0, "the missing state came from durable public reads"
      3.times { tick }
      assert_equal reads, recovery_reads, "an unchanged expired head must not reload the timeline, deck, or loop"
    end

    def recovery_reads
      @transport.api.requests.count do |path, *|
        path.end_with?("/turns", "/variants") || path.match?(%r{/agent_loops/[^/]+\z})
      end
    end

    def event(sequence, type, **payload)
      { "public_id" => "ev-#{sequence}", "sequence" => sequence, "cursor" => "c#{sequence}", "type" => type,
        "resource" => { "type" => "conversation", "public_id" => "c-7" },
        "occurred_at" => "2026-08-01T00:00:00Z", "payload" => payload.transform_keys(&:to_s) }
    end

    def status_event(sequence, status)
      event(sequence, "turn_status", status: status, loop_status: status,
        turn_public_id: "t-7", variant_public_id: "v-7", agent_loop_public_id: "al-7")
    end

    def task_event(sequence, status)
      event(sequence, "task_status", task_key: "work", kind: "model_task", status: status,
        turn_public_id: "t-7", variant_public_id: "v-7", agent_loop_public_id: "al-7")
    end

    def history(turn: "t-7", status:, head:, answer: nil, events: [], previous: nil,
                candidate: turn.delete_prefix("t-"), active_variant: nil)
      row = turn_document(turn, status, answer, candidate: candidate)
      variant = row.fetch("active_variant")
      loop_id = variant.fetch("agent_loop_public_id")
      variants = active_variant ? [active_variant, variant.merge("active" => false)] : [variant]
      row = row.merge("active_variant" => active_variant) if active_variant
      task = NexusDoubles::RUNNING_TRACE.fetch("tasks").first.merge("status" => status)
      tasks = status == "completed" ? [task, task.merge("key" => "followup")] : [task]
      trace = NexusDoubles::RUNNING_TRACE.merge("public_id" => loop_id, "status" => status, "tasks" => tasks,
        "turn" => { "status" => status, "public_id" => turn, "conversation_public_id" => "c-7" })
      turns = previous ? previous.turn_rows + [row] : [row]
      Api.new(trace: trace, turns: turns, conversation_events: events, head: head, previous: previous,
        conversation_busy: (turn unless status == "completed"),
        variants: { "turn" => { "public_id" => turn, "inherited" => false }, "variants" => variants })
    end

    def turn_document(turn, status, answer, candidate: turn.delete_prefix("t-"))
      { "public_id" => turn, "position" => Integer(turn.delete_prefix("t-")), "kind" => "direct_reply", "role" => "assistant",
        "status" => status, "visibility" => "visible", "inherited" => false,
        "answering_user_public_id" => "0199-user", "created_at" => "2026-08-01T00:00:00Z",
        "active_variant" => { "public_id" => "v-#{candidate}", "source" => "agent_loop", "status" => status,
          "content" => answer, "content_preview" => answer, "agent_loop_public_id" => "al-#{candidate}", "active" => true } }
    end
end
