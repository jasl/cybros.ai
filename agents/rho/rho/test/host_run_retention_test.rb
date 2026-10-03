require "test_helper"

# Read the real public documents through the SDK. Only transport timing and
# the raw socket are scripted; HostRun and KernelFeed own their normal state.
class HostRunRetentionTest < Minitest::Test
  class Api < NexusDoubles::FakeAgentApi
    attr_accessor :on_events, :on_turns, :on_loop, :retained_events, :missing_deck, :missing_loop
    attr_writer :turns, :conversation_event_head

    def initialize(retained_events: [], conversation_event_head: nil, **options)
      super(conversation_events: -> { @retained_events }, conversation_event_head: conversation_event_head, **options)
      @retained_events = retained_events
    end

    def call(path, **options)
      if @missing_deck && path.end_with?("/variants")
        return respond(404, { "error" => { "code" => "not_found", "message" => "Turn not found" } })
      end
      if path.end_with?("/agent_loops/al-7")
        return respond(404, { "error" => { "code" => "not_found", "message" => "Loop not found" } }) if @missing_loop

        callback, @on_loop = @on_loop, nil
        callback&.call
      end
      if path.end_with?("/events")
        callback, @on_events = @on_events, nil
        callback&.call
        if path.include?("/agent_loops/")
          @requests << [path, options[:credential], options[:params]]
          head = @retained_events.last&.fetch("sequence") || 0
          @conversation_event_head = [@conversation_event_head, head].max if @conversation_event_head
          return respond(200, { "events" => @retained_events,
            "pagination" => { "next_after" => nil,
              "watermark" => @conversation_event_head || head } })
        end
      end
      if path.end_with?("/turns")
        response = super
        callback, @on_turns = @on_turns, nil
        callback&.call
        return response
      end
      super
    end
  end

  class Socket
    def each
      Fiber.yield until @closed
    end

    def unsubscribe = @closed = true
  end

  class Realtime
    attr_reader :subscriptions

    def initialize = @subscriptions = []
    def connect_for_feed = nil

    def subscribe(channel:, params:, timeout:)
      @subscriptions << [channel, params]
      Socket.new
    end
  end

  def teardown
    @run&.stop
    @reader.resume if @reader&.alive?
  end

  def test_a_task_only_suffix_recovers_the_earlier_completed_tasks_and_terminal_turn
    api = history(retained_events: [event(41, "task_status", task_key: "work", kind: "model_task",
      status: "completed", turn_public_id: "t-7", agent_loop_public_id: "al-7")])
    follow(api)

    assert_equal "completed", @run.snapshot.status
    assert_equal %w[before work], @run.snapshot.tasks.map(&:task_key)
    assert_equal "The retained answer.", @run.snapshot.text
    assert_equal 1, @completed.length
    assert_equal %w[before work], @completed.first.tasks.map(&:task_key)
  end

  def test_terminal_suffix_does_not_publish_completion_before_restoring_the_missing_tasks
    api = history(retained_events: [terminal_event(42)])
    follow(api)

    assert_equal 1, @completed.length
    assert_equal %w[before work], @completed.first.tasks.map(&:task_key)
    assert_equal "The retained answer.", @completed.first.text
    assert_equal 42, @run.event_position.sequence
  end

  def test_a_late_background_loop_note_does_not_choose_an_older_turn_as_current
    api = history(newer_completed: true, retained_events: [event(41, "turn_status",
      loop_status: "completed", turn_public_id: "t-7", agent_loop_public_id: "al-7")])
    follow(api)

    assert_equal ["t-8", "al-8", "completed"], [@run.snapshot.turn, @run.snapshot.loop, @run.snapshot.status]
    assert_equal "The newer answer.", @run.snapshot.text
    assert_equal %w[before work], @run.snapshot.tasks.map(&:task_key)
  end

  def test_full_contiguous_replay_uses_no_durable_recovery_reads_and_keeps_the_original_poll_boundary
    api = history(retained_events: [terminal_event(1)])
    follow(api)

    assert_equal "completed", @run.snapshot.status
    assert_empty @run.snapshot.tasks
    assert_equal 1, @completed.length
    assert_equal 1, api.requests.count { |path, *| path.end_with?("/events") }
    refute api.requests.any? { |path, *| path.end_with?("/turns", "/variants", "/agent_loops/al-7") }
  end

  def test_a_new_turn_started_during_recovery_is_consumed_on_the_next_pass
    api = history
    api.on_turns = lambda do
      api.retained_events = [terminal_event(41), event(42, "turn_status", status: "running",
        loop_status: "running", turn_public_id: "t-8", variant_public_id: "v-8", agent_loop_public_id: "al-8"),
        event(43, "task_status", task_key: "new", kind: "model_task", status: "running",
          turn_public_id: "t-8", variant_public_id: "v-8", agent_loop_public_id: "al-8")]
    end
    follow(api)
    assert_equal "t-7", @run.snapshot.turn

    @reader.resume

    assert_equal ["t-8", "al-8", "running"], [@run.snapshot.turn, @run.snapshot.loop, @run.snapshot.status]
    assert_equal ["new"], @run.snapshot.tasks.map(&:task_key)
    assert_empty @run.snapshot.text
    refute @run.turn_settled?
    assert_equal 1, api.turn_windows.length, "history recovery runs only once at adoption"
  end

  def test_a_hidden_current_turn_retains_execution_control_instead_of_selecting_an_older_visible_answer
    api = history(current: "t-8", hidden: true, status: "running", loop_status: "running")
    follow(api)

    assert_equal ["t-8", "al-8", "running"], [@run.snapshot.turn, @run.snapshot.loop, @run.snapshot.status]
    assert_equal %w[before work], @run.snapshot.tasks.map(&:task_key)
    assert_empty @run.snapshot.text
    assert_empty @completed
    refute @run.turn_settled?
  end

  def test_a_hidden_held_turn_with_no_active_pointer_is_recovered_without_revealing_its_body
    api = history(hidden: true, status: "failed", loop_status: "needs_attention")
    follow(api)

    assert_equal ["t-8", "al-8", "failed"], [@run.snapshot.turn, @run.snapshot.loop, @run.snapshot.status]
    assert_equal "needs_attention", @run.snapshot.loop_status
    assert_equal ["work"], @run.snapshot.attention.blocked_task_keys
    assert_empty @run.snapshot.text
    assert_empty @completed
    refute @run.turn_settled?
    assert_equal "true", api.turn_windows.last.fetch("include_hidden").to_s
  end

  def test_a_background_gap_on_the_same_settled_execution_does_not_publish_completion_again
    api = history(retained_events: [terminal_event(1)])
    follow(api)
    assert_equal 1, @completed.length
    api.retained_events = [event(5, "turn_status", loop_status: "completed",
      turn_public_id: "t-7", agent_loop_public_id: "al-7")]

    @reader.resume

    assert_equal "The retained answer.", @run.snapshot.text
    assert_equal 1, @completed.length
    assert_equal 1, api.turn_windows.length
  end

  def test_an_expired_removal_clears_the_projection_when_no_readable_execution_remains
    api = history
    moved = []
    follow(api, on_turn: ->(run) { moved << run.snapshot.turn })
    assert_equal "The retained answer.", @run.snapshot.text
    assert_equal ["t-7"], moved
    api.turns = []
    api.conversation_event_head = 41

    @reader.resume

    snapshot = @run.snapshot
    assert_nil snapshot.turn
    assert_nil snapshot.loop
    assert_nil snapshot.loop_status
    assert_equal "pending", snapshot.status
    assert_empty snapshot.text
    assert_empty snapshot.tasks
    refute snapshot.complete
    assert_equal ["t-7", nil], moved
    assert_equal 1, @completed.length, "losing a readable execution is not another completion"
    assert @reader.alive?, "the conversation still follows future turns"
  end

  def test_regeneration_recovers_the_running_candidate_while_the_old_answer_remains_active
    api = history(current: "t-7", status: "running", loop_status: "running", regenerating: true)
    follow(api)

    assert_equal ["al-8", "running"], [@run.snapshot.loop, @run.snapshot.status]
    assert_equal "running", @run.snapshot.loop_status
    assert_empty @run.snapshot.text
    refute @run.turn_settled?
  end

  def test_a_failed_turn_on_a_held_loop_remains_actionable_after_all_events_expire
    api = history(status: "failed", loop_status: "needs_attention")
    follow(api)

    assert_equal ["failed", "needs_attention"], [@run.snapshot.status, @run.snapshot.loop_status]
    assert_equal ["work"], @run.snapshot.attention.blocked_task_keys
    assert @run.snapshot.complete
    refute @run.turn_settled?
    assert_empty @completed
  end

  def test_a_loopless_failed_answer_is_settled_after_its_events_expire
    api = history(status: "failed", loopless: true)
    follow(api)

    assert @run.turn_settled?
    assert_equal "failed", @run.snapshot.status
    assert_nil @run.snapshot.loop
    assert_nil @run.snapshot.loop_status
    assert_equal "The retained answer.", @run.snapshot.text
    assert_equal 1, @completed.length
  end

  def test_a_failed_answer_outlives_its_deleted_terminal_execution_trace
    api = history(status: "failed", loop_status: "canceled")
    api.missing_loop = true
    follow(api)

    assert @run.turn_settled?
    assert_equal "failed", @run.snapshot.status
    assert_nil @run.snapshot.loop
    assert_nil @run.snapshot.loop_status, "do not fabricate a terminal loop status for a deleted row"
    assert_equal "The retained answer.", @run.snapshot.text
    assert_equal 1, @completed.length
  end

  def test_a_turn_removed_between_timeline_and_deck_reads_does_not_end_its_host
    api = history(retained_events: [terminal_event(42)])
    api.missing_deck = true
    ended = []
    follow(api, on_ended: ->(run) { ended << run.public_id })

    assert_empty ended
    assert @reader.alive?
    assert_empty @run.snapshot.text
    api.retained_events = [event(43, "turn_status", status: "running", loop_status: "running",
      turn_public_id: "t-8", variant_public_id: "v-8", agent_loop_public_id: "al-8")]
    @reader.resume

    assert_equal ["t-8", "running"], [@run.snapshot.turn, @run.snapshot.status]
    assert_empty ended
  end

  def test_an_empty_new_conversation_still_accepts_its_first_later_turn
    api = Api.new(turns: [])
    follow(api)
    assert_equal "pending", @run.snapshot.status
    assert_nil @run.snapshot.turn
    assert_empty @completed
    api.retained_events = [event(1, "turn_status", status: "running", loop_status: "running",
      turn_public_id: "t-8", variant_public_id: "v-8", agent_loop_public_id: "al-8")]
    @reader.resume

    assert_equal ["t-8", "running"], [@run.snapshot.turn, @run.snapshot.status]
    assert_equal 1, api.turn_windows.length, "an initial empty replay reads durable state only once"
  end

  def test_a_forked_answer_is_restored_even_when_the_child_has_never_allocated_an_event
    variant = { "public_id" => "v-7", "source" => "fork", "status" => "completed",
      "content" => "The copied answer.", "content_preview" => "The copied answer.", "active" => true }
    turn = { "public_id" => "t-7", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
      "status" => "completed", "visibility" => "visible", "inherited" => false,
      "answering_user_public_id" => "0199-user", "created_at" => "2026-09-22T00:00:00Z",
      "active_variant" => variant }
    api = Api.new(turns: [turn], conversation_event_head: 0,
      variants: { "turn" => { "public_id" => "t-7", "inherited" => false }, "variants" => [variant] })

    follow(api)

    assert_equal ["t-7", "completed"], [@run.snapshot.turn, @run.snapshot.status]
    assert_nil @run.snapshot.loop, "a copied fork candidate does not clone the source execution"
    assert_equal "The copied answer.", @run.snapshot.text
    assert @run.turn_settled?
    assert_equal 1, @completed.length
    assert_equal 0, @run.event_position.sequence
    assert_nil @run.event_position.cursor
    assert_equal 1, api.turn_windows.length

    3.times { @reader.resume }

    assert_equal 1, api.turn_windows.length, "the same empty stream must not repeat the initial state read"
    assert_equal 1, @completed.length
  end

  def test_an_independent_loop_with_no_events_recovers_its_held_state
    api = history(status: "failed", loop_status: "needs_attention", standalone: true)
    follow(api, standalone: true)

    assert_equal ["failed", "needs_attention"], [@run.snapshot.status, @run.snapshot.loop_status]
    assert_equal %w[before work], @run.snapshot.tasks.map(&:task_key)
    assert_equal ["work"], @run.snapshot.attention.blocked_task_keys
    refute @run.settled?
    assert_empty @completed
  end

  def test_an_independent_loop_terminal_suffix_restores_tasks_before_ending_the_follower
    terminal = event(42, "turn_status", status: "completed", loop_status: "completed",
      agent_loop_public_id: "al-7")
    api = history(retained_events: [terminal], standalone: true)
    follow(api, standalone: true)

    assert @run.settled?
    refute @reader.alive?
    assert_equal 1, @completed.length
    assert_equal %w[before work], @completed.first.tasks.map(&:task_key)
  end

  def test_opening_watch_during_initial_rest_drain_only_changes_the_subscription_intent
    realtime = Realtime.new
    api = history
    api.on_events = -> { Fiber.yield }
    follow(api, realtime: realtime, live: false)
    assert_empty realtime.subscriptions

    assert @run.attach_socket
    @reader.resume

    assert_equal "completed", @run.snapshot.status
    assert_equal "The retained answer.", @run.snapshot.text
    assert_equal 1, realtime.subscriptions.length
    refute realtime.subscriptions.first.last.key?(:items)
  end

  def test_a_transient_read_after_a_standalone_terminal_retries_before_completing
    terminal = event(42, "turn_status", status: "completed", loop_status: "completed",
      agent_loop_public_id: "al-7")
    api = history(retained_events: [terminal], standalone: true)
    api.on_loop = -> { raise CybrosAgent::Api::RateLimited.new(retry_after: 1) }
    follow(api, standalone: true)
    assert_empty @completed
    assert @reader.alive?

    @reader.resume

    refute @reader.alive?
    assert_equal 1, @completed.length
    assert_equal %w[before work], @completed.first.tasks.map(&:task_key)
  end

  def test_closing_watch_during_initial_rest_drain_preserves_recovery_and_narrows_the_later_subscription
    realtime = Realtime.new
    api = history
    api.on_events = -> { Fiber.yield }
    follow(api, realtime: realtime)
    assert_empty realtime.subscriptions

    assert @run.detach_socket
    @reader.resume

    assert_equal "completed", @run.snapshot.status
    assert_equal "The retained answer.", @run.snapshot.text
    assert_equal 1, realtime.subscriptions.length
    assert_equal "lifecycle", realtime.subscriptions.first.last.fetch(:items)
  end

  private

    def follow(api, standalone: false, **options)
      workspace = CybrosAgent::Client.new(base_url: "https://nexus.example",
        credential: NexusDoubles::MEMBER_TOKEN, transport: api).workspace("ws-1")
      host = standalone ? Rho::Host::AgentLoop.new(public_id: "al-7") :
        Rho::Host::Conversation.new(public_id: "c-7")
      context = standalone ? workspace.agent_loop("al-7") : workspace.conversations.conversation("c-7")
      @completed = []
      @run = Rho::HostRun.new(host: host, context: context, sleeper: ->(_) { Fiber.yield },
        on_complete: ->(run) { @completed << run.snapshot },
        loop_context: ->(id) { workspace.agent_loop(id) }, **options)
      @reader = Fiber.new { @run.follow }
      @reader.resume
    end

    def event(sequence, type, **payload)
      { "public_id" => "ev-#{sequence}", "sequence" => sequence, "cursor" => "c#{sequence}", "type" => type,
        "resource" => { "type" => "conversation", "public_id" => "c-7" },
        "occurred_at" => "2026-09-21T00:00:00Z", "payload" => payload.transform_keys(&:to_s) }
    end

    def terminal_event(sequence)
      event(sequence, "turn_status", status: "completed", loop_status: "completed", turn_public_id: "t-7",
        variant_public_id: "v-7", agent_loop_public_id: "al-7")
    end

    def history(retained_events: [], current: nil, status: "completed", loop_status: "completed",
                hidden: false, regenerating: false, standalone: false, newer_completed: false, loopless: false)
      variant = { "public_id" => "v-7", "source" => "agent_loop", "status" => status,
        "content" => "The retained answer.", "content_preview" => "The retained answer.",
        "agent_loop_public_id" => "al-7", "active" => true }
      variant = variant.except("agent_loop_public_id").merge("source" => "inference") if loopless
      turn = { "public_id" => "t-7", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
        "status" => status, "visibility" => "visible", "inherited" => false,
        "answering_user_public_id" => "0199-user", "created_at" => "2026-08-01T00:00:00Z",
        "active_variant" => variant }
      variants = [variant]
      loop_id = "al-7"
      if hidden || regenerating
        loop_id = "al-8"
        old_answer = variant.merge("status" => "completed")
        candidate = variant.merge("public_id" => "v-8", "agent_loop_public_id" => loop_id,
          "active" => hidden, "status" => status)
        variants = hidden ? [candidate] : [old_answer, candidate]
        turn = turn.merge("active_variant" => old_answer)
        turn = turn.merge("status" => "completed") if hidden
      end
      trace = NexusDoubles::RUNNING_TRACE.merge("public_id" => loop_id, "status" => loop_status,
        "tasks" => [NexusDoubles::RUNNING_TRACE.fetch("tasks").first.merge("key" => "before", "status" => "completed"),
          NexusDoubles::RUNNING_TRACE.fetch("tasks").first.merge("status" => status)],
        "turn" => { "status" => status, "public_id" => (current || "t-7" unless standalone),
          "conversation_public_id" => ("c-7" unless standalone) }.compact)
      trace["attention"] = { "reason" => "halt_failure", "blocked_task_keys" => ["work"] } if loop_status == "needs_attention"
      turns = [turn]
      if hidden
        turns << turn.merge("public_id" => "t-8", "position" => 1, "status" => status,
          "visibility" => "hidden", "active_variant" => variants.last)
        trace = trace.merge("turn" => trace.fetch("turn").merge("public_id" => "t-8"))
      end
      if newer_completed
        variants = [variant.merge("public_id" => "v-8", "agent_loop_public_id" => "al-8", "content" => "The newer answer.")]
        turns << turn.merge("public_id" => "t-8", "position" => 1, "active_variant" => variants.first)
        trace = trace.merge("public_id" => "al-8", "turn" => trace.fetch("turn").merge("public_id" => "t-8"))
      end
      head = retained_events.empty? ? 40 : retained_events.last.fetch("sequence")
      Api.new(trace: trace, turns: turns, retained_events: retained_events, conversation_busy: current,
        conversation_event_head: head,
        variants: { "turn" => { "public_id" => current || turns.last.fetch("public_id"), "inherited" => false }, "variants" => variants })
    end
end
