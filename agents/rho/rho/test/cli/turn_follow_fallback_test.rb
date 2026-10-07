require "test_helper"

class TurnFollowFallbackTest < Minitest::Test
  class Core < Rho::Core
    attr_reader :variant_reads

    def initialize(live: false, expired: false, manual: false)
      @live = live
      @expired = expired
      @manual = manual
      @variant_reads = 0
    end

    def follower_events(_id, deadline: nil)
      if @live
        yield "snapshot", { "turn" => "mine", "variant" => "original", "status" => "running", "complete" => false }
        yield "turn_variant", { "turn_public_id" => "mine", "variant_public_id" => "fallback", "regenerating" => true }
        3.times do
          yield "turn_status", { "turn_public_id" => "mine", "variant_public_id" => "original",
            "status" => "running", "variant_status" => "failed" }
        end
        yield "text_delta", { "text" => "fallback answer" }
        yield "turn_status", { "turn_public_id" => "mine", "variant_public_id" => "fallback", "status" => "completed" }
        yield "closed", {}
      else
        yield "snapshot", { "turn" => "mine", "variant" => "fallback", "status" => "completed",
          "text" => "fallback answer", "complete" => true }
        yield "closed", {}
      end
    end

    def host_events(_id, after: nil)
      items = if @expired || after
        []
      else
        [CybrosAgent::Api::ConversationEvent.new(sequence: 1, cursor: "c1", type: "turn_status", public_id: "ev1",
          resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-20T00:00:00Z",
          payload: { "turn_public_id" => "mine", "variant_public_id" => "original", "status" => "running", "variant_status" => "failed" }),
         CybrosAgent::Api::ConversationEvent.new(sequence: 2, cursor: "c2", type: "turn_status", public_id: "ev2",
           resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-20T00:00:01Z",
           payload: { "turn_public_id" => "mine", "variant_public_id" => "fallback", "status" => "completed" })]
      end
      CybrosAgent::Api::ConversationEventPage.new(items: items, next_after: nil, watermark: 2)
    end

    def follower_row(_id)
      { "turn" => "mine", "variant" => "fallback", "status" => "completed" }
    end

    def variants(_id, _turn)
      @variant_reads += 1
      original = { "public_id" => "original", "source" => "inference", "status" => "failed", "active" => false, "content" => "" }
      fallback = { "public_id" => "fallback", "source" => "fallback", "status" => "completed", "active" => true,
        "origin_variant_public_id" => (@manual ? "manual" : "original"), "content" => "fallback answer" }
      if @manual
        original["status"] = "completed"
        original["content"] = "original answer"
        [original, { "public_id" => "manual", "source" => "inference", "status" => "failed", "active" => false,
                     "origin_variant_public_id" => "original", "content" => "" }, fallback]
      else
        [original, fallback]
      end
    end
  end

  def test_live_automatic_fallback_continues_the_same_input_without_repeated_deck_reads
    core = Core.new(live: true)
    frames = []
    follow = Rho::Cli::TurnFollow.new(core: core, conversation: "conversation", turn: "mine", variant: "original",
      deadline: 0.1, on_frame: ->(type, payload) { frames << [type, payload] })

    assert_equal :completed, follow.follow
    assert_equal "fallback", follow.variant
    assert_equal ["fallback answer"], frames.select { |type, _| type == "text_delta" }.map { |_, payload| payload.fetch("text") }
    assert_equal 1, core.variant_reads
  end

  def test_a_fallback_snapshot_is_the_original_inputs_answer_with_retained_or_expired_events
    [false, true].each do |expired|
      frames = []
      follow = Rho::Cli::TurnFollow.new(core: Core.new(expired: expired), conversation: "conversation", turn: "mine",
        variant: "original", deadline: 0.1, on_frame: ->(type, payload) { frames << [type, payload] })

      assert_equal :completed, follow.follow
      assert_equal "fallback", follow.variant
      assert_equal ["fallback answer"], frames.select { |type, _| type == "snapshot" }.map { |_, payload| payload.fetch("text") }
    end
  end

  def test_a_manual_regenerations_fallback_cannot_replace_the_original_inputs_answer
    frames = []
    follow = Rho::Cli::TurnFollow.new(core: Core.new(expired: true, manual: true), conversation: "conversation", turn: "mine",
      variant: "original", deadline: 0.1, on_frame: ->(type, payload) { frames << [type, payload] })

    assert_equal :completed, follow.follow
    assert_equal "original", follow.variant
    assert_equal ["original answer"], frames.select { |type, _| type == "snapshot" }.map { |_, payload| payload.fetch("text") }
  end

  class SuccessorCore < Core
    def follower_events(_id, deadline: nil)
      yield "snapshot", { "turn" => "next-turn", "variant" => "next-variant", "status" => "running", "complete" => false }
      yield "closed", {}
    end
  end

  def test_recovery_after_the_next_turn_started_follows_only_the_originals_fallback
    [false, true].each do |expired|
      frames = []
      follow = Rho::Cli::TurnFollow.new(core: SuccessorCore.new(expired: expired), conversation: "conversation", turn: "mine",
        variant: "original", deadline: 0.1, on_frame: ->(type, payload) { frames << [type, payload] })

      assert_equal :completed, follow.follow
      assert_equal "fallback", follow.variant
      assert_equal ["fallback answer"], frames.select { |type, _| type == "snapshot" }.map { |_, payload| payload.fetch("text") }
    end
  end
end
