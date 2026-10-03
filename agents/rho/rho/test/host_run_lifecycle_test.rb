require "support/host_run_harness"

class HostRunLifecycleTest < Minitest::Test
  include RhoTest::HostRunHarness

  class Api < NexusDoubles::FakeAgentApi
    attr_accessor :archived_at

    private

      def conversation_row(public_id, **options)
        super.merge("archived_at" => @archived_at)
      end
  end

  def teardown
    @run&.stop
    @reader.resume if @reader&.alive?
  end

  def test_a_forbidden_event_read_ends_the_follow_without_canceling_the_turn
    ended = []
    @context = Context.new([], raise_once: CybrosAgent::Api::Forbidden.new("no longer readable"))
    run = Rho::HostRun.new(host: CONVERSATION, context: @context,
      on_ended: ->(finished) { ended << finished })

    assert_raises(CybrosAgent::Api::Forbidden) { run.follow }

    assert_equal [run], ended
    assert_predicate run, :stopped?
    refute_predicate run, :turn_settled?
    refute_equal "canceled", run.snapshot.status
  end

  def test_a_restored_conversation_replays_its_old_archive_and_follows_the_new_turn
    events = [wire_event(1, "conversation_ended", reason: "archived"),
      wire_event(2, "turn_status", turn_public_id: "t-restored", agent_loop_public_id: "al-restored", status: "running")]
    follow(events)

    assert_empty @ended
    refute_predicate @run, :stopped?
    assert @reader.alive?, "the restored host must keep following after its historical archive"
    assert_equal ["t-restored", "al-restored", "running"],
      [@run.snapshot.turn, @run.snapshot.loop, @run.snapshot.status]
    assert_equal 2, @run.event_position.sequence
    refute @api.requests.any? { |path, _| path.end_with?("/cancellation") }
  end

  def test_an_archived_conversation_ends_the_follow_and_tells_the_daemon
    seen = []
    looks = []
    follow([wire_event(1, "conversation_ended", reason: "archived")],
      archived_at: "2026-09-30T00:00:00Z", gate: fake_gate(looks, loop_public_id: "al-1"),
      listener: ->(event) { seen << event.type })

    assert_equal [@run], @ended
    assert_predicate @run, :stopped?
    refute @reader.alive?, "an archived host must stop without another poll"
    assert_equal ["conversation_ended"], seen
    assert_includes looks, :cancelled, "a --until waiting on an ended conversation is released"
    assert_equal 1, @run.event_position.sequence, "the end was read like any item"
    refute @api.requests.any? { |path, _| path.end_with?("/cancellation") }
  end

  private

    def follow(events, archived_at: nil, listener: nil, **options)
      @api = Api.new(conversation_events: events)
      @api.archived_at = archived_at
      context = CybrosAgent::Client.new(base_url: "https://nexus.example",
        credential: NexusDoubles::MEMBER_TOKEN, transport: @api).workspace("ws-1").conversation("c-1")
      @ended = []
      @run = Rho::HostRun.new(host: CONVERSATION, context: context,
        on_ended: ->(run) { @ended << run }, sleeper: ->(_) { Fiber.yield }, **options)
      @run.listen(&listener) if listener
      @reader = Fiber.new { @run.follow }
      @reader.resume
    end

    def wire_event(sequence, type, **payload)
      { "public_id" => "ev-#{sequence}", "sequence" => sequence, "cursor" => "c#{sequence}", "type" => type,
        "resource" => { "type" => "conversation", "public_id" => "c-1" },
        "occurred_at" => "2026-09-30T00:00:00Z", "payload" => payload.transform_keys(&:to_s) }
    end
end
