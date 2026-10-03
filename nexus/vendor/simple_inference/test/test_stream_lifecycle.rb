require "test_helper"

# Pins the lifecycle invariants of SimpleInference::Responses::Stream ahead of
# the rewrite. Streams are built directly with producer blocks (no HTTP),
# mirroring how the protocol classes construct them: emit events via the
# block argument, emit Events::Completed, then return the final result.
class TestStreamLifecycle < Minitest::Test
  EVENTS = SimpleInference::Responses::Events

  def build_result(output_text: "final text")
    SimpleInference::Responses::Result.new(
      output_text: output_text,
      output_items: [],
      tool_calls: [],
      usage: nil,
      finish_reason: "stop",
      finish_detail: nil,
      provider_response: nil,
      provider_format: "responses",
    )
  end

  def build_completed_stream(result)
    SimpleInference::Responses::Stream.new do |&emit|
      emit.call(EVENTS::TextDelta.new(delta: "Hel"))
      emit.call(EVENTS::TextDelta.new(delta: "lo"))
      emit.call(EVENTS::Completed.new(result: result))
      result
    end
  end

  def test_constructing_a_stream_does_not_invoke_the_producer
    producer_calls = []

    stream =
      SimpleInference::Responses::Stream.new do |&emit|
        producer_calls << :called
        emit.call(EVENTS::TextDelta.new(delta: "hi"))
        nil
      end

    assert_empty producer_calls

    stream.each { |_event| nil }

    assert_equal [:called], producer_calls
  end

  def test_second_each_raises_after_full_consumption
    stream = build_completed_stream(build_result)
    stream.each { |_event| nil }

    # error class may be revisited in rewrite
    error = assert_raises(SimpleInference::Error) { stream.each { |_event| nil } }
    assert error.is_a?(SimpleInference::Error)
    assert_equal "Responses::Stream can only be consumed once", error.message
  end

  def test_completed_event_carries_the_same_object_as_final_result
    result = build_result
    stream = build_completed_stream(result)

    completed_events = []
    stream.each do |event|
      completed_events << event if event.is_a?(EVENTS::Completed)
    end

    assert_equal 1, completed_events.length
    assert_same result, completed_events.first.result
    assert_same completed_events.first.result, stream.final_result
  end

  def test_final_result_on_a_never_consumed_stream_self_consumes
    result = build_result
    producer_calls = []

    stream =
      SimpleInference::Responses::Stream.new do |&emit|
        producer_calls << :called
        emit.call(EVENTS::Completed.new(result: result))
        result
      end

    assert_same result, stream.final_result
    assert_equal [:called], producer_calls
  end

  def test_output_text_accumulates_text_deltas_when_no_completed_event_arrives
    stream =
      SimpleInference::Responses::Stream.new do |&emit|
        emit.call(EVENTS::TextDelta.new(delta: "Hel"))
        emit.call(EVENTS::TextDelta.new(delta: "lo"))
        nil
      end

    assert_equal "Hello", stream.output_text
    assert_equal "Hello", stream.text
  end

  def test_output_text_prefers_the_final_result_output_text_after_completion
    result = build_result(output_text: "Hello, canonical")
    stream = build_completed_stream(result)

    assert_equal "Hello, canonical", stream.output_text
    assert_equal "Hello, canonical", stream.text
  end

  def test_each_without_block_returns_a_lazy_enumerator
    producer_calls = []

    stream =
      SimpleInference::Responses::Stream.new do |&emit|
        producer_calls << :called
        emit.call(EVENTS::TextDelta.new(delta: "first"))
        emit.call(EVENTS::TextDelta.new(delta: "second"))
        nil
      end

    enumerator = stream.each

    assert enumerator.is_a?(Enumerator)
    assert_empty producer_calls

    first_event = enumerator.next

    assert first_event.is_a?(EVENTS::TextDelta)
    assert_equal "first", first_event.delta
    assert_equal [:called], producer_calls
  end

  def test_producer_exceptions_propagate_out_of_each
    seen_events = []

    stream =
      SimpleInference::Responses::Stream.new do |&emit|
        emit.call(EVENTS::TextDelta.new(delta: "before failure"))
        raise "boom"
      end

    error =
      assert_raises(RuntimeError) do
        stream.each { |event| seen_events << event }
      end

    assert_equal "boom", error.message
    assert_equal 1, seen_events.length
    assert_equal "before failure", seen_events.first.delta
  end

  # An INTERRUPTED consumption (break mid-stream) must not read as "completed
  # with no result" — the kernel's abort paths would otherwise see a silent
  # nil where a loud error belongs.
  def test_final_result_raises_after_interrupted_consumption
    result = build_result
    stream = build_completed_stream(result)

    stream.each { |_event| break }

    error = assert_raises(SimpleInference::StreamError) { stream.final_result }
    assert_match(/interrupted/, error.message)
  end

  def test_final_result_still_returns_nil_when_the_producer_completes_without_a_result
    stream =
      SimpleInference::Responses::Stream.new do |&emit|
        emit.call(EVENTS::TextDelta.new(delta: "hi"))
        nil
      end

    stream.each { |_event| nil }

    assert_nil stream.final_result, "a COMPLETE producer run without a result is not an interruption"
  end

  def test_double_consumption_raises_stream_error
    stream = build_completed_stream(build_result)
    stream.each { |_event| nil }

    assert_raises(SimpleInference::StreamError) { stream.each { |_event| nil } }
  end

  def test_close_is_gone
    refute_respond_to build_completed_stream(build_result), :close,
                      "the no-op #close affordance was removed — nothing ever called it"
  end
end
