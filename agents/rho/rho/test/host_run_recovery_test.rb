require "test_helper"

# The last durable event may miss a healthy socket: no later sequence exposes
# its absence. Exercise both hosts through the SDK feed and rho's real start
# door, keeping the connection open while only REST learns the terminal fact.
class HostRunRecoveryTest < Minitest::Test
  Event = Data.define(:sequence, :cursor, :public_id, :type, :payload)
  Page = Data.define(:items, :next_after, :watermark)

  class Socket
    attr_reader :closed, :unsubscribes

    def initialize
      @closed = false
      @unsubscribes = 0
      @events = []
    end

    def push(event) = @events << event

    def each
      until @closed
        event = @events.shift
        event ? yield(event) : Fiber.yield
      end
    end

    def unsubscribe
      @unsubscribes += 1
      @closed = true
    end
  end

  class Realtime
    def rebind = true
    def close = nil
  end

  class Context
    attr_reader :socket, :probes, :subscriptions
    attr_accessor :probe_override, :replay_head, :durable

    def initialize
      @events = []
      @probes = []
      @subscriptions = 0
    end

    def append(event) = @events << event

    def events(after: nil, limit: nil)
      if limit == 1
        @probes << after
        return @probe_override.call if @probe_override
      end
      offset = after ? @events.index { |event| event.cursor == after } + 1 : 0
      items = @events.drop(offset)
      items = items.take(limit) if limit
      Page.new(items: items, next_after: items.last&.cursor || after,
        watermark: @replay_head || @events.last&.sequence || 0)
    end

    def realtime_opener(_realtime, items: nil)
      -> do
        @subscriptions += 1
        @socket = Socket.new
      end
    end

    def feed(realtime: nil, items: nil, **options)
      CybrosAgent::KernelFeed.new(
        replay: ->(cursor) { events(after: cursor) },
        subscribe: realtime && realtime_opener(realtime, items: items), **options
      )
    end

    def children = CybrosAgent::Api::Page.new(items: [], next_after: nil)
    def fetch = @durable.fetch
    def turns = @durable.turns
  end

  def setup
    @context = Context.new
    @fibers = []
    @completed = []
    @ended = []
    @sleeps = []
  end

  def teardown
    @run.stop
    tick
  end

  def test_a_conversation_learns_its_turn_finished_without_another_socket_event
    start(Rho::Host::Conversation.new(public_id: "c-1"), turn: "t-1")
    assert_equal "running", @run.snapshot.status
    refute @run.turn_settled?
    refute @context.socket.closed

    @context.append(status_event(2, "completed", turn: "t-1"))
    assert_equal "completed", @context.events(after: "c1").items.last.payload.fetch("status")
    3.times { tick }

    assert @run.turn_settled?, "the final lifecycle wake may be lost on a still-open socket"
    assert @run.snapshot.complete
    assert_equal "completed", @run.snapshot.status
    assert_equal ["c-1"], @completed
    refute @run.settled?, "the conversation remains followable for its next turn"
  end

  def test_a_standalone_loop_finishes_its_follower_when_the_final_wake_is_lost
    start(Rho::Host::AgentLoop.new(public_id: "al-1"))
    assert_equal "running", @run.snapshot.status
    refute @run.settled?
    refute @context.socket.closed

    @context.append(status_event(2, "completed"))
    assert_equal "completed", @context.events(after: "c1").items.last.payload.fetch("status")
    3.times { tick }

    assert @run.settled?, "REST knows the loop ended even when no further frame arrives"
    assert_equal ["al-1"], @completed
    assert @context.socket.closed
    refute @fibers.any?(&:alive?), "the loop's followers must all finish"
  end

  def test_missing_tasks_and_terminal_status_replay_through_one_consumer_in_order
    start(Rho::Host::Conversation.new(public_id: "c-1"), turn: "t-1")
    seen = []
    @run.listen { |event| seen << event.sequence }
    @context.append(Event.new(sequence: 2, cursor: "c2", public_id: "e2", type: "task_status",
      payload: { "task_key" => "r1t0", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed" }))
    @context.append(status_event(3, "completed", turn: "t-1"))
    3.times { tick }

    assert_equal [2, 3], seen
    assert_equal "completed", @run.snapshot.tasks.first.status
    assert_equal 3, @run.snapshot.sequence
    assert_equal ["c-1"], @completed
    assert_equal 2, @context.subscriptions

    @context.socket.push(status_event(3, "completed", turn: "t-1"))
    3.times { tick }
    assert_equal [2, 3], seen
    assert_equal ["c-1"], @completed
    assert_equal 2, @context.subscriptions, "caught-up durable tasks do not keep rebinding"
  end

  def test_transient_probes_back_off_and_recover_a_canceled_loop
    start(Rho::Host::AgentLoop.new(public_id: "al-1"))
    responses = [
      -> { raise CybrosAgent::Api::RateLimited.new(retry_after: 7) },
      -> { raise CybrosAgent::Api::ServerError.new("briefly unavailable") },
    ]
    @context.probe_override = -> { responses.shift.call }
    @sleeps.clear
    2.times { tick }
    assert_equal [7, Rho::HostRun::POLL_SECONDS], @sleeps.select { |fiber, _| fiber == @fibers.last }.map(&:last)
    refute @run.settled?
    assert_equal 1, @context.subscriptions

    @context.probe_override = nil
    @context.append(status_event(2, "canceled"))
    3.times { tick }
    assert @run.settled?
    assert_equal "canceled", @run.snapshot.status
    assert_equal ["al-1"], @completed
    refute @fibers.any?(&:alive?)
  end

  def test_an_expired_head_rebinds_once_and_repeated_empty_probes_keep_the_recovered_socket
    start(Rho::Host::Conversation.new(public_id: "c-1"), turn: "t-1")
    variant = { "public_id" => "v-1", "source" => "manual", "status" => "completed",
      "content" => "The retained answer.", "content_preview" => "The retained answer.", "active" => true }
    turn = { "public_id" => "t-1", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
      "status" => "completed", "visibility" => "visible", "inherited" => false,
      "answering_user_public_id" => "0199-user", "created_at" => "2026-08-01T00:00:00Z",
      "active_variant" => variant }
    api = NexusDoubles::FakeAgentApi.new(turns: [turn],
      variants: { "turn" => { "public_id" => "t-1", "inherited" => false }, "variants" => [variant] })
    @context.durable = CybrosAgent::Client.new(base_url: "https://nexus.example",
      credential: NexusDoubles::MEMBER_TOKEN, transport: api).workspace("ws-1").conversations.conversation("c-1")
    @context.replay_head = 99
    3.times { tick }

    assert_equal 2, @context.subscriptions
    refute @context.socket.closed
    assert_equal 1, @run.snapshot.sequence
    assert_equal "The retained answer.", @run.snapshot.text
    assert @run.turn_settled?
    assert_equal ["c-1"], @completed
    assert_equal 1, api.turn_windows.length

    3.times { tick }

    assert_equal 2, @context.subscriptions, "the recovered head cannot trigger another rebind"
    assert_equal 1, api.turn_windows.length, "the same empty head needs no second state recovery"
    assert_equal ["c-1"], @completed
  end

  def test_a_completed_conversation_probes_slowly_and_a_new_turn_restores_active_cadence
    start(Rho::Host::Conversation.new(public_id: "c-1"), turn: "t-1")
    assert_equal Rho::HostRun::POLL_SECONDS, @sleeps.last.last
    @context.append(status_event(2, "completed", turn: "t-1"))
    3.times { tick }
    assert @run.turn_settled?
    assert_equal Rho::HostRun::IDLE_POLL_SECONDS, @sleeps.last.last

    event = status_event(3, "running", turn: "t-2")
    @context.append(event)
    @context.socket.push(event)
    @fibers.first.resume
    refute @run.turn_settled?
    assert_equal "t-2", @run.snapshot.turn
    # The existing idle sleep can finish normally; the live event was timely.
    @fibers.last.resume
    assert_equal Rho::HostRun::POLL_SECONDS, @sleeps.last.last
    assert_equal 2, @context.subscriptions
  end

  def test_a_probe_does_not_rebind_when_live_delivery_caught_up_during_the_read
    start(Rho::Host::Conversation.new(public_id: "c-1"), turn: "t-1")
    event = status_event(2, "completed", turn: "t-1")
    @context.append(event)
    @context.probe_override = -> do
      Fiber.yield
      Page.new(items: [event], next_after: "c2", watermark: 2)
    end
    @fibers.last.resume
    @context.socket.push(event)
    @fibers.first.resume
    assert @run.turn_settled?

    @fibers.last.resume
    assert_equal 1, @context.subscriptions
    refute @context.socket.closed
    assert_equal ["c-1"], @completed
  end

  def test_stopping_during_a_probe_discards_its_in_flight_page
    start(Rho::Host::Conversation.new(public_id: "c-1"), turn: "t-1")
    event = status_event(2, "completed", turn: "t-1")
    @context.probe_override = -> do
      Fiber.yield
      Page.new(items: [event], next_after: "c2", watermark: 2)
    end
    @fibers.last.resume
    socket = @context.socket
    @run.stop
    unsubscribes = socket.unsubscribes
    probes = @context.probes.length
    @fibers.last.resume

    assert_equal unsubscribes, socket.unsubscribes
    assert_equal probes, @context.probes.length
    assert_equal 1, @run.snapshot.sequence
    assert_empty @completed
    refute @fibers.last.alive?
  end

  def test_a_not_found_probe_ends_the_host_and_stops_all_followers
    start(Rho::Host::Conversation.new(public_id: "c-1"), turn: "t-1")
    @context.probe_override = -> { raise CybrosAgent::Api::NotFound.new("gone") }
    2.times { tick }

    assert_equal ["c-1"], @ended
    assert @context.socket.closed
    refute @fibers.any?(&:alive?)
    assert_empty @completed
  end

  def test_a_forbidden_read_probe_ends_the_follow_without_canceling_the_turn
    start(Rho::Host::Conversation.new(public_id: "c-1"), turn: "t-1")
    @context.probe_override = -> { raise CybrosAgent::Api::Forbidden.new("no longer readable") }
    2.times { tick }

    assert_equal ["c-1"], @ended
    assert @context.socket.closed
    refute @fibers.any?(&:alive?)
    assert_equal "running", @run.snapshot.status
    assert_empty @completed
  end

  def test_a_late_not_found_does_not_repeat_the_live_host_ended_callback
    start(Rho::Host::Conversation.new(public_id: "c-1"), turn: "t-1")
    @context.probe_override = -> do
      Fiber.yield
      raise CybrosAgent::Api::NotFound.new("gone")
    end
    @fibers.last.resume
    @context.socket.push(Event.new(sequence: 2, cursor: "c2", public_id: "e2",
      type: "conversation_ended", payload: { "reason" => "deleted" }))
    @fibers.first.resume
    assert_equal ["c-1"], @ended

    @fibers.last.resume
    assert_equal ["c-1"], @ended
    assert_equal 2, @run.snapshot.sequence
  end

  private

    def start(host, turn: nil)
      @context.append(status_event(1, "running", turn: turn))
      @run = Rho::HostRun.new(
        host: host, context: @context, realtime: Realtime.new, live: false, stream: false,
        sleeper: ->(seconds) { @sleeps << [Fiber.current, seconds]; Fiber.yield },
        on_complete: ->(run) { @completed << run.public_id },
        on_ended: ->(run) { @ended << run.public_id }
      )
      @run.start(->(&block) { @fibers << Fiber.new(&block) })
      tick
    end

    def tick
      @fibers.each { |fiber| fiber.resume if fiber.alive? }
    end

    def status_event(sequence, status, turn: nil)
      payload = { "status" => status, "loop_status" => status, "agent_loop_public_id" => "al-1" }
      payload["turn_public_id"] = turn if turn
      Event.new(sequence: sequence, cursor: "c#{sequence}", public_id: "e#{sequence}",
        type: "turn_status", payload: payload)
    end
end
