require "test_helper"

# THE MIGRATION'S ACCEPTANCE TEST, kept as a permanent one.
#
# The gem shipped 26 production profiles until 2026-08-21. This drives the
# builder with the catalog entries that replace them and asserts the profile
# it composes is the SAME OBJECT the gem used to hand out — field for field.
# It is what made deleting a 1,362-line registry a safe move rather than a
# hopeful one, and it goes on proving that the three layers compose the way
# the measurement said they did.
class ModelCatalog::ProfileBuilderTest < ActiveSupport::TestCase
  B = ModelCatalog::ProfileBuilder
  AF = SimpleInference::ApiFormat

  test "row headers override provider headers independently of authentication" do
    profile = B.call(model_ref: "gateway/m",
      provider: { "api_format" => "anthropic_messages", "authentication" => "bearer",
        "request_headers" => { "User-Agent" => "provider-client", "X-Routing" => "provider-route" } },
      model: { "request_headers" => { "user-agent" => "model-client" } })
    assert_equal "bearer", profile.authentication
    assert_equal({ "user-agent" => "model-client", "x-routing" => "provider-route" }, profile.request_headers)
    assert_raises(SimpleInference::ConfigurationError) do
      B.call(model_ref: "gateway/m", provider: { "api_format" => "anthropic_messages" },
        model: { "request_headers" => { "AUTHORIZATION" => "static-secret" } })
    end
  end

  test "a model that states nothing inherits its whole wire from the format" do
    profile = B.call(
      model_ref: "local/sample-text",
      provider: { "api_format" => "openai_compatible_chat", "credentials" => "none" },
      model: {}
    )

    assert_equal "openai_compatible_chat", profile.adapter_profile
    assert_equal "text_generation", profile.workload, "the wire names the work"
    assert_equal "sample-text", profile.model_pin, "the ref tail is the wire name"
    assert_equal "none", profile.credential_lane, "a local server authenticates nothing"
    assert_equal AF.deadline_seconds("text_generation"), profile.total_execution_deadline_seconds
    assert_equal({ "input_tokens" => 128_000 }, profile.local_safety_limits.to_h,
      "an unmeasured model is never assumed bigger than it is")
    assert_equal AF.defaults("openai_compatible_chat")[:protocol_route], profile.protocol_route
  end

  test "credentials is the operator's word, translated at this boundary" do
    lane = ->(declared) do
      B.call(model_ref: "p/m", provider: { "api_format" => "openai_responses" }
        .merge(declared.nil? ? {} : { "credentials" => declared }), model: {}).credential_lane
    end

    assert_equal "api_key", lane.call(nil), "api_key is the default"
    assert_equal "none", lane.call("none")
    assert_equal "oauth_tokens", lane.call("codex"),
      "the operator says codex; the wire vocabulary keeps its own word"
    assert_raises(ModelCatalog::CompileError) { lane.call("bearer") }
  end

  test "a provider bends one wire option and still speaks the rest of its format" do
    format_options = AF.defaults("codex_responses")[:wire_options]
    profile = B.call(
      model_ref: "codex_subscription/text",
      provider: {
        "api_format" => "codex_responses",
        "credentials" => "codex",
        "wire_options" => { "responses_path" => "/custom/responses" },
      },
      model: {}
    )

    assert_equal "/custom/responses", profile.wire_options[:responses_path]
    format_options.except(:responses_path).each do |key, value|
      assert_equal value, profile.wire_options[key], "#{key} came from the format"
    end
  end

  test "the model overrides its provider's format, and only the few that must" do
    profile = B.call(
      model_ref: "openai_api/image",
      provider: { "api_format" => "openai_responses" },
      model: { "api_format" => "openai_images" }
    )

    assert_equal "openai_images", profile.adapter_profile
    assert_equal "image_generation", profile.workload,
      "overriding the wire moves the workload with it"
    assert_equal AF.deadline_seconds("image_generation"),
      profile.total_execution_deadline_seconds
  end

  test "a measured model states its own window and modality" do
    profile = B.call(
      model_ref: "anthropic/text",
      provider: { "api_format" => "anthropic_messages" },
      model: { "capabilities" => {
        "input_modalities" => ["image"],
        "limits" => { "input_tokens" => 1_000_000, "output_tokens" => 128_000 },
      } }
    )

    assert_equal ["image"], profile.input_modalities
    assert_equal 1_000_000, profile.local_safety_limits.input_tokens
  end

  test "an unknown format refuses at the boundary, never by guessing" do
    assert_raises(SimpleInference::ConfigurationError) do
      B.call(model_ref: "p/m", provider: { "api_format" => "no_such_wire" }, model: {})
    end
  end

  # `tool_calls` is a boolean and only that (owner 2026-09-16): `true`
  # declares the capability, `false` is the opt-out, and no profile member
  # says anything further about the calls.
  test "tool_calls' two boolean forms declare and refuse the capability" do
    stated = lambda do |tool_calls|
      B.call(
        model_ref: "openai_api/text",
        provider: { "api_format" => "openai_responses" },
        model: { "capabilities" => { "tool_calls" => tool_calls } }
      )
    end

    assert stated.call(true).capability_enabled?("tool_calls")
    refute stated.call(false).capability_enabled?("tool_calls")
    refute_respond_to stated.call(true), :parallel_tool_calls, "the profile states no parallel fact"
  end

  # FUNCTION TOOLS ARE THE WIRE'S PROPERTY (owner 2026-09-16). A row that
  # says nothing about `tool_calls` has the capability on every wire whose
  # protocol declares `tools` as a request option — the fact the lowering
  # reads from the vendored gem, and every text_generation wire declares it
  # — so the official DeepSeek floor runs its first loop with no claim in
  # its row. `false` is the explicit opt-out for a model known not to; a
  # wire that carries no tools (images, speech, embeddings) inherits nothing.
  test "a silent row has tool_calls on every wire that carries tools, and off where it does not" do
    silent = ->(api_format) do
      B.call(
        model_ref: "lane/m", provider: { "api_format" => api_format, "credentials" => "none" }, model: {}
      ).capability_enabled?("tool_calls")
    end

    assert silent.call("deepseek_responses"), "the floor's wire, with no tool_calls line"
    text_wires = AF::WORKLOADS.select { |_format, workload| workload == "text_generation" }.keys
    text_wires.each do |api_format|
      assert silent.call(api_format), "#{api_format} declares tools; the default is on"
      assert ModelRequests::WireLowering.carries_function_tools?(api_format)
    end
    (AF::FORMATS - text_wires).each do |api_format|
      refute silent.call(api_format), "#{api_format} carries no tools; nothing to default"
      refute ModelRequests::WireLowering.carries_function_tools?(api_format)
    end

    opted_out = B.call(
      model_ref: "lane/m", provider: { "api_format" => "deepseek_responses", "credentials" => "none" },
      model: { "capabilities" => { "tool_calls" => false } }
    )
    refute opted_out.capability_enabled?("tool_calls"), "an explicit false is the one opt-out"
  end

  # PROMPT CACHING IS EVERY TEXT WIRE'S DEFAULT (owner 2026-09-16: the
  # provider caches a stable prefix — Anthropic through the kernel-placed
  # breakpoints, every other family implicitly). A row silent on
  # `prompt_caching` has it on every text-generation wire and on no
  # image/speech/transcription/embedding one; `false` is the one opt-out,
  # and a written `true` says nothing more than silence does. The
  # BREAKPOINT placement belongs to Messages and Bedrock — a different
  # predicate, read by Build, never by the capability.
  test "a silent row has prompt_caching on every text wire, with explicit native breakpoint wires" do
    silent = ->(api_format) do
      B.call(
        model_ref: "lane/m", provider: { "api_format" => api_format, "credentials" => "none" }, model: {}
      ).capability_enabled?("prompt_caching")
    end

    text_wires, other_wires = AF::FORMATS.partition { |api_format| AF.workload(api_format) == "text_generation" }
    assert text_wires.include?("anthropic_messages") && text_wires.include?("openai_responses")
    text_wires.each do |api_format|
      assert silent.call(api_format), "#{api_format} caches a stable prefix; the fact is on with no line in the row"
      assert ModelRequests::WireLowering.carries_prompt_caching?(api_format)
    end
    other_wires.each do |api_format|
      refute silent.call(api_format), "#{api_format} has no prompt to cache"
      refute ModelRequests::WireLowering.carries_prompt_caching?(api_format)
    end
    %w[anthropic_messages bedrock_converse].each do |api_format|
      assert ModelRequests::WireLowering.carries_cache_breakpoints?(api_format)
    end
    (AF::FORMATS - %w[anthropic_messages bedrock_converse]).each do |api_format|
      refute ModelRequests::WireLowering.carries_cache_breakpoints?(api_format), "#{api_format}: nothing for the kernel to mark"
    end

    stated = lambda do |api_format, prompt_caching|
      B.call(
        model_ref: "lane/m", provider: { "api_format" => api_format, "credentials" => "none" },
        model: { "capabilities" => { "prompt_caching" => prompt_caching } }
      ).capability_enabled?("prompt_caching")
    end
    refute stated.call("anthropic_messages", false), "an explicit false is the one opt-out"
    refute stated.call("openai_responses", false), "on every wire"
    assert stated.call("anthropic_messages", true), "true says nothing more than silence"
    refute stated.call("openai_images", true), "and claims nothing on a wire without a prompt to cache"
  end

  # STREAMING IS THE WIRE'S DEFAULT TOO (owner 2026-09-16): a row silent
  # on it streams on every wire whose protocol has a streaming parser and
  # on none of the unary ones; `false` opts out; a written `true` on a
  # unary wire is not a claim the profile carries.
  test "a silent row streams on every wire with a streaming parser, and off where there is none" do
    silent = ->(api_format) do
      B.call(
        model_ref: "lane/m", provider: { "api_format" => api_format, "credentials" => "none" }, model: {}
      ).capability_enabled?("streaming")
    end
    text_wires = AF::WORKLOADS.select { |_format, workload| workload == "text_generation" }.keys

    text_wires.each do |api_format|
      assert silent.call(api_format), "#{api_format} streams"
      assert ModelRequests::WireLowering.carries_streaming?(api_format)
    end
    (AF::FORMATS - text_wires).each do |api_format|
      refute silent.call(api_format), "#{api_format} answers one body"
      refute ModelRequests::WireLowering.carries_streaming?(api_format)
    end

    stated = lambda do |api_format, streaming|
      B.call(
        model_ref: "lane/m", provider: { "api_format" => api_format, "credentials" => "none" },
        model: { "capabilities" => { "streaming" => streaming } }
      ).capability_enabled?("streaming")
    end
    refute stated.call("openai_responses", false), "an explicit false is the one opt-out"
    refute stated.call("openai_images", true), "a written true on a unary wire says nothing more"
  end

  # STRUCTURED OUTPUT IS THE WIRE'S DEFAULT (owner 2026-09-16): a row
  # silent on `output_format` offers it on every text wire whose protocol
  # carries `response_format`, with the wire's own allowed kinds and NO
  # default — a plain turn still sends nothing. A row's own descriptor
  # stands as written; `output_format: false` is the one opt-out.
  test "a silent text row offers the wire's output_format with no default" do
    profile = ->(api_format, capabilities = {}) do
      B.call(
        model_ref: "lane/m", provider: { "api_format" => api_format, "credentials" => "none" },
        model: { "capabilities" => capabilities }
      )
    end
    text_wires = AF::WORKLOADS.select { |_format, workload| workload == "text_generation" }.keys -
      %w[bedrock_converse pi_messages]

    text_wires.each do |api_format|
      descriptor = profile.call(api_format).generation_parameters["output_format"]
      refute_nil descriptor, "#{api_format} carries response_format; the offer is the wire's"
      assert_equal "output_format", descriptor.kind
      assert_nil descriptor.default, "#{api_format}: offered, never imposed"
      assert_equal ModelRequests::WireLowering.allowed_output_formats(api_format), descriptor.allowed_values
      assert ModelRequests::WireLowering.carries_output_format?(api_format)
    end
    assert_equal %w[json_schema], profile.call("anthropic_messages").generation_parameters["output_format"].allowed_values,
      "the Messages protocol lowers json_schema alone (text and json_object are its local rejections)"
    (AF::FORMATS - text_wires).each do |api_format|
      refute profile.call(api_format).generation_parameters.key?("output_format"),
        "#{api_format} has no structured text format contract"
      refute ModelRequests::WireLowering.carries_output_format?(api_format)
    end

    narrowed = profile.call("openai_responses", "generation_parameters" => {
      "output_format" => {
        "kind" => "output_format", "default" => nil, "minimum" => nil, "maximum" => nil,
        "allowed_values" => %w[json_schema],
      },
    }).generation_parameters
    assert_equal %w[json_schema], narrowed["output_format"].allowed_values, "a row's own descriptor stands"

    opted_out = profile.call("openai_responses", "generation_parameters" => {
      "output_format" => false,
      "temperature" => { "kind" => "number", "default" => nil, "minimum" => 0.0, "maximum" => 2.0, "allowed_values" => nil },
    }).generation_parameters
    refute opted_out.key?("output_format"), "an explicit false is the one opt-out"
    assert opted_out.key?("temperature"), "and the row's other controls stand"

    speech = profile.call("openai_audio_speech").generation_parameters
    assert speech.key?("voice"), "a wire's own default controls are untouched"
  end
end
