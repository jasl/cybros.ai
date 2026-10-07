require "support/runtime"

class TelegramTaskRoutingRaceTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_completion_visible_during_the_history_read_keeps_its_request_association
    @bridge.defer_inputs = true
    @runtime.consume(mention(1))
    completed = turn(0, "Completed while history was being read")
    events = materialized(1, input: "input-1", position: 0, run_public_id: "original-loop")
    original = @bridge.method(:turns)
    @bridge.define_singleton_method(:turns) do |id, **options|
      @event_rows[id] = events
      @turn_rows[id] = [completed]
      original.call(id, **options)
    end

    @runtime.tick
    assert_equal 0, tracker.fetch("position")
    assert_equal "telegram:42:1:input", @state.read.fetch("messages").fetch("-10:4:#{@client.last_message_id}")
    advance
    sent = sent_answer(completed.fetch("text"))
    assert_equal({ message_id: 1, allow_sending_without_reply: true }, sent.fetch(:reply_parameters))
    assert_equal "original-loop", @state.read.fetch("requests").fetch("telegram:42:1:input").fetch("run_id")
  end

  def test_newer_history_waits_while_an_earlier_page_catches_up_with_its_events
    prepare_backlog
    @runtime.tick
    assert_nil tracker.fetch("position")
    refute @state.read.fetch("deliveries").key?("turn:conversation-1:turn-0:conversation-1-variant-0")

    expose_later_completion
    advance
    assert_equal 0, tracker.fetch("position"), "the first page cannot publish a later unlinked turn"
    refute @state.read.fetch("deliveries").key?("turn:conversation-1:turn-1:conversation-1-variant-1")
    refute @client.calls.any? { |method, params| method == "sendMessage" && params[:text] == "Second answer" }

    3.times { advance }
    assert_equal 1, tracker.fetch("position")
    assert_equal 1, sent_answer("First answer").fetch(:reply_parameters).fetch(:message_id)
    assert_equal 2, sent_answer("Second answer").fetch(:reply_parameters).fetch(:message_id)
  end

  def test_restart_does_not_publish_new_history_using_the_previous_pages_watermark
    prepare_backlog
    @runtime.tick
    expose_later_completion
    @runtime = runtime

    advance
    assert_nil tracker.fetch("position"), "the fresh history page needs all its materialization events"
    refute @state.read.fetch("deliveries").keys.any? { |key| key.start_with?("turn:") }
    4.times { advance }

    assert_equal 1, tracker.fetch("position")
    assert_equal 1, sent_answer("First answer").fetch(:reply_parameters).fetch(:message_id)
    assert_equal 2, sent_answer("Second answer").fetch(:reply_parameters).fetch(:message_id)
  end

  def test_completion_during_event_paging_is_delivered_on_the_next_history_pass
    prepare_backlog
    @bridge.turn_rows["conversation-1"] = [turn(0, "", status: "running")]
    @runtime.tick
    assert_nil tracker.fetch("position")

    @bridge.turn_rows["conversation-1"] = [turn(0, "Completed during event paging")]
    @bridge.current = @bridge.current.merge("sequence" => 2, "status" => "completed", "complete" => true)
    advance
    assert_nil tracker.fetch("position"), "the retained history page still contains the running turn"

    advance
    assert_equal 0, tracker.fetch("position"), "the completion must not wait for the quiet-history fallback"
    advance
    assert_equal 1, sent_answer("Completed during event paging").fetch(:reply_parameters).fetch(:message_id)
  end

  def test_lost_acceptance_response_recovers_original_and_supplementary_reply_links
    @bridge.defer_inputs = true
    @bridge.fail_input = true
    update = mention(1)
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    @bridge.event_rows["conversation-1"] = materialized(1, input: "input-1", position: 0, run_public_id: "original-loop") + [
      event(3, "input_accepted", "input_public_id" => "supplement-input", "origin" => "task_result",
        "run_public_id" => "original-loop"),
    ] + materialized(4, input: "supplement-input", position: 1, run_public_id: "supplement-loop")
    @bridge.turn_rows["conversation-1"] = [turn(0, "Original answer"), turn(1, "Supplementary answer")]

    @runtime.tick
    assert_nil tracker.fetch("position")
    refute @state.read.fetch("deliveries").keys.any? { |key| key.start_with?("turn:") }
    @runtime = runtime
    @runtime.consume(update)
    3.times { advance }

    document = @state.read
    request_id = "telegram:42:1:input"
    assert_equal 1, @bridge.inputs.length, "the lost response reuses the original input key"
    assert_equal "original-loop", document.fetch("requests").fetch(request_id).fetch("run_id")
    assert_equal request_id, document.fetch("work").fetch("supplement-input").fetch("request_id")
    assert_equal 1, sent_answer("Original answer").fetch(:reply_parameters).fetch(:message_id)
    assert_equal 1, sent_answer("Supplementary answer").fetch(:reply_parameters).fetch(:message_id)
    message_id = document.fetch("messages").keys.select { |key| document.fetch("messages").fetch(key) == request_id }
      .map { |key| key.split(":").last.to_i }.max
    @runtime.consume(telegram_message(2, "/stop", user: 2, chat: -10, topic: 4, reply_to: message_id))
    assert_equal [["original-loop", "run", "workspace-home"]], @bridge.stop_calls
  end

  private

    def mention(id)
      telegram_message(id, "@rho_bot request #{id}", user: 2, chat: -10, topic: 4,
        entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    end

    def tracker
      @state.read.fetch("routes").fetch("-10:4:2").fetch("conversations").fetch("conversation-1")
    end

    def advance
      @now += 5
      @runtime.tick
    end

    def sent_answer(text)
      @client.calls.find { |method, params| method == "sendMessage" && params[:text] == text }&.last ||
        flunk("No formal reply sent for #{text.inspect}")
    end

    def prepare_backlog
      @bridge.defer_inputs = true
      @runtime.consume(mention(1))
      @runtime.consume(mention(2))
      @bridge.turn_rows["conversation-1"] = [turn(0, "First answer")]
      @bridge.event_rows["conversation-1"] = unrelated_events(1..100) +
        materialized(101, input: "input-1", position: 0, run_public_id: "first-loop")
      @bridge.define_singleton_method(:events) do |id, after: nil, workspace_public_id: nil|
        all = @event_rows.fetch(id)
        rows = all.select { |row| !after || row.fetch("sequence") > after.to_i }.first(100)
        { "events" => rows, "pagination" => { "watermark" => all.last.fetch("sequence"),
          "next_after" => rows.last&.fetch("cursor") } }
      end
    end

    def expose_later_completion
      @bridge.turn_rows["conversation-1"] = [turn(0, "First answer"), turn(1, "Second answer")]
      @bridge.event_rows["conversation-1"] += unrelated_events(103..200) +
        materialized(201, input: "input-2", position: 1, run_public_id: "second-loop")
    end

    def unrelated_events(sequences)
      sequences.map do |sequence|
        event(sequence, "input_accepted", "input_public_id" => "earlier-#{sequence}", "origin" => "person")
      end
    end

    def materialized(sequence, input:, position:, run_public_id:)
      [event(sequence, "input_materialized", "input_public_id" => input, "turn_public_id" => "turn-#{position}"),
        event(sequence + 1, "turn_status", "turn_public_id" => "turn-#{position}", "run_public_id" => run_public_id)]
    end

    def event(sequence, type, payload)
      { "sequence" => sequence, "cursor" => sequence.to_s, "type" => type, "payload" => payload }
    end
end
