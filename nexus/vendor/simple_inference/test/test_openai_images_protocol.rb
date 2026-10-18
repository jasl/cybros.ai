require "json"
require "test_helper"

class TestOpenAIImagesProtocol < Minitest::Test
  class CapturingAdapter < SimpleInference::HTTPAdapter
    attr_reader :last_request

    def initialize(data = [{ "b64_json" => "aGVsbG8=" }])
      @data = data
    end

    def call(request)
      @last_request = request
      body = JSON.generate({ "data" => @data })
      { status: 200, headers: { "content-type" => "application/json" }, body: body }
    end
  end

  def build_protocol(adapter: CapturingAdapter.new)
    SimpleInference::Protocols::OpenAIImages.new(base_url: "http://example.com", api_key: "k", adapter: adapter)
  end

  def test_generate_normalizes_openai_image_payload
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              data: [
                {
                  b64_json: "aGVsbG8=",
                  revised_prompt: "hello image",
                },
              ],
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::OpenAIImages.new(base_url: "http://example.com", api_key: "secret", adapter: adapter)
    result = protocol.generate(model: "gpt-image-1", prompt: "hello")

    assert_instance_of SimpleInference::Images::Result, result
    assert_equal(
      {
        "b64_json" => "aGVsbG8=", "mime_type" => "image/png",
        "revised_prompt" => "hello image",
      },
      result.images.fetch(0)
    )
    assert_equal "http://example.com/v1/images/generations", adapter.last_request.fetch(:url)
  end

  def test_generate_preserves_v1_prefix_when_base_url_already_includes_it
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate({ data: [] }),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::OpenAIImages.new(
      base_url: "http://example.com/v1",
      api_key: "secret",
      adapter: adapter,
      images_path: "/images/generations",
    )
    protocol.generate(model: "gpt-image-2", prompt: "hello")

    assert_equal "http://example.com/v1/images/generations", adapter.last_request.fetch(:url)
  end

  def test_generate_preserves_a_real_url_output_without_duplicate_views
    adapter = CapturingAdapter.new([{ "url" => "https://cdn.example/image.png" }])
    result = build_protocol(adapter: adapter).generate(model: "m", prompt: "x")

    assert_equal(
      { "url" => "https://cdn.example/image.png", "mime_type" => "image/png" },
      result.images.fetch(0)
    )
  end

  # --- declared-vocabulary + extra_body contract ---

  def test_declared_options_reach_the_wire_as_string_keys
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.generate(
      model: "dall-e-3",
      prompt: "hello",
      n: 2,
      size: "1024x1024",
      quality: "hd",
      style: "vivid",
      response_format: "b64_json",
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "dall-e-3", body.fetch("model")
    assert_equal "hello", body.fetch("prompt")
    assert_equal 2, body.fetch("n")
    assert_equal "1024x1024", body.fetch("size")
    assert_equal "hd", body.fetch("quality")
    assert_equal "vivid", body.fetch("style")
    assert_equal "b64_json", body.fetch("response_format")
  end

  def test_unknown_symbol_options_raise_and_point_at_extra_body
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.generate(model: "m", prompt: "x", sizee: "1024x1024")
      end

    assert_includes error.message, "sizee"
    assert_includes error.message, "extra_body"
  end

  def test_extra_body_merges_string_keyed_fields_verbatim
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.generate(model: "m", prompt: "x", extra_body: { "watermark" => false, "image_size" => "1K" })

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal false, body.fetch("watermark")
    assert_equal "1K", body.fetch("image_size")
  end

  def test_extra_body_collisions_with_declared_wire_fields_raise
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.generate(model: "m", prompt: "x", size: "512x512", extra_body: { "size" => "1024x1024" })
      end

    assert_includes error.message, "size"
  end

  def test_extra_body_collisions_with_kwarg_built_wire_fields_raise
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.generate(model: "m", prompt: "x", extra_body: { "prompt" => "other" })
      end

    assert_includes error.message, "prompt"
  end

  # Pins the prompt/input quirk: a String input doubles as the prompt when no
  # prompt was given, so prompt-only providers read it either way.
  def test_string_input_doubles_as_prompt
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.generate(model: "m", input: "draw a cat")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "draw a cat", body.fetch("input")
    assert_equal "draw a cat", body.fetch("prompt")
  end

  def test_request_option_keys_are_introspectable
    keys = SimpleInference::Protocols::OpenAIImages.request_option_keys

    assert_includes keys, :size
    assert_includes keys, :quality
    assert_includes keys, :style
    assert_includes keys, :n
    assert_includes keys, :response_format
    assert keys.frozen?
  end

  # --- pinned option surface (C2-1 non-text matrix): bounded n, frozen
  # quality/size vocabulary, b64_json-only delivery. All rejections below are
  # deterministic pre-IO constructions — no request may be emitted. ---

  class ExplodingAdapter < SimpleInference::HTTPAdapter
    def call(_request)
      raise "no request may be emitted on a pre-IO rejection"
    end
  end

  def test_n_is_the_locally_frozen_bounded_requested_count
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.generate(model: "m", prompt: "x", n: 1)
    assert_equal 1, JSON.parse(adapter.last_request.fetch(:body)).fetch("n")

    protocol.generate(model: "m", prompt: "x", n: 10)
    assert_equal 10, JSON.parse(adapter.last_request.fetch(:body)).fetch("n")
  end

  def test_non_positive_absurd_or_non_integer_n_is_rejected_pre_io
    protocol = build_protocol(adapter: ExplodingAdapter.new)

    [0, -1, 11, 1.5, "2"].each do |n|
      error =
        assert_raises(SimpleInference::ValidationError, "n=#{n.inspect} must be rejected") do
          protocol.generate(model: "m", prompt: "x", n: n)
        end

      assert_includes error.message, "n"
    end
  end

  def test_quality_outside_the_candidate_vocabulary_is_rejected_pre_io
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: ExplodingAdapter.new).generate(model: "m", prompt: "x", quality: "ultra")
      end

    assert_includes error.message, "quality"
  end

  # --- F22: the vendor's quality/size vocabularies (images/create reference
  # + the gpt-image-2.5 pages, read 2026-09-16). Quality gains xhigh/max;
  # size accepts the enum OR an arbitrary WIDTHxHEIGHT under the 2.5
  # rule (multiples of 16, edge <= 3840, aspect 1:3..3:1, 655,360..8,294,400
  # pixels). A vendor-page widening, not a reference agreement: codex's own
  # enum stops at high and always sends auto. ---

  def test_xhigh_and_max_quality_reach_the_body_verbatim
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    %w[xhigh max].each do |quality|
      protocol.generate(model: "gpt-image-2.5-sunburst", prompt: "hello", quality: quality)

      assert_equal quality, JSON.parse(adapter.last_request.fetch(:body)).fetch("quality")
    end
  end

  def test_an_arbitrary_size_within_the_vendor_rule_reaches_the_body
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.generate(model: "gpt-image-2.5-flare", prompt: "hello", size: "2048x1152")

    assert_equal "2048x1152", JSON.parse(adapter.last_request.fetch(:body)).fetch("size")
  end

  def test_a_size_outside_the_vendor_rule_is_rejected_pre_io
    protocol = build_protocol(adapter: ExplodingAdapter.new)

    {
      "641x480" => "multiple of 16",
      "3856x1024" => "3840",
      "3120x1024" => "aspect",
      "640x480" => "pixels",
      "portrait" => "size",
    }.each do |size, clause|
      error =
        assert_raises(SimpleInference::ValidationError, "size=#{size} must be rejected") do
          protocol.generate(model: "m", prompt: "x", size: size)
        end

      assert_includes error.message, "size"
      assert_includes error.message, clause, "size=#{size} names the rule it breaks"
    end
  end

  def test_response_format_url_delivery_is_locally_rejected
    # Byte-inline transport policy: only b64_json delivery is accepted; a URL
    # response is a remote-fetch mechanism and stays rejected.
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: ExplodingAdapter.new).generate(model: "m", prompt: "x", response_format: "url")
      end

    assert_includes error.message, "b64_json"
  end

  def test_response_format_b64_json_passes
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.generate(model: "m", prompt: "x", response_format: "b64_json")

    assert_equal "b64_json", JSON.parse(adapter.last_request.fetch(:body)).fetch("response_format")
  end

  def test_response_format_is_not_invented_without_a_provider_wire_option
    adapter = CapturingAdapter.new

    build_protocol(adapter: adapter).generate(model: "m", prompt: "x")

    refute JSON.parse(adapter.last_request.fetch(:body)).key?("response_format")
  end

  def test_provider_wire_option_defaults_response_format_to_inline_bytes
    adapter = CapturingAdapter.new
    protocol = SimpleInference::Protocols::OpenAIImages.new(
      base_url: "http://example.com", api_key: "k", adapter: adapter,
      image_response_format: "b64_json"
    )

    protocol.generate(model: "m", prompt: "x")

    assert_equal "b64_json", JSON.parse(adapter.last_request.fetch(:body)).fetch("response_format")
  end

  # --- F18: `originator:` — the codex image lane generates on the
  # provider it chats on (codex-rs ext/image-generation/src/backend.rs
  # image_request_headers). A construction fact; plain openai_api/xai rows
  # never carry the header. ---

  def test_originator_is_a_construction_fact_emitted_only_when_set
    adapter = CapturingAdapter.new
    protocol = SimpleInference::Protocols::OpenAIImages.new(
      base_url: "https://chatgpt.com/backend-api/codex", api_key: "k", adapter: adapter,
      images_path: "/images/generations", originator: "codex_cli_rs"
    )

    protocol.generate(model: "gpt-image-2", prompt: "hello")

    headers = adapter.last_request.fetch(:headers)
    assert_equal "codex_cli_rs", headers.fetch("originator")
    assert_equal "https://chatgpt.com/backend-api/codex/images/generations", adapter.last_request.fetch(:url)

    build_protocol(adapter: adapter).generate(model: "m", prompt: "x")
    refute_includes adapter.last_request.fetch(:headers), "originator"
  end

  def test_a_blank_originator_is_a_loud_construction_error
    assert_raises(SimpleInference::ConfigurationError) do
      SimpleInference::Protocols::OpenAIImages.new(base_url: "http://example.com", originator: " ")
    end
  end

  def test_protocol_option_keys_declare_the_image_construction_facts
    assert_equal %i[images_path image_response_format images_edits_path images_edits_encoding originator],
                 SimpleInference::Protocols::OpenAIImages.protocol_option_keys
  end

  # --- F23: images/edits. An `images:` option of bytes-only MediaInputs
  # (cap 16 — the vendor's `image[]` bound for gpt-image) and an optional
  # `mask:` retarget the compile to the edits path. The ENCODING is a
  # per-lane wire_options fact: the public v1 route takes multipart
  # (`image[]` + `mask`), the codex backend the JSON shape codex-rs sends
  # (`{images: [{image_url: <data URL>}], prompt, ...}`,
  # codex-api/src/images.rs ImageEditRequest). ---

  PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + "deterministic-test-pixels".b).freeze
  JPEG_BYTES = ("\xFF\xD8\xFF".b + "deterministic-jpeg-pixels".b).freeze

  def png_media = SimpleInference::MediaInput.from_bytes(PNG_BYTES)

  def jpeg_media = SimpleInference::MediaInput.from_bytes(JPEG_BYTES)

  def multipart_text(request)
    body = request.fetch(:body)
    body.respond_to?(:to_s) ? body.to_s : body
  end

  def test_images_route_to_the_edits_path_as_multipart_on_the_public_wire
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    result = protocol.generate(
      model: "gpt-image-2", prompt: "make it night", images: [png_media, jpeg_media],
      mask: png_media, size: "1024x1024", n: 1
    )

    request = adapter.last_request
    assert_equal "http://example.com/v1/images/edits", request.fetch(:url)
    assert_match %r{\Amultipart/form-data; boundary=}, request.fetch(:headers).fetch("Content-Type")
    text = multipart_text(request)
    assert_equal 2, text.scan(%(name="image[]")).length
    assert_includes text, %(name="image[]"; filename="image-1.png")
    assert_includes text, %(name="image[]"; filename="image-2.jpg")
    assert_includes text, "Content-Type: image/png\r\n\r\n#{PNG_BYTES}"
    assert_includes text, "Content-Type: image/jpeg\r\n\r\n#{JPEG_BYTES}"
    assert_equal 1, text.scan(%(name="mask")).length
    assert_includes text, %(name="model"\r\n\r\ngpt-image-2)
    assert_includes text, %(name="prompt"\r\n\r\nmake it night)
    assert_includes text, %(name="size"\r\n\r\n1024x1024)
    assert_includes text, %(name="n"\r\n\r\n1)
    refute_includes text, "images"
    assert_instance_of SimpleInference::Images::Result, result
    assert_equal "images.edit", result.provider_format
  end

  def test_images_route_to_the_edits_path_as_json_on_the_codex_encoding
    adapter = CapturingAdapter.new
    protocol = SimpleInference::Protocols::OpenAIImages.new(
      base_url: "https://chatgpt.com/backend-api/codex", api_key: "k", adapter: adapter,
      images_path: "/images/generations", images_edits_path: "/images/edits",
      images_edits_encoding: "json", originator: "codex_cli_rs"
    )

    protocol.generate(model: "gpt-image-2", prompt: "make it night", images: [png_media], quality: "high")

    request = adapter.last_request
    assert_equal "https://chatgpt.com/backend-api/codex/images/edits", request.fetch(:url)
    assert_equal "application/json", request.fetch(:headers).fetch("Content-Type")
    assert_equal "codex_cli_rs", request.fetch(:headers).fetch("originator")
    body = JSON.parse(request.fetch(:body))
    assert_equal "gpt-image-2", body.fetch("model")
    assert_equal "make it night", body.fetch("prompt")
    assert_equal "high", body.fetch("quality")
    assert_equal(
      [{ "image_url" => "data:image/png;base64,#{[PNG_BYTES].pack("m0")}" }],
      body.fetch("images")
    )
  end

  def test_a_mask_has_no_slot_on_the_codex_json_shape
    protocol = SimpleInference::Protocols::OpenAIImages.new(
      base_url: "http://example.com", adapter: ExplodingAdapter.new, images_edits_encoding: "json"
    )

    error = assert_raises(SimpleInference::ValidationError) do
      protocol.generate(model: "m", prompt: "x", images: [png_media], mask: png_media)
    end

    assert_includes error.message, "mask"
  end

  def test_the_edits_path_is_a_construction_fact_under_the_api_prefix
    adapter = CapturingAdapter.new
    protocol = SimpleInference::Protocols::OpenAIImages.new(
      base_url: "http://example.com/v1", api_key: "k", adapter: adapter, images_edits_path: "/images/edits"
    )

    protocol.generate(model: "m", prompt: "x", images: [png_media])

    assert_equal "http://example.com/v1/images/edits", adapter.last_request.fetch(:url)
  end

  def test_without_images_the_compile_stays_on_the_generations_path
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.generate(model: "m", prompt: "x")

    assert_equal "http://example.com/v1/images/generations", adapter.last_request.fetch(:url)
    assert_equal "application/json", adapter.last_request.fetch(:headers).fetch("Content-Type")
  end

  def test_images_must_be_a_non_empty_list_of_image_media_inputs_within_the_cap
    protocol = build_protocol(adapter: ExplodingAdapter.new)
    wav = SimpleInference::MediaInput.from_bytes("RIFF....WAVEfmt ".b)

    [
      [], "data:image/png;base64,AAAA", [PNG_BYTES], [wav], Array.new(17) { png_media },
    ].each do |images|
      error =
        assert_raises(SimpleInference::ValidationError, "images=#{images.inspect[0, 40]} must be rejected") do
          protocol.generate(model: "m", prompt: "x", images: images)
        end

      assert_includes error.message, "images"
    end
  end

  def test_a_mask_without_images_and_a_non_image_mask_are_rejected_pre_io
    protocol = build_protocol(adapter: ExplodingAdapter.new)

    error = assert_raises(SimpleInference::ValidationError) { protocol.generate(model: "m", prompt: "x", mask: png_media) }
    assert_includes error.message, "mask"

    error = assert_raises(SimpleInference::ValidationError) do
      protocol.generate(model: "m", prompt: "x", images: [png_media], mask: PNG_BYTES)
    end
    assert_includes error.message, "mask"
  end

  def test_an_unknown_edits_encoding_is_a_loud_construction_error
    assert_raises(SimpleInference::ConfigurationError) do
      SimpleInference::Protocols::OpenAIImages.new(base_url: "http://example.com", images_edits_encoding: "yaml")
    end
  end

  def test_extra_body_rides_the_multipart_edit_as_form_fields
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.generate(model: "m", prompt: "x", images: [png_media], extra_body: { "input_fidelity" => "high" })

    assert_includes multipart_text(adapter.last_request), %(name="input_fidelity"\r\n\r\nhigh)
  end

  # --- truthful usage parsing per the non-text matrix ---

  def test_usage_flattens_evidenced_token_subcounts_preserving_raw_fields
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        body = JSON.generate(
          {
            "data" => [{ "b64_json" => "aGVsbG8=" }],
            "usage" => {
              "input_tokens" => 10,
              "output_tokens" => 26,
              "cost_in_usd_ticks" => 600_000_000,
              "input_tokens_details" => { "image_tokens" => 6, "text_tokens" => 4 },
              "output_tokens_details" => { "image_tokens" => 26 },
            },
          }
        )
        { status: 200, headers: { "content-type" => "application/json" }, body: body }
      end
    end.new

    result = build_protocol(adapter: adapter).generate(model: "m", prompt: "x")

    assert_equal 10, result.usage.fetch("input_tokens")
    assert_equal 26, result.usage.fetch("output_tokens")
    assert_equal 600_000_000, result.usage.fetch("cost_in_usd_ticks")
    assert_instance_of Integer, result.usage.fetch("cost_in_usd_ticks")
    assert_equal 6, result.usage.fetch("image_input_tokens")
    assert_equal 4, result.usage.fetch("text_input_tokens")
    assert_equal 26, result.usage.fetch("image_output_tokens")
    refute result.usage.key?("text_output_tokens"),
           "a subcount absent on the wire stays absent — never fabricated as 0"
    assert_equal({ "image_tokens" => 6, "text_tokens" => 4 }, result.usage.fetch("input_tokens_details"),
                 "raw provider-shaped fields are preserved")
  end

  def test_absent_usage_stays_absent_declared_omission_branch
    # gpt-image-2 usage is typed optional (declared-omission review branch):
    # an omitted usage object surfaces as nil, never as fabricated zeros.
    result = build_protocol.generate(model: "m", prompt: "x")

    assert_nil result.usage
  end

  def test_result_keeps_the_provider_payload_encoded_for_the_storage_owner
    png_bytes = ("\x89PNG\r\n\x1a\n" + "deterministic-png-payload").b
    b64 = [png_bytes].pack("m0")
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call) do |_env|
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate({ "data" => [{ "b64_json" => b64 }] }),
        }
      end
    end.new

    result = build_protocol(adapter: adapter).generate(model: "m", prompt: "x")

    image = result.images.fetch(0)
    assert_equal b64, image.fetch("b64_json")
    assert_equal "image/png", image.fetch("mime_type")
    refute image.key?("data_url")
    refute image.key?("raw")
    refute image.key?("sha256_digest")
    assert_predicate result.images, :frozen?
  end
end
