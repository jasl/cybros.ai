require_relative "../test_helper"
require_relative "../support/ops_harness"

class OpsRetainedTranscriptTest < Minitest::Test
  include RhoTest::OpsHarness

  ANSWER = "The retained answer."

  class Socket
    attr_reader :reads

    def initialize
      @closed = false
      @reads = 0
    end

    def each
      @reads += 1
      Fiber.yield until @closed
    end

    def unsubscribe = @closed = true
  end

  class Realtime
    attr_reader :transcripts

    def initialize
      @transcripts = []
    end

    def connect_for_feed = nil
    def rebind = true

    def close
      @transcripts.each(&:unsubscribe)
      nil
    end

    def subscribe(channel:, params:, timeout:)
      socket = Socket.new
      if params[:items] == "transcript"
        @transcripts << socket
        Fiber.yield # The server has not confirmed this subscription yet.
      end
      socket
    end
  end

  def setup
    super
    @realtime = Realtime.new
    client = CybrosAgent::Client.new(base_url: "https://nexus.example",
      credential: NexusDoubles::MEMBER_TOKEN, transport: retained_history_api)
    workspace = client.workspace("ws-1")
    @run = Rho::HostFollower.new(host: Rho::Host::Conversation.new(public_id: "c-7"),
      context: workspace.conversations.conversation("c-7"), realtime: @realtime,
      run_context: ->(id) { workspace.run(id) }, sleeper: ->(_seconds) { Fiber.yield })
    @events = Fiber.new { @run.follow }
    @transcript = Fiber.new { @run.follow_transcript }
    @frames = []
    @run.listen { |frame| @frames << frame.type }
  end

  def teardown
    @run&.stop
    @events.resume if @events&.alive?
    @transcript.resume if @transcript&.alive?
    super
  end

  def test_a_late_first_transcript_confirmation_preserves_the_recovered_answer
    @transcript.resume
    assert_equal 0, @realtime.transcripts.first.reads

    @events.resume
    assert_recovered
    @frames.clear
    @transcript.resume

    assert_equal 1, @realtime.transcripts.first.reads
    assert_reader_receives_answer
  end

  def test_a_transcript_reconnect_preserves_the_recovered_answer_without_a_new_terminal_frame
    @transcript.resume
    @transcript.resume
    assert_equal 1, @realtime.transcripts.first.reads

    @events.resume
    assert_recovered
    @frames.clear
    @realtime.transcripts.first.unsubscribe
    @transcript.resume
    assert_equal 2, @realtime.transcripts.length
    assert_equal 0, @realtime.transcripts.last.reads
    @transcript.resume

    assert_equal 1, @realtime.transcripts.last.reads
    assert_reader_receives_answer
  end

  private

    def assert_recovered
      assert @run.snapshot.live
      assert @run.turn_settled?
      assert @run.transcript_settled?
      assert_equal ANSWER, @run.snapshot.text
    end

    def assert_reader_receives_answer
      assert_recovered
      refute_includes @frames, "stream_reset", "a sealed answer is not an interrupted partial stream"

      daemon = inference_request_ready(boot(realtime_factory: ->(_credential) { nil }))
      daemon.lineage.install_follower(daemon.lineage.credentials, @run)
      response = route(daemon, "GET", "/followers/follow").call(
        query_request("/followers/follow?public_id=c-7", token: bearer(daemon)))
      assert_equal 200, response.status

      frames = +""
      while response.body.ready?
        chunk = response.body.read
        break if chunk.nil?

        frames << chunk
      end
      assert_includes frames, %Q("text":"#{ANSWER}")
      assert_includes frames, %(event: closed\ndata: {"reason":"turn_settled"})
      refute @run.settled?, "the conversation remains available for its next turn"
    end

    def retained_history_api
      variant = {
        "public_id" => "v-7", "source" => "run", "status" => "completed",
        "content" => ANSWER, "content_preview" => ANSWER,
        "run_public_id" => "al-7", "active" => true,
      }
      turn = {
        "public_id" => "t-7", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
        "status" => "completed", "visibility" => "visible", "inherited" => false,
        "answering_user_public_id" => "0199-user", "created_at" => "2026-08-01T00:00:00Z",
        "active_variant" => variant,
      }
      trace = NexusDoubles::RUNNING_TRACE.merge(
        "public_id" => "al-7", "status" => "completed",
        "tasks" => NexusDoubles::RUNNING_TRACE.fetch("tasks").map { |task| task.merge("status" => "completed") },
        "turn" => { "status" => "completed", "public_id" => "t-7", "conversation_public_id" => "c-7" }
      )
      NexusDoubles::FakeAgentApi.new(trace: trace, turns: [turn], conversation_events: [], conversation_event_head: 42,
        variants: { "turn" => { "public_id" => "t-7", "inherited" => false }, "variants" => [variant] })
    end
end
