require "json"
require "test_helper"

# The declared-vocabulary + extra_body contract for the OpenAI audio one-shots:
# - request methods accept ONLY their declared symbol options,
# - provider-specific wire fields ride the extra_body escape hatch
#   (string-keyed, merged verbatim, collisions rejected),
# - speech exits through a string-keyed JSON body; transcriptions exits
#   through a multipart PARTS ARRAY where each extra_body pair becomes one
#   more form-field part.
class TestOpenAIAudioSpeechProtocol < Minitest::Test
  class CapturingAdapter < SimpleInference::HTTPAdapter
    attr_reader :last_request

    def call(request)
      @last_request = request
      { status: 200, headers: { "content-type" => "audio/mpeg" }, body: "ID3AUDIOBYTES" }
    end
  end

  # The input caps are construction facts fed from the registry row's
  # local_safety_limits (ApiFormat.protocol_for); these tests feed the
  # same declared values the shipped row carries.
  def build_protocol(adapter: CapturingAdapter.new)
    SimpleInference::Protocols::OpenAIAudioSpeech.new(
      base_url: "http://example.com", api_key: "k", adapter: adapter,
      input_character_cap: 4_096, input_byte_cap: 2_000
    )
  end

  def test_declared_options_reach_the_wire_as_string_keys
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    result = protocol.create(
      model: "gpt-4o-mini-tts",
      input: "Hello",
      voice: "coral",
      response_format: "mp3",
      speed: 1.25,
      instructions: "Speak cheerfully.",
    )

    assert_instance_of SimpleInference::Audio::SpeechResult, result
    assert_equal "ID3AUDIOBYTES", result.audio
    assert_equal "audio/mpeg", result.mime_type

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "gpt-4o-mini-tts", body.fetch("model")
    assert_equal "Hello", body.fetch("input")
    assert_equal "coral", body.fetch("voice")
    assert_equal "mp3", body.fetch("response_format")
    assert_equal 1.25, body.fetch("speed")
    assert_equal "Speak cheerfully.", body.fetch("instructions")
  end

  def test_unknown_symbol_options_raise_and_point_at_extra_body
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.create(model: "m", input: "x", voice: "v", voice_speed: 2)
      end

    assert_includes error.message, "voice_speed"
    assert_includes error.message, "extra_body"
  end

  def test_extra_body_merges_string_keyed_fields_verbatim
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: "m", input: "x", voice: "v", extra_body: { "sample_rate" => 24_000 })

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal 24_000, body.fetch("sample_rate")
  end

  def test_extra_body_collisions_with_built_wire_fields_raise
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.create(model: "m", input: "x", voice: "v", extra_body: { "voice" => "alloy" })
      end

    assert_includes error.message, "voice"
  end

  def test_request_option_keys_are_introspectable
    keys = SimpleInference::Protocols::OpenAIAudioSpeech.request_option_keys

    assert_includes keys, :speed
    assert keys.frozen?
  end

  # --- the dual pre-IO input bound (C2-1 non-text matrix): 4,096 Unicode
  # scalars (Create Speech character bound) AND 2,000 UTF-8 bytes (conservative
  # proxy for the 2,000-token model bound: byte-level BPE consumes >= 1 byte
  # per token, so bytes bound tokens from above — scalar counts do NOT). All
  # cap/cap+1 inputs are deterministic constructions. ---

  class ExplodingAdapter < SimpleInference::HTTPAdapter
    def call(_request)
      raise "no request may be emitted on a pre-IO rejection"
    end
  end

  def test_input_at_the_byte_cap_passes
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: "m", input: "a" * 2_000, voice: "v")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal 2_000, body.fetch("input").bytesize
  end

  def test_input_one_byte_over_the_byte_cap_is_rejected_pre_io
    error =
      assert_raises(SimpleInference::BoundExceededError) do
        build_protocol(adapter: ExplodingAdapter.new).create(model: "m", input: "a" * 2_001, voice: "v")
      end

    assert_includes error.message, "speech_input_bytes_token_proxy"
    assert_includes error.message, "2001"
  end

  def test_multibyte_input_is_bounded_by_bytes_not_scalars
    # 700 scalars but 2,100 UTF-8 bytes: the token-conservative byte proxy
    # must trip even though the scalar count is far under 4,096.
    error =
      assert_raises(SimpleInference::BoundExceededError) do
        build_protocol(adapter: ExplodingAdapter.new).create(model: "m", input: "世" * 700, voice: "v")
      end

    assert_includes error.message, "speech_input_bytes_token_proxy"
  end

  def test_input_over_the_character_cap_is_rejected_with_the_character_bound
    # The scalar bound is checked first, so 4,097 scalars names the character
    # bound even though the byte proxy would also trip.
    error =
      assert_raises(SimpleInference::BoundExceededError) do
        build_protocol(adapter: ExplodingAdapter.new).create(model: "m", input: "a" * 4_097, voice: "v")
      end

    assert_includes error.message, "speech_input_characters"
    assert_includes error.message, "4097"
  end

  def test_input_at_the_character_cap_passes_the_character_bound
    # Deterministic construction: 4,096 one-byte scalars satisfy the character
    # cap exactly, so the rejection that follows MUST name the byte proxy —
    # proving the character check passed at its cap. (An input at 4,096 scalars
    # under 2,000 bytes cannot exist: every scalar is at least one byte.)
    error =
      assert_raises(SimpleInference::BoundExceededError) do
        build_protocol(adapter: ExplodingAdapter.new).create(model: "m", input: "a" * 4_096, voice: "v")
      end

    assert_includes error.message, "speech_input_bytes_token_proxy"
    refute_includes error.message, "speech_input_characters"
  end

  def test_speech_result_keeps_provider_audio_without_proof_facts
    result = build_protocol.create(model: "m", input: "x", voice: "v")

    assert_equal "ID3AUDIOBYTES", result.audio
    assert_equal "audio/mpeg", result.mime_type
    refute_respond_to result, :byte_size
    refute_respond_to result, :sha256_digest
    refute_respond_to result, :detected_media_type
    assert_predicate result, :frozen?
  end

  def test_language_option_is_locally_rejected_naming_the_route_gap
    # M2's speech language is locally rejected: the Create Speech route
    # exposes no such request field (register speech bullet).
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: ExplodingAdapter.new).create(model: "m", input: "x", voice: "v", language: "en")
      end

    assert_includes error.message, "language"
    refute_includes error.message, "extra_body", "language is a route gap, not an escape-hatch candidate"
  end
end

class TestOpenAIAudioTranscriptionsProtocol < Minitest::Test
  class CapturingAdapter < SimpleInference::HTTPAdapter
    attr_reader :last_request

    def call(request)
      @last_request = request
      body = JSON.generate({ "text" => "hello", "usage" => { "total_tokens" => 3 } })
      { status: 200, headers: { "content-type" => "application/json" }, body: body }
    end
  end

  AUDIO_FILE = { filename: "sample.wav", content_type: "audio/wav", body: "RIFF....WAVE" }.freeze

  def build_protocol(adapter: CapturingAdapter.new)
    SimpleInference::Protocols::OpenAIAudioTranscriptions.new(base_url: "http://example.com", api_key: "k", adapter: adapter)
  end

  def test_declared_options_become_multipart_form_fields
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    result = protocol.create(model: "gpt-4o-transcribe", file: AUDIO_FILE, language: "en", temperature: 0.2)

    assert_instance_of SimpleInference::Audio::TranscriptionResult, result
    assert_equal "hello", result.text

    # The multipart body is ITERATED, never assembled — `to_s` is how a
    # reader materializes it, and the one full copy it costs is exactly what
    # the send no longer pays.
    body = adapter.last_request.fetch(:body).to_s
    assert_includes body, %(name="model")
    assert_includes body, "gpt-4o-transcribe"
    assert_includes body, %(filename="sample.wav")
    assert_includes body, %(name="language")
    assert_includes body, "en"
    assert_includes body, %(name="temperature")
    assert_includes body, "0.2"
  end

  def test_unknown_symbol_options_raise_and_point_at_extra_body
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.create(model: "m", file: AUDIO_FILE, languge: "en")
      end

    assert_includes error.message, "languge"
    assert_includes error.message, "extra_body"
  end

  def test_extra_body_pairs_become_multipart_form_fields_verbatim
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: "m", file: AUDIO_FILE, extra_body: { "diarize" => "true" })

    # The multipart body is ITERATED, never assembled — `to_s` is how a
    # reader materializes it, and the one full copy it costs is exactly what
    # the send no longer pays.
    body = adapter.last_request.fetch(:body).to_s
    assert_includes body, %(name="diarize")
    assert_includes body, "true"
  end

  def test_extra_body_collisions_with_declared_form_fields_raise
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.create(model: "m", file: AUDIO_FILE, language: "en", extra_body: { "language" => "fr" })
      end

    assert_includes error.message, "language"
  end

  def test_extra_body_collisions_with_protocol_built_parts_raise
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.create(model: "m", file: AUDIO_FILE, extra_body: { "model" => "other" })
      end

    assert_includes error.message, "model"
  end

  def test_extra_body_rejects_symbol_keys
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.create(model: "m", file: AUDIO_FILE, extra_body: { diarize: "true" })
      end

    assert_includes error.message, "string keys"
  end

  def test_request_option_keys_are_introspectable
    keys = SimpleInference::Protocols::OpenAIAudioTranscriptions.request_option_keys

    assert_includes keys, :language
    assert keys.frozen?
  end

  # --- media ingress via MediaInput (byte-truth sniffing; the profile
  # allowlist stays validator-side). All rejected bodies are deterministic
  # constructions, not wire captures. ---

  class ExplodingAdapter < SimpleInference::HTTPAdapter
    def call(_request)
      raise "no request may be emitted on a pre-IO rejection"
    end
  end

  def test_detected_mime_is_sent_as_the_file_part_content_type
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    # No caller-asserted content type at all: byte truth alone names the part.
    protocol.create(model: "m", file: { filename: "sample.flac", body: "fLaC0000STREAMBYTES" })

    # The multipart body is ITERATED, never assembled — `to_s` is how a
    # reader materializes it, and the one full copy it costs is exactly what
    # the send no longer pays.
    body = adapter.last_request.fetch(:body).to_s
    assert_includes body, "Content-Type: audio/flac\r\n\r\n"
  end

  def test_declared_content_type_mismatching_the_bytes_is_rejected_pre_io
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: ExplodingAdapter.new).create(
          model: "m",
          file: { filename: "sample.mp3", content_type: "audio/mpeg", body: "RIFF....WAVE" },
        )
      end

    assert_includes error.message, "audio/wav"
    assert_includes error.message, "audio/mpeg"
  end

  def test_unknown_bytes_are_rejected_pre_io
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: ExplodingAdapter.new).create(model: "m", file: { body: "zzzz-not-audio" })
      end

    assert_includes error.message, "no supported media type"
  end

  def test_non_audio_bytes_are_rejected_pre_io
    png = "\x89PNG\r\n\x1a\n0000".b

    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: ExplodingAdapter.new).create(model: "m", file: { body: png })
      end

    assert_includes error.message, "image/png"
  end

  def test_file_without_body_bytes_is_rejected_pre_io
    assert_raises(SimpleInference::ValidationError) do
      build_protocol(adapter: ExplodingAdapter.new).create(model: "m", file: "sample.wav")
    end
    assert_raises(SimpleInference::ValidationError) do
      build_protocol(adapter: ExplodingAdapter.new).create(model: "m", file: { "body" => "RIFF....WAVE" })
    end
  end

  def test_public_transcription_accepts_only_body_bytes
    source = ->(&chunk) { chunk.call("not-the-sniffed-bytes") }

    error = assert_raises(SimpleInference::ValidationError) do
      build_protocol(adapter: ExplodingAdapter.new).create(
        model: "m",
        file: {
          source: source,
          byte_size: 21,
          header: "RIFF....WAVE",
        },
      )
    end

    assert_includes error.message, ":body"
  end

  def test_internal_compile_accepts_a_trusted_streaming_media_input
    chunks = ["RIFF", "....", "WAVE"]
    media = SimpleInference::MediaInput.new(
      source: ->(&chunk) { chunks.each(&chunk) },
      byte_size: chunks.sum(&:bytesize),
      media_type: "audio/wav",
    )

    request = build_protocol.compile_from_media(model: "m", media: media, filename: "sample.wav")

    assert_includes request.payload.to_s, "RIFF....WAVE"
  end

  def test_filesystem_path_file_parts_stay_rejected
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: ExplodingAdapter.new).create(model: "m", file: { path: "/tmp/sample.wav" })
      end

    assert_includes error.message, "paths are not accepted"
  end

  # --- response_format dispositions: json only for v1 ---

  def test_response_format_json_passes
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: "m", file: AUDIO_FILE, response_format: "json")

    # The multipart body is ITERATED, never assembled — `to_s` is how a
    # reader materializes it, and the one full copy it costs is exactly what
    # the send no longer pays.
    body = adapter.last_request.fetch(:body).to_s
    assert_includes body, %(name="response_format")
    assert_includes body, "json"
  end

  def test_non_json_response_formats_are_loud_local_rejections
    %w[text srt vtt verbose_json].each do |format|
      error =
        assert_raises(SimpleInference::ValidationError, "#{format} must be rejected") do
          build_protocol(adapter: ExplodingAdapter.new).create(model: "m", file: AUDIO_FILE, response_format: format)
        end

      assert_includes error.message, "json"
    end
  end

  def test_valid_empty_string_transcript_is_preserved
    # Wire-confirmed contract (2026-08-09 probe, tone-only file): "text": ""
    # is a valid transcript, not a missing one.
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_request)
        body = JSON.generate({ "text" => "", "usage" => { "type" => "tokens", "total_tokens" => 3 } })
        { status: 200, headers: { "content-type" => "application/json" }, body: body }
      end
    end.new

    result = build_protocol(adapter: adapter).create(model: "m", file: AUDIO_FILE)

    assert_equal "", result.text
    assert_equal 3, result.usage.fetch("total_tokens")
  end

  def test_wire_omitted_transcript_text_stays_nil
    # The omitted-vs-valid-empty distinction (C2-1): a 2xx body WITHOUT a
    # "text" member is a missing transcript, not an empty one. Deterministic
    # construction — never coerced into "".
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_request)
        body = JSON.generate({ "usage" => { "type" => "tokens", "total_tokens" => 3 } })
        { status: 200, headers: { "content-type" => "application/json" }, body: body }
      end
    end.new

    result = build_protocol(adapter: adapter).create(model: "m", file: AUDIO_FILE)

    assert_nil result.text, "wire-omitted text stays nil; only a wire \"\" is a valid empty transcript"
  end
end
