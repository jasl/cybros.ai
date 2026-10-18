require "test_helper"

# The publish seam for the realtime mirrors. Two properties matter here and
# neither is about latency: a broadcast failure must never fail the committed
# append it mirrors, and a lifecycle item must reach the narrowed broadcasting
# that exists so an uninterested subscriber receives nothing at all.
class RealtimeEvents::BroadcastTest < ActiveSupport::TestCase
  def broadcastings_for(type)
    sent = []
    ActionCable.server.stub(:broadcast, ->(name, payload) { sent << [name, payload] }) do
      RealtimeEvents::Broadcast.call(
        resource_type: "inference_request", resource_public_id: "os-1",
        event_item: { type: type, payload: {} }
      )
    end
    sent
  end

  test "a lifecycle item reaches both broadcastings and a delta reaches only the stream" do
    lifecycle = broadcastings_for("result")
    assert_equal %w[agent_api:v1:inference_request:os-1:events agent_api:v1:inference_request:os-1:lifecycle],
      lifecycle.map(&:first)
    assert_equal lifecycle.first.last, lifecycle.last.last,
      "the same projected item, so a subscriber sees one shape whichever it chose"

    assert_equal %w[agent_api:v1:inference_request:os-1:events],
      broadcastings_for("text_delta").map(&:first)
    assert_equal %w[agent_api:v1:inference_request:os-1:events],
      broadcastings_for("rollback").map(&:first)
    assert_equal %w[agent_api:v1:inference_request:os-1:events agent_api:v1:inference_request:os-1:lifecycle],
      broadcastings_for("run_status").map(&:first)
  end

  # The rescue is load-bearing: the durable rows are the truth and the replay
  # endpoint serves them, so a cable adapter that is down must cost nothing.
  test "a failing adapter is swallowed rather than failing the append it mirrors" do
    ActionCable.server.stub(:broadcast, ->(*) { raise "adapter down" }) do
      assert_nil RealtimeEvents::Broadcast.call(
        resource_type: "inference_request", resource_public_id: "os-1",
        event_item: { type: "result" }
      )
      assert_nil RealtimeEvents::Broadcast.frame(
        resource_type: "run", resource_public_id: "al-1", frame: { "type" => "executor_progress" }
      )
    end
  end

  # THE ONE PUBLISH SEAM for the ephemeral half: a frame goes out once, on the host's `progress`
  # feed alone, under `{frame}` — never on `events`, never on `lifecycle`, never as `{event}`.
  test "a frame reaches the progress broadcasting alone, under its own envelope" do
    sent = []
    ActionCable.server.stub(:broadcast, ->(name, payload) { sent << [name, payload] }) do
      RealtimeEvents::Broadcast.frame(
        resource_type: "conversation", resource_public_id: "c-1",
        frame: { "type" => "process_output", "process_id" => "p1", "lines" => ["up"] }
      )
    end

    assert_equal [["agent_api:v1:conversation:c-1:progress",
                   { frame: { "type" => "process_output", "process_id" => "p1", "lines" => ["up"] } }]], sent
  end
end
