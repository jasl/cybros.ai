require "test_helper"

class TurnFollowIdentityTest < Minitest::Test
  Event = CybrosAgent::Api::ConversationEvent
  Page = CybrosAgent::Api::ConversationEventPage

  class Core < Rho::Core
    def initialize = nil

    def variants(_id, turn)
      raise "wrong turn" unless turn == "mine"

      [{ "agent_loop_public_id" => "my-loop", "active" => true, "content" => "my sealed answer" }]
    end

    def loop_row(_id)
      { "turn" => "later", "loop" => "later-loop", "status" => "completed", "loop_status" => "completed" }
    end

    def loop_events(_id, deadline: nil)
      yield "snapshot", { "turn" => "later", "loop" => "later-loop", "complete" => false,
        "text" => "another answer", "attention" => { "reason" => "approval_required", "blocked_task_keys" => ["r1t1"] } }
    end

    def host_events(_id, after: nil)
      items = [Event.new(sequence: 1, cursor: "c1", type: "turn_status", public_id: "ev1",
        resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-20T00:00:00Z",
        payload: { "turn_public_id" => "mine", "agent_loop_public_id" => "my-loop", "status" => "completed", "loop_status" => "completed" })]
      Page.new(items: after ? [] : items, next_after: nil, watermark: 1)
    end
  end

  def test_a_join_after_the_next_turn_started_never_renders_or_approves_that_turn
    frames = []
    parks = []
    follow = Rho::Cli::TurnFollow.new(core: Core.new, conversation: "conversation", turn: "mine", loop: "my-loop",
      on_frame: ->(type, payload) { frames << [type, payload] }, on_park: ->(loop, keys) { parks << [loop, keys] })

    assert_equal :completed, follow.follow
    assert_equal "my-loop", follow.loop
    assert_empty parks
    assert_equal ["snapshot"], frames.map(&:first)
    assert_equal "my sealed answer", frames.first.last.fetch("text")
    assert_equal "mine", frames.first.last.fetch("turn")
  end

  class OtherVariantCore < Core
    def loop_events(_id, deadline: nil)
      yield "snapshot", { "turn" => "mine", "loop" => "other-variant", "complete" => false,
        "text" => "another variant's answer", "attention" => { "reason" => "approval_required", "blocked_task_keys" => ["r1t1"] } }
    end

    def host_events(id, after: nil)
      page = super
      return page if after

      reopened = Event.new(sequence: 2, cursor: "c2", type: "turn_status", public_id: "ev2",
        resource_type: "conversation", resource_public_id: id, occurred_at: "2026-09-20T00:00:01Z",
        payload: { "turn_public_id" => "mine", "variant_public_id" => "new-variant", "status" => "running" })
      Page.new(items: [*page.items, reopened], next_after: nil, watermark: 2)
    end
  end

  def test_a_join_after_another_variant_started_never_renders_or_approves_that_loop
    frames = []
    parks = []
    follow = Rho::Cli::TurnFollow.new(core: OtherVariantCore.new, conversation: "conversation", turn: "mine", loop: "my-loop",
      on_frame: ->(type, payload) { frames << [type, payload] }, on_park: ->(loop, keys) { parks << [loop, keys] })

    assert_equal :completed, follow.follow
    assert_equal "my-loop", follow.loop
    assert_empty parks
    assert_equal ["snapshot"], frames.map(&:first)
    assert_equal "my sealed answer", frames.first.last.fetch("text")
    assert_equal "mine", frames.first.last.fetch("turn")
    assert_equal "my-loop", frames.first.last.fetch("loop")
  end

  class LaggingCore < Core
    def loop_events(_id, deadline: nil)
      yield "snapshot", { "turn" => "earlier", "loop" => "earlier-loop", "text" => "old answer" }
      yield "text_delta", { "text" => "old tail" }
      yield "turn_status", { "turn_public_id" => "mine", "agent_loop_public_id" => "my-loop", "status" => "running" }
      yield "text_delta", { "text" => "my answer" }
      yield "turn_status", { "turn_public_id" => "mine", "agent_loop_public_id" => "my-loop", "status" => "completed" }
      yield "closed", {}
    end

    def host_events(_id, after: nil)
      items = [Event.new(sequence: 1, cursor: "c1", type: "turn_status", public_id: "ev1",
        resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-20T00:00:00Z",
        payload: { "turn_public_id" => "mine", "agent_loop_public_id" => "my-loop", "status" => "running" })]
      Page.new(items: after ? [] : items, next_after: nil, watermark: 1)
    end
  end

  def test_a_follower_behind_the_receipt_waits_for_its_turn_and_ignores_old_text
    frames = []
    follow = Rho::Cli::TurnFollow.new(core: LaggingCore.new, conversation: "conversation", turn: "mine", loop: "my-loop",
      on_frame: ->(type, payload) { frames << [type, payload] })
    assert_equal :completed, follow.follow
    assert_equal ["my answer"], frames.select { |type, _| type == "text_delta" }.map { |_, payload| payload.fetch("text") }
    assert_equal "my-loop", follow.loop
  end

  class LateNoteCore < LaggingCore
    def loop_events(_id, deadline: nil)
      yield "snapshot", { "turn" => "mine", "loop" => "my-loop" }
      yield "turn_status", { "turn_public_id" => "earlier", "agent_loop_public_id" => "earlier-loop", "loop_status" => "completed" }
      yield "text_delta", { "text" => "my answer after the old loop's note" }
      yield "turn_status", { "turn_public_id" => "mine", "agent_loop_public_id" => "my-loop", "status" => "completed" }
      yield "closed", {}
    end
  end

  def test_a_late_note_from_an_old_loop_cannot_steal_the_current_stream
    frames = []
    follow = Rho::Cli::TurnFollow.new(core: LateNoteCore.new, conversation: "conversation", turn: "mine", loop: "my-loop",
      on_frame: ->(type, payload) { frames << [type, payload] })
    assert_equal :completed, follow.follow
    assert_equal ["my answer after the old loop's note"], frames.select { |type, _| type == "text_delta" }.map { |_, payload| payload.fetch("text") }
    assert_equal "my-loop", follow.loop
  end
end
