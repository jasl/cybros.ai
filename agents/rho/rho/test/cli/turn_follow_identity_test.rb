require "test_helper"

class TurnFollowIdentityTest < Minitest::Test
  Event = CybrosAgent::Api::ConversationEvent
  Page = CybrosAgent::Api::ConversationEventPage

  class Core < Rho::Core
    def initialize = nil

    def variants(_id, turn)
      raise "wrong turn" unless turn == "mine"

      [{ "run_public_id" => "my-run", "active" => true, "content" => "my sealed answer" }]
    end

    def follower_row(_id)
      { "turn" => "later", "run_public_id" => "later-run", "status" => "completed", "run_status" => "completed" }
    end

    def follower_events(_id, deadline: nil)
      yield "snapshot", { "turn" => "later", "run_public_id" => "later-run", "complete" => false,
        "text" => "another answer", "attention" => { "reason" => "approval_required", "blocked_task_keys" => ["r1t1"] } }
    end

    def host_events(_id, after: nil)
      items = [Event.new(sequence: 1, cursor: "c1", type: "turn_status", public_id: "ev1",
        resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-20T00:00:00Z",
        payload: { "turn_public_id" => "mine", "run_public_id" => "my-run", "status" => "completed", "run_status" => "completed" })]
      Page.new(items: after ? [] : items, next_after: nil, watermark: 1)
    end
  end

  def test_a_join_after_the_next_turn_started_never_renders_or_approves_that_turn
    frames = []
    parks = []
    follow = Rho::Cli::TurnFollow.new(core: Core.new, conversation: "conversation", turn: "mine", run_public_id: "my-run",
      on_frame: ->(type, payload) { frames << [type, payload] }, on_park: ->(run_public_id, keys) { parks << [run_public_id, keys] })

    assert_equal :completed, follow.follow
    assert_equal "my-run", follow.run_public_id
    assert_empty parks
    assert_equal ["snapshot"], frames.map(&:first)
    assert_equal "my sealed answer", frames.first.last.fetch("text")
    assert_equal "mine", frames.first.last.fetch("turn")
  end

  class OtherVariantCore < Core
    def follower_events(_id, deadline: nil)
      yield "snapshot", { "turn" => "mine", "run_public_id" => "other-variant", "complete" => false,
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

  def test_a_join_after_another_variant_started_never_renders_or_approves_that_run
    frames = []
    parks = []
    follow = Rho::Cli::TurnFollow.new(core: OtherVariantCore.new, conversation: "conversation", turn: "mine", run_public_id: "my-run",
      on_frame: ->(type, payload) { frames << [type, payload] }, on_park: ->(run_public_id, keys) { parks << [run_public_id, keys] })

    assert_equal :completed, follow.follow
    assert_equal "my-run", follow.run_public_id
    assert_empty parks
    assert_equal ["snapshot"], frames.map(&:first)
    assert_equal "my sealed answer", frames.first.last.fetch("text")
    assert_equal "mine", frames.first.last.fetch("turn")
    assert_equal "my-run", frames.first.last.fetch("run_public_id")
  end

  class LaggingCore < Core
    def follower_events(_id, deadline: nil)
      yield "snapshot", { "turn" => "earlier", "run_public_id" => "earlier-run", "text" => "old answer" }
      yield "text_delta", { "text" => "old tail" }
      yield "turn_status", { "turn_public_id" => "mine", "run_public_id" => "my-run", "status" => "running" }
      yield "text_delta", { "text" => "my answer" }
      yield "turn_status", { "turn_public_id" => "mine", "run_public_id" => "my-run", "status" => "completed" }
      yield "closed", {}
    end

    def host_events(_id, after: nil)
      items = [Event.new(sequence: 1, cursor: "c1", type: "turn_status", public_id: "ev1",
        resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-20T00:00:00Z",
        payload: { "turn_public_id" => "mine", "run_public_id" => "my-run", "status" => "running" })]
      Page.new(items: after ? [] : items, next_after: nil, watermark: 1)
    end
  end

  def test_a_follower_behind_the_receipt_waits_for_its_turn_and_ignores_old_text
    frames = []
    follow = Rho::Cli::TurnFollow.new(core: LaggingCore.new, conversation: "conversation", turn: "mine", run_public_id: "my-run",
      on_frame: ->(type, payload) { frames << [type, payload] })
    assert_equal :completed, follow.follow
    assert_equal ["my answer"], frames.select { |type, _| type == "text_delta" }.map { |_, payload| payload.fetch("text") }
    assert_equal "my-run", follow.run_public_id
  end

  class LateNoteCore < LaggingCore
    def follower_events(_id, deadline: nil)
      yield "snapshot", { "turn" => "mine", "run_public_id" => "my-run" }
      yield "turn_status", { "turn_public_id" => "earlier", "run_public_id" => "earlier-run", "run_status" => "completed" }
      yield "text_delta", { "text" => "my answer after the old run's note" }
      yield "turn_status", { "turn_public_id" => "mine", "run_public_id" => "my-run", "status" => "completed" }
      yield "closed", {}
    end
  end

  def test_a_late_note_from_an_old_run_cannot_steal_the_current_stream
    frames = []
    follow = Rho::Cli::TurnFollow.new(core: LateNoteCore.new, conversation: "conversation", turn: "mine", run_public_id: "my-run",
      on_frame: ->(type, payload) { frames << [type, payload] })
    assert_equal :completed, follow.follow
    assert_equal ["my answer after the old run's note"], frames.select { |type, _| type == "text_delta" }.map { |_, payload| payload.fetch("text") }
    assert_equal "my-run", follow.run_public_id
  end

  class DirectVariantCore < Core
    def initialize(expired: false, concealed: false)
      @expired = expired
      @concealed = concealed
    end

    def follower_events(_id, deadline: nil)
      yield "snapshot", { "turn" => "mine", "variant" => "replacement", "status" => "running",
        "text" => "the replacement's private preview", "complete" => false }
      yield "text_delta", { "text" => "not the requested answer" }
      yield "closed", {}
    end

    def host_events(_id, after: nil)
      items = if @expired || after
        []
      else
        [Event.new(sequence: 1, cursor: "c1", type: "turn_status", public_id: "ev1",
          resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-20T00:00:00Z",
          payload: { "turn_public_id" => "mine", "variant_public_id" => "original", "status" => "completed" }),
         Event.new(sequence: 2, cursor: "c2", type: "turn_status", public_id: "ev2",
           resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-20T00:00:01Z",
           payload: { "turn_public_id" => "mine", "variant_public_id" => "replacement", "status" => "running" })]
      end
      Page.new(items: items, next_after: nil, watermark: 2)
    end

    def variants(_id, _turn)
      original = { "public_id" => "original", "status" => "completed", "active" => false, "content" => "original sealed answer" }
      current = { "public_id" => "replacement", "status" => "running", "active" => true, "content" => "replacement" }
      @concealed ? [current] : [original, current]
    end
  end

  def test_a_direct_inference_follow_stays_on_its_variant_when_the_same_turn_regenerates
    frames = []
    follow = Rho::Cli::TurnFollow.new(core: DirectVariantCore.new, conversation: "conversation", turn: "mine", variant: "original",
      on_frame: ->(type, payload) { frames << [type, payload] })

    assert_equal :completed, follow.follow
    assert_equal "original", follow.variant
    assert_nil follow.run_public_id
    assert_equal ["snapshot"], frames.map(&:first)
    assert_equal "original sealed answer", frames.first.last.fetch("text")
    assert_equal "original", frames.first.last.fetch("variant")
  end

  def test_a_direct_inference_follow_recovers_its_original_variant_after_events_expire
    frames = []
    follow = Rho::Cli::TurnFollow.new(core: DirectVariantCore.new(expired: true), conversation: "conversation", turn: "mine", variant: "original",
      on_frame: ->(type, payload) { frames << [type, payload] })

    assert_equal :completed, follow.follow
    assert_equal "original", follow.variant
    assert_equal ["original sealed answer"], frames.map { |_, payload| payload.fetch("text") }
  end

  class BackgroundNoteCore < DirectVariantCore
    def host_events(_id, after: nil)
      note = Event.new(sequence: 99, cursor: "c99", type: "turn_status", public_id: "ev99",
        resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-20T00:00:00Z",
        payload: { "turn_public_id" => "mine", "variant_public_id" => "original",
          "run_public_id" => "original-run", "run_status" => "completed" })
      Page.new(items: after ? [] : [note], next_after: nil, watermark: 99)
    end

    def variants(id, turn)
      super.map { |variant| variant.merge("run_public_id" => "original-run") }
    end
  end

  def test_a_retained_background_note_does_not_replace_the_expired_turn_status
    frames = []
    follow = Rho::Cli::TurnFollow.new(core: BackgroundNoteCore.new, conversation: "conversation",
      turn: "mine", variant: "original", run_public_id: "original-run", on_frame: ->(type, payload) { frames << [type, payload] })

    assert_equal :completed, follow.follow
    assert_equal "completed", follow.run_status
    assert_equal ["original sealed answer"], frames.map { |_, payload| payload.fetch("text") }
  end

  class FailedVariantCore < DirectVariantCore
    attr_reader :result_reads

    def initialize(run_status: nil)
      super(expired: true)
      @run_status = run_status
      @result_reads = []
    end

    def variants(id, turn)
      super.map do |variant|
        variant.merge("status" => "failed", "run_public_id" => ("original-run" if @run_status))
      end
    end

    def result(run_id)
      raise "must read the original execution" unless run_id == "original-run"

      @result_reads << run_id
      { "public_id" => run_id, "status" => @run_status }
    end
  end

  def test_an_expired_failed_direct_inference_is_terminal_without_a_run_read
    core = FailedVariantCore.new
    follow = Rho::Cli::TurnFollow.new(core: core, conversation: "conversation", turn: "mine", variant: "original")

    assert_equal :failed, follow.follow
    assert_equal "failed", follow.status
    assert_empty core.result_reads
  end

  def test_an_expired_failed_candidate_uses_the_original_runs_current_status_to_distinguish_a_hold
    { "needs_attention" => :hold, "canceled" => :failed, "completed" => :failed }.each do |status, verdict|
      core = FailedVariantCore.new(run_status: status)
      follow = Rho::Cli::TurnFollow.new(core: core, conversation: "conversation", turn: "mine",
        variant: "original", run_public_id: "original-run")

      assert_equal verdict, follow.follow, status
      assert_equal status, follow.run_status
      assert_equal ["original-run"], core.result_reads
    end
  end

  def test_an_expired_concealed_original_is_never_replaced_with_the_new_candidate
    frames = []
    follow = Rho::Cli::TurnFollow.new(core: DirectVariantCore.new(expired: true, concealed: true),
      conversation: "conversation", turn: "mine", variant: "original", on_frame: ->(type, payload) { frames << [type, payload] })

    assert_equal :refused, follow.follow
    assert_equal "original", follow.variant
    assert_empty frames.select { |_, payload| payload.key?("text") }
  end
end
