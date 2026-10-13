require "json"
require "test_helper"
require "gemini_protocol_helpers"

class TestGeminiRequests < Minitest::Test
  include GeminiProtocolHelpers

  PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + "deterministic-test-pixels".b).freeze

  # --- Media ingress: bytes only (MediaInput), carriers rejected ---
  # Transport policy (register Input-media profiles v1): provider requests
  # embed prepared bytes inline; caller data URIs, URLs, host paths, and
  # provider file handles are loud rejections at the lane's lowering.

  def test_media_input_bytes_lower_to_the_inline_data_wire_form
    media = SimpleInference::MediaInput.from_bytes(PNG_BYTES)
    adapter = capturing_gemini_adapter
    protocol = gemini_protocol(adapter: adapter)

    protocol.create(
      model: "gemini-3.7-flash",
      input: [
        {
          role: "user",
          content: [
            { "type" => "input_text", "text" => "look" },
            { "type" => "input_image", "image_url" => media },
          ],
        },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    inline = body.fetch("contents").fetch(0).fetch("parts").find { |part| part.key?("inline_data") }.fetch("inline_data")
    assert_equal "image/png", inline.fetch("mime_type")
    assert_equal [PNG_BYTES].pack("m0"), inline.fetch("data")
  end

  def test_caller_data_uri_image_is_a_loud_rejection
    protocol = gemini_protocol(adapter: exploding_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "gemini-3.7-flash",
          input: [{ role: "user", content: [{ "type" => "input_image", "image_url" => "data:image/png;base64,AAAA" }] }]
        )
      end

    assert_includes error.message, "MediaInput"
  end

  def test_caller_remote_url_image_is_a_loud_rejection
    protocol = gemini_protocol(adapter: exploding_adapter)

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(
        model: "gemini-3.7-flash",
        input: [{ role: "user", content: [{ "type" => "input_image", "image_url" => { "url" => "https://example.com/cat.png" } }] }]
      )
    end
  end

  # Frozen reasoning contract (register "Reasoning contracts v1"): the gemini
  # lane's wire vocabulary is thinkingConfig.thinkingLevel ∈ minimal|low|
  # medium|high. Every accepted effort maps 1:1 onto that closed set.
  def test_create_maps_each_accepted_reasoning_effort_to_thinking_level
    %w[minimal low medium high].each do |effort|
      adapter = capturing_gemini_adapter
      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
      )

      protocol.create(model: "gemini-3.7-flash", input: "Hello", reasoning_effort: effort)

      thinking_config = JSON.parse(adapter.last_request.fetch(:body)).dig("generationConfig", "thinkingConfig")
      assert_equal effort, thinking_config.fetch("thinkingLevel")
      assert_equal true, thinking_config.fetch("includeThoughts")
      refute thinking_config.key?("thinkingBudget"), "3.x reasoning must never emit the 2.5-era thinkingBudget"
    end
  end

  # Efforts outside the frozen 3.x thinkingLevel vocabulary (none, xhigh, max,
  # typos) are loud local rejections with zero outbound IO — there is no
  # thinkingBudget disable path and no silent nearest-level mapping.
  def test_create_rejects_reasoning_effort_outside_the_frozen_thinking_level_vocabulary
    %w[none xhigh max bogus].each do |effort|
      adapter = capturing_gemini_adapter
      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
      )

      error =
        assert_raises(SimpleInference::ValidationError) do
          protocol.create(model: "gemini-3.7-flash", input: "Hello", reasoning_effort: effort)
        end

      assert_includes error.message, effort
      assert_includes error.message, "thinkingLevel"
      assert_nil adapter.last_request, "a rejected reasoning_effort must produce zero outbound IO"
    end
  end

  def test_omitted_reasoning_effort_sends_no_thinking_config
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(model: "gemini-3.7-flash", input: "Hello")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_nil body.dig("generationConfig", "thinkingConfig"), "the server-side default (medium) applies when unset"
  end

  # Register "All-workload request-control" frozen disposition: this lane
  # locally rejects explicit temperature/top_p/top_k — Google marks them
  # deprecated/ignored on gemini-3.7-flash, so Nexus never forwards a control
  # whose effect it cannot observe. Deterministic pre-wire rejection, zero IO.
  def test_create_locally_rejects_temperature_top_p_and_top_k_pre_wire
    { temperature: 0.3, top_p: 0.9, top_k: 40 }.each do |key, value|
      adapter = capturing_gemini_adapter
      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
      )

      error =
        assert_raises(SimpleInference::ValidationError) do
          protocol.create(model: "gemini-3.7-flash", input: "Hello", key => value)
        end

      assert_includes error.message, key.to_s
      assert_includes error.message, "locally rejected"
      assert_nil adapter.last_request, "#{key} must be rejected before any outbound IO"
    end
  end

  # The frozen register removes the candidateCount surface for this lane: :n
  # is a loud local rejection and no code path writes candidateCount.
  def test_create_locally_rejects_n_and_never_builds_candidate_count
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gemini-3.7-flash", input: "Hello", n: 2)
      end

    assert_includes error.message, "n"
    assert_includes error.message, "locally rejected"
    assert_nil adapter.last_request
  end

  def test_stream_locally_rejects_sampling_controls_pre_wire
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.stream(model: "gemini-3.7-flash", input: "Hello", temperature: 0.5)
      end

    assert_includes error.message, "temperature"
    assert_nil adapter.last_request
  end

  # Register disposition: reject input whose last nonempty turn is assistant
  # (wire "model") instead of dropping/relabeling/padding it.
  def test_create_rejects_assistant_last_input_pre_wire
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "gemini-3.7-flash",
          input: [
            { role: "user", content: "Question" },
            { role: "assistant", content: "Half-finished answer" },
          ]
        )
      end

    assert_includes error.message, "assistant"
    assert_nil adapter.last_request, "assistant-last input must be rejected before any outbound IO"
  end

  def test_create_accepts_assistant_history_when_user_turn_is_last
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(
      model: "gemini-3.7-flash",
      input: [
        { role: "user", content: "Question" },
        { role: "assistant", content: "Prior answer" },
        { role: "user", content: "Follow-up" },
      ]
    )

    roles = JSON.parse(adapter.last_request.fetch(:body)).fetch("contents").map { |content| content.fetch("role") }
    assert_equal %w[user model user], roles
  end

  # The Responses family's `developer` role has no twin on this wire: it
  # lowers to `user` and stays WHERE THE CALLER PLACED IT in the list —
  # hoisting it into systemInstruction would move it ahead of everything
  # behind it (Nexus S-F r2 (5)). A role outside the vocabulary is still
  # the loud pre-wire error, never a quiet "user" turn.
  def test_create_lowers_developer_to_user_in_place
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(
      model: "gemini-3.7-flash",
      input: [
        { role: "user", content: "memory" }, { role: "developer", content: "env" },
        { role: "user", content: "Hi" },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    content = body.fetch("contents").fetch(0)
    assert_equal 1, body.fetch("contents").length, "adjacent user turns merge, as this wire always did"
    assert_equal "user", content.fetch("role")
    assert_equal ["memory", "env", "Hi"], content.fetch("parts").map { |part| part.fetch("text") },
      "the developer text stays between memory and the prompt — lowered in place"
    refute body.key?("systemInstruction"), "lowered in place, never hoisted"
    # The kernel's admission reads ACCEPTED_ROLES, so the constant must name
    # what normalize_role admits: its Anthropic twin was caught parking every
    # developer-led conversation at turn 1 (the paid live_cache_tier lane on
    # the direct Anthropic lane, 2026-09-18); this wire had the same gap.
    assert_includes SimpleInference::Protocols::GeminiGenerateContent::ACCEPTED_ROLES, "developer"
  end

  def test_create_rejects_unknown_roles_loudly
    %w[banana].each do |role|
      adapter = capturing_gemini_adapter
      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
      )

      error =
        assert_raises(SimpleInference::ValidationError) do
          protocol.create(
            model: "gemini-3.7-flash",
            input: [{ role: role, content: "Hello" }, { role: "user", content: "Hi" }]
          )
        end

      assert_includes error.message, role
      assert_nil adapter.last_request, "an unknown role (#{role}) must never silently reach the wire"
    end
  end

  def test_create_normalizes_gemini_tool_schema_and_tool_choice
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [
                {
                  content: {
                    parts: [
                      { text: "ok" },
                    ],
                  },
                  finishReason: "STOP",
                },
              ],
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      tool_choice: { type: "function", function: { name: "calculator" } },
      tools: [
        {
          type: "function",
          function: {
            name: "calculator",
            description: "Solve arithmetic",
            parameters: {
              type: "object",
              properties: {
                expression: {
                  anyOf: [
                    { type: "string" },
                    { type: "null" },
                  ],
                  description: "Math expression",
                },
              },
              required: [:expression],
            },
          },
        },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    declaration = request_body.fetch("tools").fetch(0).fetch("functionDeclarations").fetch(0)
    schema = declaration.fetch("parameters")
    property = schema.fetch("properties").fetch("expression")
    tool_config = request_body.fetch("toolConfig").fetch("functionCallingConfig")

    assert_equal "OBJECT", schema.fetch("type")
    assert_equal ["expression"], schema.fetch("required")
    assert_equal "STRING", property.fetch("type")
    assert_equal true, property.fetch("nullable")
    assert_equal "Math expression", property.fetch("description")
    assert_equal "any", tool_config.fetch("mode")
    assert_equal ["calculator"], tool_config.fetch("allowedFunctionNames")
  end

  def test_create_omits_function_response_id_when_history_lacks_call_id
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [
                {
                  content: {
                    parts: [
                      { text: "ok" },
                    ],
                  },
                  finishReason: "STOP",
                },
              ],
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    protocol.create(
      model: "gemini-3.5-flash",
      input: [
        { role: "user", content: "Add it up" },
        { type: "function_call", name: "calculator", arguments: "{\"expression\":\"2 + 2\"}" },
        { type: "function_call_output", name: "calculator", output: "{\"value\":4}" },
        { role: "tool", name: "calculator", content: "{\"value\":4}" },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    function_responses = request_body.fetch("contents").flat_map { |content| content.fetch("parts") }.filter_map { |part| part["functionResponse"] }

    assert_equal 2, function_responses.length
    function_responses.each do |function_response|
      assert_equal "calculator", function_response.fetch("name")
      # The reference client omits the id key entirely when there is no call
      # id; "id": null is not a valid substitute on the wire.
      refute function_response.key?("id")
    end
  end

  def test_create_preserves_multi_member_any_of_tool_parameter_unions
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [
                {
                  content: {
                    parts: [
                      { text: "ok" },
                    ],
                  },
                  finishReason: "STOP",
                },
              ],
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      tools: [
        {
          type: "function",
          function: {
            name: "lookup",
            description: "Look up a value",
            parameters: {
              type: "object",
              properties: {
                key: {
                  description: "Union-typed key",
                  anyOf: [
                    { type: "string" },
                    { type: "integer" },
                    { type: "null" },
                  ],
                },
              },
              required: ["key"],
            },
          },
        },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    property = request_body.fetch("tools").fetch(0).fetch("functionDeclarations").fetch(0).fetch("parameters").fetch("properties").fetch("key")

    # Multi-member unions survive: each member converted, the null member
    # only marks the parent nullable, and no single member wins the type.
    assert_equal %w[STRING INTEGER], property.fetch("anyOf").map { |member| member.fetch("type") }
    assert_equal true, property.fetch("nullable")
    assert_equal "Union-typed key", property.fetch("description")
    refute property.key?("type")
  end

  def test_create_does_not_treat_symbol_tool_enums_as_protocol_values
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [
                {
                  content: {
                    parts: [
                      { text: "ok" },
                    ],
                  },
                  finishReason: "STOP",
                },
              ],
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      tool_choice: { type: :function, function: { name: "calculator" } },
      tools: [
        {
          type: :function,
          function: {
            name: "calculator",
          },
        },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    refute request_body.key?("tools")
    refute request_body.key?("toolConfig")

    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      tool_choice: :auto,
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    refute request_body.key?("toolConfig")
  end

  def test_generate_content_maps_thought_input_parts_to_native_thought_parts
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(
      model: "gemini-3.5-flash",
      input: [
        { role: "user", content: "Question" },
        { role: "assistant", content: [
          { type: "thought", text: "signed reasoning", thoughtSignature: "sig_x" },
          { type: "thought", text: "unsigned reasoning" },
          { type: "thought", text: "" },
          { type: "output_text", text: "answer" },
        ] },
        { role: "user", content: "Follow-up" },
      ]
    )

    parts = JSON.parse(adapter.last_request.fetch(:body)).fetch("contents").flat_map { |content| content.fetch("parts", []) }
    thoughts = parts.select { |part| part["thought"] }
    assert_equal ["signed reasoning", "unsigned reasoning"], thoughts.map { |part| part.fetch("text") }, "empty-text thoughts are dropped"
    assert_equal "sig_x", thoughts.fetch(0).fetch("thoughtSignature")
    refute thoughts.fetch(1).key?("thoughtSignature"), "an unsigned replayed thought omits thoughtSignature"
    assert(parts.any? { |part| part["text"] == "answer" && !part["thought"] }, "the answer text is preserved")
  end

  # --- The declared-vocabulary + extra_body contract (transplant template):
  # request methods accept ONLY their declared symbol options, provider
  # wire fields ride extra_body verbatim, collisions with protocol-built
  # fields raise, and every body exits through finalize_wire_body. ---

  def test_gemini_request_option_keys_are_introspectable
    generate_content_keys = SimpleInference::Protocols::GeminiGenerateContent.request_option_keys

    assert_includes generate_content_keys, :thinking_config
    refute_includes generate_content_keys, :thinkingConfig, "the camelCase spelling is a wire field, not an option"
    assert generate_content_keys.frozen?
  end

  def test_generate_content_unknown_symbol_options_raise_and_point_at_extra_body
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: capturing_gemini_adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gemini-3.5-flash", input: "Hello", temperture: 0.2)
      end

    assert_includes error.message, "temperture"
    assert_includes error.message, "extra_body"
  end

  def test_generate_content_rejects_the_camel_case_thinking_config_spelling
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: capturing_gemini_adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gemini-3.5-flash", input: "Hello", thinkingConfig: { thinkingBudget: 512 })
      end

    assert_includes error.message, "thinkingConfig"
    assert_includes error.message, "extra_body"
  end

  def test_generate_content_declared_thinking_config_reaches_the_wire
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(model: "gemini-3.5-flash", input: "Hello", thinking_config: { thinkingBudget: 512, includeThoughts: true })

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal(
      { "thinkingBudget" => 512, "includeThoughts" => true },
      request_body.dig("generationConfig", "thinkingConfig")
    )
  end

  def test_generate_content_extra_body_merges_wire_fields_verbatim
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      max_output_tokens: 64,
      extra_body: {
        "safetySettings" => [{ "category" => "HARM_CATEGORY_HARASSMENT", "threshold" => "BLOCK_NONE" }],
        "cachedContent" => "cachedContents/abc",
      }
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal 64, request_body.dig("generationConfig", "maxOutputTokens")
    assert_equal [{ "category" => "HARM_CATEGORY_HARASSMENT", "threshold" => "BLOCK_NONE" }], request_body.fetch("safetySettings")
    assert_equal "cachedContents/abc", request_body.fetch("cachedContent")
  end

  def test_generate_content_extra_body_collisions_with_built_fields_raise
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: capturing_gemini_adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gemini-3.5-flash", input: "Hello", max_output_tokens: 64, extra_body: { "generationConfig" => {} })
      end

    assert_includes error.message, "generationConfig"
  end

  def test_generate_content_stream_rejects_unknown_options_before_streaming
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: capturing_gemini_adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.stream(model: "gemini-3.5-flash", input: "Hello", tempo: 1)
      end

    assert_includes error.message, "tempo"
    assert_includes error.message, "extra_body"
  end

  def test_generate_content_stream_extra_body_reaches_the_wire
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call_stream(env)
          @last_request = env
          yield "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }] })}\n\n"

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    protocol.stream(model: "gemini-3.5-flash", input: "Hello", extra_body: { "cachedContent" => "cachedContents/abc" }).to_a

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "cachedContents/abc", request_body.fetch("cachedContent")
  end

  # seed still maps INTO generationConfig (its real wire home); the
  # candidateCount surface no longer exists on this lane.
  def test_create_maps_seed_into_generation_config_without_candidate_count
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(model: "gemini-3.5-flash", input: "Hello", seed: 123)

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute body.key?("seed"), "seed must not be a top-level wire field"
    assert_equal 123, body.dig("generationConfig", "seed")
    refute body.fetch("generationConfig").key?("candidateCount")
  end

  def test_create_maps_json_object_response_format_to_response_mime_type
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(model: "gemini-3.5-flash", input: "Hello", response_format: { type: "json_object" })

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute body.key?("response_format"), "response_format must not be a top-level wire field"
    assert_equal "application/json", body.dig("generationConfig", "responseMimeType")
    refute body.fetch("generationConfig").key?("responseJsonSchema")
  end

  def test_create_maps_json_schema_response_format_to_response_json_schema
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    schema = { "type" => "object", "properties" => { "answer" => { "type" => "string" } } }

    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      response_format: { type: "json_schema", name: "reply", schema: schema, strict: true },
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "application/json", body.dig("generationConfig", "responseMimeType")
    assert_equal schema, body.dig("generationConfig", "responseJsonSchema")
  end

  # Load-bearing production mapping (the kernel routes catalog options through
  # this at spec-build time). temperature/top_p/top_k are frozen local
  # rejections for this lane (see the pre-wire rejection tests above), so
  # max_output_tokens is the only surviving sampling-adjacent control.
  def test_create_maps_max_output_tokens_into_generation_config
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(model: "gemini-3.5-flash", input: "Hi", max_output_tokens: 64)

    config = JSON.parse(adapter.last_request.fetch(:body)).fetch("generationConfig")
    assert_equal 64, config.fetch("maxOutputTokens")
  end

  def test_generate_content_full_vocabulary_is_pinned
    assert_equal(
      %i[tools tool_choice instructions max_output_tokens temperature top_p top_k reasoning_enabled reasoning_effort thinking_config seed n response_format],
      SimpleInference::Protocols::GeminiGenerateContent.request_option_keys,
    )
  end

  private

  def exploding_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        raise "a rejected request must never touch the adapter"
      end

      def call_stream(_env)
        raise "a rejected request must never touch the adapter"
      end
    end.new
  end

  def capturing_gemini_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
              usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1, totalTokenCount: 2 },
            }
          ),
        }
      end
    end.new
  end
end
