require "test_helper"

class TestImagesResult < Minitest::Test
  def build_result(images:)
    SimpleInference::Images::Result.new(
      images: images,
      usage: nil,
      provider_response: nil,
      provider_format: "images.generate",
    )
  end

  def test_keeps_normalized_entries_encoded_without_copying_or_enriching_them
    image = { "b64_json" => "provider-encoded-payload", "mime_type" => "image/png" }
    images = [image]
    result = build_result(images: images)

    assert_same images, result.images
    assert_same image, result.images.fetch(0)
    assert_equal "provider-encoded-payload", image.fetch("b64_json")
    refute image.key?("byte_size")
    refute image.key?("sha256_digest")
    refute image.key?("detected_media_type")
    assert_predicate result, :frozen?
    assert_predicate result.images, :frozen?
  end
end

class TestSpeechResult < Minitest::Test
  def build_result(audio:, mime_type: "audio/flac")
    SimpleInference::Audio::SpeechResult.new(
      audio: audio,
      mime_type: mime_type,
      provider_response: nil,
      provider_format: "audio.speech",
    )
  end

  def test_keeps_received_audio_without_copying_or_fingerprinting_it
    audio = +"provider-audio"
    result = build_result(audio: audio, mime_type: "application/octet-stream")

    assert_same audio, result.audio
    assert_equal "application/octet-stream", result.mime_type
    refute_respond_to result, :byte_size
    refute_respond_to result, :sha256_digest
    refute_respond_to result, :detected_media_type
    assert_predicate result, :frozen?
  end
end

class TestTranscriptionResultNullableText < Minitest::Test
  def build_result(text:)
    SimpleInference::Audio::TranscriptionResult.new(
      text: text,
      usage: nil,
      provider_response: nil,
      provider_format: "audio.transcriptions",
    )
  end

  def test_wire_omitted_text_stays_nil
    assert_nil build_result(text: nil).text,
               "an omitted transcript is MISSING, not an empty transcript"
  end

  def test_wire_valid_empty_text_stays_empty
    # Probe-confirmed contract (2026-08-09, tone-only file): "text": "" is a
    # valid transcript distinct from an omitted one.
    assert_equal "", build_result(text: "").text
  end

  def test_present_text_is_preserved_and_frozen
    result = build_result(text: "hello")

    assert_equal "hello", result.text
    assert_predicate result, :frozen?
    assert_predicate result.text, :frozen?
  end
end

class TestEmbeddingsResultDimensions < Minitest::Test
  def build_result(embeddings:, requested_dimension: nil)
    SimpleInference::Embeddings::Result.new(
      embeddings: embeddings,
      usage: nil,
      provider_response: nil,
      provider_format: "embeddings.create",
      requested_dimension: requested_dimension,
    )
  end

  def test_vector_entries_are_retained_without_a_duplicate_dimension_fact
    result = build_result(
      embeddings: [
        { "index" => 0, "embedding" => [0.1, 0.2, 0.3] },
        { "index" => 1, "embedding" => [0.4, 0.5] },
      ]
    )

    assert_equal 3, result.embeddings.fetch(0).fetch("embedding").length
    assert_equal 2, result.embeddings.fetch(1).fetch("embedding").length
    refute result.embeddings.fetch(0).key?("dimension")
  end

  def test_requested_dimension_matching_every_effective_dimension_passes
    result = build_result(
      embeddings: [{ "index" => 0, "embedding" => [0.1, 0.2] }],
      requested_dimension: 2,
    )

    assert_equal 2, result.requested_dimension
    assert_equal 2, result.embeddings.fetch(0).fetch("embedding").length
  end

  def test_requested_vs_effective_dimension_mismatch_is_a_typed_error
    # Deterministic construction: a body whose vector length differs from the
    # requested dimension — a silent mismatch would corrupt every downstream
    # vector consumer.
    error =
      assert_raises(SimpleInference::DecodeError) do
        build_result(
          embeddings: [{ "index" => 0, "embedding" => [0.1, 0.2, 0.3] }],
          requested_dimension: 128,
        )
      end

    assert_includes error.message, "128"
    assert_includes error.message, "3"
    assert_includes error.message, "requested-vs-effective"
  end

  def test_non_vector_embeddings_gain_no_dimension_fact
    # encoding_format base64 delivers the vector as an opaque string: no
    # dimension fact is computable and none is fabricated.
    result = build_result(embeddings: [{ "index" => 0, "embedding" => "b64payload" }])

    refute result.embeddings.fetch(0).key?("dimension")
  end

  def test_empty_embeddings_with_requested_dimension_do_not_raise
    # A non-2xx lane constructs the result with no embeddings; there is no
    # effective dimension to verify.
    result = build_result(embeddings: [], requested_dimension: 128)

    assert_empty result.embeddings
  end

  def test_result_and_collection_are_frozen_without_copying_entries
    result = build_result(embeddings: [{ "index" => 0, "embedding" => [0.1] }])

    assert_predicate result, :frozen?
    assert_predicate result.embeddings, :frozen?
    refute_predicate result.embeddings.fetch(0), :frozen?
  end
end

class TestResponsesRefusal < Minitest::Test
  # The wire's words ride verbatim; an empty one is the absence the wire
  # meant, never a word — so a null category reads the same on every lane.
  def test_blank_words_are_absent_and_present_words_ride_verbatim
    assert_equal SimpleInference::Responses::Refusal.new(category: nil, explanation: nil),
      SimpleInference::Responses::Refusal.new(category: "", explanation: "")
    refusal = SimpleInference::Responses::Refusal.new(category: "cyber", explanation: "Not this.")

    assert_equal ["cyber", "Not this."], [refusal.category, refusal.explanation]
    assert_predicate refusal, :frozen?
  end

  # A reader is told what a word means where the word does not say it
  # plainly; the word itself rides verbatim, and a Gemini word glossed here
  # is one the lane's own table types as a decline.
  def test_meanings_gloss_opaque_words_and_only_words_the_wire_sends
    meanings = SimpleInference::Responses::Refusal::MEANINGS

    assert_equal "the request asks for the model's own reasoning", meanings.fetch("reasoning_extraction")
    assert_equal "an unsupported language", meanings.fetch("LANGUAGE")
    assert_nil meanings["cyber"], "a plain word needs no gloss"
    gemini = meanings.keys.grep(/\A[A-Z_]+\z/)
    assert_empty gemini - SimpleInference::FinishQuality::GEMINI.keys.map { |key| key.delete_prefix("PROMPT_") }
    assert gemini.all? { |word| SimpleInference::FinishQuality::DECLINED.include?(SimpleInference::FinishQuality::GEMINI[word]) }
    assert_predicate meanings, :frozen?
  end

  def test_a_result_built_without_one_has_no_refusal
    result = SimpleInference::Responses::Result.new(
      output_text: "hi", output_items: [], tool_calls: [], usage: nil, finish_reason: "stop",
      finish_detail: "stop", provider_response: nil, provider_format: "chat_completions"
    )

    assert_nil result.refusal
  end
end
