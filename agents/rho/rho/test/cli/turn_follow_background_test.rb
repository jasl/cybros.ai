require "test_helper"

class TurnFollowBackgroundTest < Minitest::Test
  include RhoTest::CliHarness

  def test_an_older_turns_background_events_cannot_render_or_decide_current_work
    assert_background_is_ignored("older-turn")
  end

  def test_an_older_candidates_background_events_cannot_render_or_decide_current_work
    assert_background_is_ignored("current-turn")
  end

  private

    def assert_background_is_ignored(old_turn)
      current = { "turn_public_id" => "current-turn", "agent_loop_public_id" => "current-loop" }
      previous = { "turn_public_id" => old_turn, "agent_loop_public_id" => "older-loop" }
      parked = { "reason" => "approval_required", "blocked_task_keys" => ["r1t1"] }
      stream = frame("snapshot", { "turn" => "current-turn", "loop" => "current-loop", "status" => "running" }) +
        frame("task_status", previous.merge("task_key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "failed")) +
        frame("turn_status", previous.merge("loop_status" => "needs_attention", "attention_reason" => "halt_failure")) +
        frame("attention_required", previous.merge(parked)) +
        frame("attention_required", previous.merge("reason" => "awaiting_human", "blocked_task_keys" => ["r1t2"])) +
        frame("turn_status", previous.merge("status" => "completed", "loop_status" => "completed")) +
        frame("text_delta", { "text" => "the current answer" }) +
        frame("task_status", current.merge("task_key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed")) +
        frame("attention_required", current.merge(parked)) +
        frame("turn_status", current.merge("status" => "completed", "loop_status" => "completed")) +
        frame("closed", { "reason" => "turn_settled" })
      page = {
        "events" => [{ "public_id" => "event-1", "sequence" => 1, "cursor" => "cursor-1", "type" => "turn_status",
          "resource" => { "type" => "conversation", "public_id" => "conversation" },
          "occurred_at" => "2026-09-20T00:00:00Z", "payload" => current.merge("status" => "running", "loop_status" => "running") }],
        "pagination" => { "next_after" => nil, "watermark" => 1 },
      }
      announce(endpoint: recording_routed_endpoint(nil, {
        "GET /loops/follow?public_id=conversation" => [[200, stream]],
        "GET /loops/events?public_id=conversation" => [[200, page], [200, page]],
      }))
      frames = []
      parks = []
      output = StringIO.new
      printer = Rho::StreamPrinter.new(output)
      follow = Rho::Cli::TurnFollow.new(core: core, conversation: "conversation", turn: "current-turn", loop: "current-loop",
        on_frame: ->(type, payload) {
          frames << [type, payload]
          printer.text(payload.fetch("text")) if type == "text_delta"
        },
        on_park: ->(loop_id, keys) { parks << [loop_id, keys] })

      assert_equal :completed, follow.follow
      assert_equal "current-loop", follow.loop
      assert_equal [["current-loop", ["r1t1"]]], parks
      assert_equal ["r1t1"], follow.decided
      assert_equal %w[snapshot text_delta task_status attention_required turn_status closed], frames.map(&:first)
      assert_equal "completed", frames.find { |type, _| type == "task_status" }.last.fetch("status")
      assert_equal "  │ the current answer", output.string
    end

    def frame(type, payload)
      "event: #{type}\ndata: #{JSON.generate(payload)}\n\n"
    end
end
