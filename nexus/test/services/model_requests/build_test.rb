require "test_helper"
require "test_helpers/log_capture"

# THE REQUEST PATH: read the Invocation-owned request, validate and compile it
# into ONE exact in-process provider request immediately before the claim.
#
# A request that cannot be valid is a typed pre-IO refusal that must terminalize
# without spending an ordinal. There is ONE builder: nothing else in this
# repository compiles a provider request.
class ModelRequests::BuildTest < ActiveSupport::TestCase
  include LogCapture
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:cybros)
    @creator = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  test "it compiles the accepted input into one exact wire request" do
    result = build(inference_request_invocation)

    assert_predicate result, :built?
    request = result.request
    assert_instance_of SimpleInference::CompiledRequest, request
    assert_predicate request, :stream?, "the dev text lane streams"
    body = JSON.parse(request.payload)
    assert_equal "mock-text", body.fetch("model")
    assert_equal "describe this",
      body.fetch("input").first.fetch("content").first.fetch("text")
  end

  # Provider prefix caching depends on request bytes, not only equivalent messages. Preserve
  # submission order and serialize a sealed body identically on retry; a single-message test
  # cannot detect a reordering regression.
  test "the wire preserves submission order, and rebuilding is byte-identical" do
    invocation = ordered_invocation(%w[alpha bravo charlie])

    first = build(invocation)
    assert_predicate first, :built?
    body = JSON.parse(first.request.payload)
    assert_equal %w[alpha bravo charlie],
      body.fetch("input").map { _1.fetch("content").first.fetch("text") },
      "tail-only growth is worth nothing if the tail is not where the wire puts it"

    # THE PREFIX, NOT THE WHOLE BODY, and the difference is worth recording
    # because this assertion caught it. A provider caches on the leading
    # messages; `request_options` sits after them and is stored as jsonb, which
    # PostgreSQL reorders by key length — so a freshly built invocation and a
    # reloaded one serialize `max_output_tokens/temperature/top_p` in different
    # orders while the `input` array is character-identical. Nothing digests
    # the compiled payload (the idempotency digest is taken over the accepted
    # envelope through canonical JSON), so whole-body determinism buys nothing
    # today. Anyone who later digests THIS payload has to fix the ordering
    # first, and this comment is where they find out why.
    second = build(invocation.reload)
    assert_equal JSON.parse(first.request.payload).fetch("input").to_json,
      JSON.parse(second.request.payload).fetch("input").to_json,
      "a retry recompiles the cached prefix byte for byte, or it re-pays for it"
  end

  test "adding a deferred Runner preserves the compiled tool prefix across wire families" do
    first_runner = suite_runner
    second_runner = connect_runner(manager: users(:owner), registration_identifier: "deferred-second",
      display_name: "Second Runner", assignment_scope: :account_wide).executor_access_token.task_executor
    assert_predicate second_runner.announce(tools: TEST_SERVED_TOOLS), :accepted?
    accessors = %w[tool_search tool_call].map { |name| Nexus::ToolRegistry.function_definition(name) }
    declarations = [first_runner, second_runner].map.with_index do |runner, index|
      TOOL.merge("defer_loading" => true,
        "function" => TOOL.fetch("function").merge("name" => "runner_#{index}_bash"),
        "route" => { "kind" => "runner", "runner_executor_public_id" => runner.public_id, "tool_name" => "bash" })
    end
    options = [declarations.first(1), declarations].map do |runner_tools|
      run = seed(model("work", "tools" => accessors + runner_tools),
        workspace: workspaces(:shared), creating_user: @creator, default_runner_executor_public_id: nil)
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: run, acting_user: @creator)), :accepted?
      clear_enqueued_jobs
      AgentRuns::ScheduleReady.call(agent_run_id: run.id)
      clear_enqueued_jobs
      node = run.agent_run_tasks.find_by!(node_key: "work")
      assert_equal 2 + runner_tools.length, node.tool_definitions.length, "authority retains the complete frozen set"
      ModelInvocation.find(node.selected_model_invocation_id).request_options
    end

    %w[openai_responses openai_compatible_chat anthropic_messages gemini_generate_content].each do |format|
      tool_prefixes = options.map do |request_options|
        invocation, profile = tooled_invocation(api_format: format,
          request_options: request_options.slice("tools", "instructions", "prompt_cache").merge("max_output_tokens" => 128))
        result = build(invocation, profile: profile, base_url: "https://lane.example")
        assert_predicate result, :built?, "#{format}: #{result.refusal}"
        JSON.parse(result.request.payload).fetch("tools").to_json
      end
      assert_equal tool_prefixes.first, tool_prefixes.last, format
      assert_includes tool_prefixes.first, "tool_search", format
      assert_includes tool_prefixes.first, "tool_call", format
      assert_not_includes tool_prefixes.last, "runner_", format
      assert_not_includes tool_prefixes.last, "defer_loading", format
    end
  end

  # The protocol lowers prepared bytes to the wire's own inline form before
  # the claim; dispatch sends these exact serialized bytes.
  # Nothing durable ever holds them: the row holds the accepted input, which
  # names its uploads.
  test "the built request carries the prepared bytes no row holds" do
    invocation = inference_request_invocation(with_image: true)

    result = build(invocation)

    assert_predicate result, :built?
    image_part = JSON.parse(result.request.payload).fetch("input")
      .flat_map { _1.fetch("content") }.find { _1["type"] == "input_image" }
    assert image_part.fetch("image_url").start_with?("data:image/png;base64,"),
      "the compiled request already carries the protocol's wire form"
    assert_predicate invocation.content_bodies.find_by!(role: "request"), :sealed?
  end

  # An Invocation whose owner input was never sealed has nothing to lower —
  # a provider-test Invocation exists before its diagnostic input is written.
  test "an invocation with no accepted input compiles nothing" do
    inference_request = InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared), creating_user: @creator,
      workload: "text_generation"
    )
    selection = DevModelLane.selection(workload: "text_generation", account: @account)
    result = build(DevModelLane.create_invocation!(inference_request: inference_request, selection: selection))

    assert_equal ModelRequests::Build::MISSING_INPUT, result.refusal
    assert_nil result.request
  end

  # Both ends read ONE declaration, and it reaches them through the gem so a
  # fourth copy cannot appear. Two different grounds arrive at the same
  # answer: wire truth for a lane whose endpoint answers 400 to a unary POST,
  # and a declared transport for every other SSE text lane.
  test "a text lane is lowered as the streaming request it is" do
    wire_forced = DevModelLane.profile_for("codex_subscription/gpt-6.1-sol")
    declared = DevModelLane.profile_for("dev/mock-text")

    assert wire_forced.wire_option(:stream_only), "codex reaches it from the wire"
    assert_predicate declared, :streaming?, "the dev text lane reaches it from its transport"
    [wire_forced, declared].each do |profile|
      assert ModelRequests::InputSource.streams?(profile), profile.profile_id
    end

    # A lane with no SSE route streams nothing, and the same one authority
    # says so.
    assert_not ModelRequests::InputSource.streams?(DevModelLane.profile_for("dev/mock-image"))
  end

  # The built request carries it to the dispatcher, which is the half that
  # matters: a request claiming to be unary on a streaming lane is what this
  # whole declaration exists to prevent.
  test "the built request for a streaming lane is a streaming request" do
    result = build(inference_request_invocation)

    assert_predicate result, :built?
    assert_predicate result.request, :stream?
  end

  # THE INLINE BYTE BOUND IS THE TERMINAL ONE. The token gate became advisory,
  # and this did not: it is about bytes this side actually assembles into a
  # request part, not an estimate of what a provider will charge. Its test
  # came from the deleted seal suite; the deletion left the bound with zero
  # assertions behind it, which a mutation pass found by removing the guard
  # and watching the whole suite stay green.
  test "prepared bytes over the inline bound refuse by their own name" do
    invocation = inference_request_invocation(with_image: true)

    result = nil
    Nexus::SizeBounds.stub(:bytes_within?, ->(name, _bytes) { name != :inline_binary_bound }) do
      result = build(invocation)
    end

    assert_equal ModelRequests::Build::OVER_INLINE_BOUND, result.refusal
    assert_nil result.request
  end

  # The bound is on bytes actually INLINED. A transcription's audio rides the
  # multipart byte payload, so it is never base64'd into a request part — and
  # holding it to this bound accepted a large upload under its own 100 MiB
  # bound and then refused it here, which
  # is work admitted that could never run.
  test "audio that never rides inline is not held to the inline bound" do
    invocation = transcription_invocation

    result = nil
    Nexus::SizeBounds.stub(:bytes_within?, ->(name, _bytes) { name != :inline_binary_bound }) do
      result = build(invocation)
    end

    assert_predicate result, :built?, "the multipart lane is exempt by workload, not by luck"
    request = result.request
    assert_not_predicate request, :stream?
    assert_includes request.payload.to_s, "RIFF",
      "the compiled multipart payload carries the audio bytes, never an inline data URI"
  end

  test "compiled transcription trusts the Active Storage media boundary" do
    invocation = transcription_invocation

    result = SimpleInference::MediaType.stub(
      :detect, ->(*) { raise "compiled transcription sniffed normalized storage bytes again" }
    ) do
      build(invocation)
    end

    assert_predicate result, :built?
    assert_includes result.request.payload.to_s, "RIFF"
  end

  # A vanished blob is a preparation failure with typed evidence, never an exception escaping a
  # typed command and never a silently dropped attachment.
  test "media that can no longer be prepared refuses under its own name" do
    invocation = inference_request_invocation(with_image: true)
    ModelRequests::UploadMedia.stub(
      :by_public_id, ->(*, **) { raise ActiveStorage::FileNotFoundError }
    ) do
      result = build(invocation)

      assert_equal ModelRequests::Build::MEDIA_UNUSABLE, result.refusal
      assert_nil result.request
    end
  end

  test "the build uses the current profile supplied by the send boundary" do
    invocation = inference_request_invocation
    snapshot = ModelCatalog.current
    model = snapshot.models.fetch("dev/mock-text").merge("model_id" => "current-wire-model")
    profile = ModelCatalog::ProfileBuilder.call(
      model_ref: "dev/mock-text", provider: snapshot.providers.fetch("dev"), model: model
    )

    result = build(invocation, profile: profile)

    assert_predicate result, :built?
    assert_equal "current-wire-model", JSON.parse(result.request.payload).fetch("model")
  end

  test "shipped image lanes use their provider's current inline-byte contract" do
    snapshot = ModelCatalog.current
    expected_formats = {
      "openai_api/gpt-image-2-2026-04-21" => nil,
      "xai/grok-imagine-image-2.0" => "b64_json",
    }

    expected_formats.each do |model_ref, expected_format|
      provider_id, model_tail = model_ref.split("/", 2)
      profile = ModelCatalog::ProfileBuilder.call(
        model_ref: model_ref,
        provider: snapshot.providers.fetch(provider_id),
        model: snapshot.models.fetch(model_ref)
      )
      invocation = image_invocation(
        provider_id: provider_id, model_ref: model_tail, profile: profile
      )

      result = build(invocation, profile: profile)

      assert_predicate result, :built?, model_ref
      body = JSON.parse(result.request.payload)
      if expected_format
        assert_equal expected_format, body.fetch("response_format"), model_ref
      else
        refute body.key?("response_format"), model_ref
      end
    end
  end

  # AN IMAGE UPLOAD ROUTES THE IMAGE LANE TO ITS EDITS PATH (the alignment
  # audit's F23): the bound uploads become the gem's `images:` in binding
  # order, lowered through the same bytes-only media preparation the
  # Responses lanes use, and the lane's declared encoding spells the body
  # (multipart on the public route). No upload, no edit: the generations
  # compile above is untouched.
  test "an image upload routes the image lane to its edits path" do
    profile = DevModelLane.profile_with(
      DevModelLane.profile_for("dev/mock-image"),
      input_modalities: ["image"],
      input_media: { "image" => { "mime_allowlist" => %w[image/png image/jpeg image/webp] } }
    )
    invocation = image_invocation(
      provider_id: "dev", model_ref: "mock-image", profile: profile, uploads: [create_upload]
    )

    result = build(invocation, profile: profile)

    assert_predicate result, :built?, result.refusal.inspect
    request = result.request
    assert_equal "/v1/images/edits", request.path
    assert_match %r{\Amultipart/form-data; boundary=}, request.headers.fetch("Content-Type")
    payload = request.payload.to_s
    assert_equal 1, payload.scan(%(name="image[]")).length
    assert_includes payload, "Content-Type: image/png\r\n\r\n#{png_bytes}"
    assert_includes payload, %(name="prompt"\r\n\r\ndraw a tiny house)
    refute_includes payload, %(name="mask"), "the kernel binds no mask slot"
  end

  # THE PROMPT CACHE KEY ROUTES BY THE HOST (alignment audit F4; codex-rs
  # client.rs prompt_cache_key — a parent and its children share routing):
  # a conversation-hosted invocation keys on the conversation, a standalone
  # loop's on the loop, and a InferenceRequest on nothing — neither reference keys a
  # one-off. NEVER the invocation id, which would defeat routing. Emitted on
  # the two Responses wires only; the dev lane speaks openai_responses.
  test "a conversation-hosted request carries the conversation's prompt cache key; a one-shot carries none" do
    conversation = Conversation.create!(
      workspace: workspaces(:shared), creating_user: @creator, answering_user: users(:agent)
    )
    hosted = conversation_invocation(conversation)

    body = JSON.parse(build(hosted).request.payload)
    assert_equal conversation.public_id, body.fetch("prompt_cache_key")

    refute JSON.parse(build(inference_request_invocation).request.payload).key?("prompt_cache_key"),
      "a one-off has no session to key on"
  end

  # A SERVICE TIER IS CODEX'S RULE ON THE WIRE (F20): sent only when the
  # row declares it, omitted for `default`, refused before IO otherwise —
  # the invocation's stored request fact, never a default of ours.
  test "a requested service tier reaches the Responses wire only when the row declares it" do
    declared = { "capabilities" => { "service_tiers" => %w[priority] } }
    invocation, profile = tooled_invocation(
      api_format: "openai_responses", tools: false, model: declared,
      request_options: { "service_tier" => "priority" }
    )
    result = build(invocation, profile: profile, base_url: "https://lane.example")
    assert_predicate result, :built?, result.refusal.inspect
    assert_equal "priority", JSON.parse(result.request.payload).fetch("service_tier")

    undeclared, plain = tooled_invocation(
      api_format: "openai_responses", tools: false, request_options: { "service_tier" => "flex" }
    )
    refused = build(undeclared, profile: plain, base_url: "https://lane.example")
    assert_equal ModelRequests::WireLowering::SERVICE_TIER_REFUSAL, refused.refusal

    default, _profile = tooled_invocation(
      api_format: "openai_responses", tools: false, model: declared,
      request_options: { "service_tier" => "default" }
    )
    body = JSON.parse(build(default, profile: profile, base_url: "https://lane.example").request.payload)
    refute body.key?("service_tier"), "codex omits the default tier"
  end

  # FUNCTION TOOLS ARE THE WIRE'S PROPERTY (owner 2026-09-16), and the
  # gem's gate stays: a row that writes `tool_calls: false` is the one
  # model known not to, and a function tool on it is still refused before
  # IO under the capability's own name — the default fills silence, never
  # an opt-out.
  test "an explicit tool_calls: false still refuses a function tool as model_capability_unavailable" do
    invocation, profile = tooled_invocation(api_format: "deepseek_responses", tool_calls: false)
    result = build(invocation, profile: profile, base_url: "https://lane.example")

    refute_predicate result, :built?
    assert_equal ModelRequests::Build::CAPABILITY_UNAVAILABLE, result.refusal
  end

  # NOT ONE WIRE BYTE CHANGES for a lane that already claimed tools. The
  # shipped kimi-k3 row is silent now; the same row with the deleted
  # `tool_calls: true` line put back compiles the same profile, and one
  # invocation built against each yields the same payload, byte for byte —
  # the tools the round merges ride exactly as they did on 2026-09-15.
  test "the shipped OpenRouter row builds the same bytes silent as it did claiming tools" do
    candidate = ModelCatalog::FileBase.compile(
      root: Rails.root.join("config/model_catalog"), override_dir: nil
    )
    provider = candidate.providers.fetch("openrouter")
    silent = candidate.models.fetch("openrouter/moonshotai/kimi-k3")
    refute silent.fetch("capabilities").key?("tool_calls"), "the row no longer restates its wire"
    claiming = silent.merge("capabilities" => silent.fetch("capabilities").merge("tool_calls" => true))

    model_ref = "openrouter/moonshotai/kimi-k3"
    invocation, profile_silent = tooled_invocation(
      api_format: "openrouter_chat", provider: provider, model: silent, model_ref: model_ref
    )
    profile_claiming = ModelCatalog::ProfileBuilder.call(model_ref: model_ref, provider: provider, model: claiming)
    assert_equal profile_claiming.capabilities, profile_silent.capabilities

    before = build(invocation, profile: profile_claiming, base_url: "https://lane.example")
    after = build(invocation, profile: profile_silent, base_url: "https://lane.example")
    assert_predicate before, :built?
    assert_predicate after, :built?
    assert_equal before.request.payload.b, after.request.payload.b, "byte-identical"
    assert_includes JSON.parse(after.request.payload).fetch("tools").map { _1.dig("function", "name") }, "bash"
  end

  # The Responses wire labels each assistant message it produced
  # (`phase`) and asks for the label back. It is a word of that ONE
  # grammar on that ONE lane: a different model on the same lane keeps
  # it, while a chat wire — whose lowering passes unknown keys through,
  # the one place a missing gate would show — never sees it, and a phase
  # with no origin has no licence to ride at all.
  test "an assistant message's phase reaches the wire only on the lane that produced it" do
    origin = { "provider_id" => "openai_api", "model_id" => "gpt-6.1-sol", "api_format" => "openai_responses" }
    phased = phased_message("Reading the file.", origin: origin)
    assistant = shipped_payload([user_message("read it"), phased], model_ref: "openai_api/gpt-6-luna")
      .fetch("input").find { |item| item["role"] == "assistant" }
    assert_equal "commentary", assistant["phase"], "a different model on the same lane keeps the label"

    messages = shipped_payload([user_message("read it"), phased], model_ref: "openrouter/z-ai/glm-5.3")
      .fetch("messages")
    assert_equal ["Reading the file."], messages.select { |m| m["role"] == "assistant" }.map { |m| wire_text(m) }
    assert messages.none? { |message| message.key?("phase") }, "a chat wire never receives the word"

    assistant = shipped_payload([user_message("read it"), phased_message("Reading the file.", origin: nil)],
      model_ref: "openai_api/gpt-6-luna").fetch("input").find { |item| item["role"] == "assistant" }
    assert_not assistant.key?("phase"), "the origin is the phase's licence"
  end

  # A Responses round that thought and spoke between its calls, inherited
  # by a chat model: the foreign reasoning items carry nothing across (the
  # chat model cannot read them, and no fence stands in for them), and the
  # round's calls still ride ONE assistant message — the commentary between
  # the calls folds into it — with every tool message after it, the shape a
  # strict chat endpoint accepts.
  test "a sealed Responses round with commentary between calls lowers to one assistant message on a chat wire" do
    origin = { "provider_id" => "openai_api", "model_id" => "gpt-6.1-sol", "api_format" => "openai_responses" }
    reasoning = ->(blob, summary) do
      Nexus::ReasoningInputItem.new(type: "reasoning_item", native_origin: origin, payload: {
        "type" => "reasoning", "encrypted_content" => blob,
        "summary" => [{ "type" => "summary_text", "text" => summary }],
      })
    end
    elements = [user_message("read both"), reasoning.call("E1", "plan one"),
                phased_message("Reading the first.", origin: origin), call_item("call_x"),
                reasoning.call("E2", "plan two"), call_item("call_y"), result_item("call_x"), result_item("call_y")]

    messages = shipped_payload(elements, model_ref: "openrouter/z-ai/glm-5.3").fetch("messages")
    assert_equal %w[user assistant tool tool], messages.map { |message| message["role"] }
    assert_equal "Reading the first.", wire_text(messages[1]), "no thought of another model rides as words"
    assert_equal %w[call_x call_y], messages[1].fetch("tool_calls").map { |c| c["id"] },
      "one assistant message carries the round's calls"
    assert_equal %w[call_x call_y], messages[2..].map { |message| message["tool_call_id"] },
      "every tool message follows the message carrying its call, no assistant message between"
  end

  # The broker's own round comes back to it with its reasoning in the
  # message's field: the detail blocks verbatim on the message that carries
  # the round's calls, the answer's words beside them.
  test "a chat model's own round carries its reasoning details on the calling message" do
    origin = { "provider_id" => "openrouter", "model_id" => "moonshotai/kimi-k3", "api_format" => "openrouter_chat" }
    blocks = [{ "type" => "reasoning.text", "text" => "read a first", "format" => "moonshot", "index" => 0 }]
    thought = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING, native_origin: origin,
      payload: { "type" => "reasoning_details", "blocks" => blocks })
    round = Nexus::TextInputMessage.new(role: "assistant", parts: [thought])
    elements = [user_message("read a"), round, call_item("call_a"), result_item("call_a")]

    messages = shipped_payload(elements, model_ref: "openrouter/moonshotai/kimi-k3").fetch("messages")
    assert_equal %w[user assistant tool], messages.map { |message| message["role"] }
    assert_equal blocks, messages[1].fetch("reasoning_details")
    assert_equal %w[call_a], messages[1].fetch("tool_calls").map { |c| c["id"] }
    assert_not messages[1].key?("reasoning_content"), "the blocks are the capture; the text is never sent twice"
  end

  # THE REQUEST'S KIND, stamped at the mint, is what the Anthropic markers read: a mainline request
  # writes its prefix for an hour, a branch or a subagent's for five minutes, the summarizer's none;
  # a request minted without the fact takes five minutes and its tail, and the placement line names
  # the kind either way.
  test "the stamped request kind sets the Anthropic markers' tier and tail" do
    input = [user_message("hi"), Nexus::TextInputMessage.new(role: "assistant",
      parts: [Nexus::TextInputPart.new(type: "text", text: "hello")]), user_message("and now")]
    markers = ->(payload) { payload.to_json.scan(/"cache_control":(\{[^}]*\})/).flatten.map { |m| JSON.parse(m) } }
    kind = ->(stamp) { { "max_output_tokens" => 1_024, "prompt_cache" => Nexus::PromptCache::RequestKind.stamp(stamp) } }

    mainline = nil
    lines = capture_log do
      mainline = shipped_payload(input, model_ref: "anthropic/claude-opus-5-5", request_options: kind.call("mainline"))
    end
    assert_equal [{ "type" => "ephemeral", "ttl" => "1h" }] * 2, markers.call(mainline), "stable and tail, an hour"
    assert_match(/event=prompt_cache_placement .*kind=mainline .*tier=1h/, lines.join)

    branch = shipped_payload(input, model_ref: "anthropic/claude-opus-5-5", request_options: kind.call("branch"))
    assert_equal [{ "type" => "ephemeral" }] * 2, markers.call(branch)

    summary = shipped_payload(input, model_ref: "anthropic/claude-opus-5-5", request_options: kind.call("summary"))
    assert_empty markers.call(summary), "the summarizer writes no marker at all"

    lines = capture_log do
      unstated = shipped_payload(input, model_ref: "anthropic/claude-opus-5-5",
        request_options: { "max_output_tokens" => 1_024 })
      assert_equal [{ "type" => "ephemeral" }] * 2, markers.call(unstated)
    end
    assert_match(/kind=unstated/, lines.join)
  end

  # The row's reasoning context is a request fact the send reads from the
  # catalog beside the effort: a GPT-6 API row asks for every turn's items.
  test "a row's reasoning context reaches the Responses wire beside the effort" do
    payload = shipped_payload([user_message("hi")], model_ref: "openai_api/gpt-6.1-sol",
      reasoning_effort: "medium", reasoning_context: "all_turns")

    assert_equal "all_turns", payload.dig("reasoning", "context")
    assert_equal "medium", payload.dig("reasoning", "effort")
  end

  private

    def user_message(text)
      Nexus::TextInputMessage.new(role: "user", parts: [Nexus::TextInputPart.new(type: "text", text: text)])
    end

    def phased_message(text, origin:)
      Nexus::TextInputMessage.new(role: "assistant", phase: "commentary", native_origin: origin,
        parts: [Nexus::TextInputPart.new(type: "text", text: text)])
    end

    # A chat message's words, whichever spelling its content took.
    def wire_text(message)
      content = message.fetch("content")
      Array(content).map { |part| part.fetch("text") }.join("\n")
    end

    # The wire payload of an invocation whose sealed request is `elements`,
    # built under the profile a shipped catalog row makes.
    def shipped_payload(elements, model_ref:, reasoning_effort: nil, reasoning_context: nil, request_options: {})
      candidate = ModelCatalog::FileBase.compile(root: Rails.root.join("config/model_catalog"), override_dir: nil)
      provider_id, model_id = Nexus::ModelRef.parse(model_ref).deconstruct
      profile = ModelCatalog::ProfileBuilder.call(model_ref: model_ref,
        provider: candidate.providers.fetch(provider_id), model: candidate.models.fetch(model_ref))
      inference_request = InferenceRequest.create!(account: @account, workspace: workspaces(:shared), creating_user: @creator,
        workload: "text_generation")
      body = ContentBodies::Replace.call(owner: inference_request, role: InferenceRequests::Create::BODY_ROLE,
        entries: Nexus::InputEntries.for(elements), seal: true)
      raise "input body refused: #{body.refusal.inspect}" unless body.accepted?

      invocation = ModelInvocation.create!(inference_request: inference_request, provider_id: provider_id, model_ref: model_id,
        reasoning_effort: reasoning_effort, request_options: request_options,
        admission_deadline_seconds: profile.total_execution_deadline_seconds)
      ContentBodies::CloneSealed.call(source: body.body, owner: invocation, role: "request")
      built = build(invocation, profile: profile, base_url: "https://lane.example", reasoning_context: reasoning_context)
      raise "build refused: #{built.refusal.inspect}" unless built.built?

      JSON.parse(built.request.payload)
    end

    def build(invocation, profile: DevModelLane.profile_for_invocation(invocation),
              base_url: ModelCatalog.provider_base_url(invocation.provider_id), reasoning_context: nil)
      ModelRequests::Build.call(
        invocation: invocation, profile: profile, base_url: base_url, host: "solid_queue",
        reasoning_context: reasoning_context
      )
    end

    def call_item(id)
      Nexus::ToolCallInputItem.new(type: "tool_call_item",
        payload: { "type" => "function_call", "call_id" => id, "name" => "read_file", "arguments" => "{}" })
    end

    def result_item(id)
      Nexus::ToolResultInputItem.new(type: "tool_result_item",
        payload: { "type" => "function_call_output", "call_id" => id, "output" => "contents of #{id}" })
    end

    def transcription_invocation
      bytes = "RIFF\x00\x00\x00\x00WAVEfmt #{SecureRandom.hex(4)}".b
      upload = @account.content_uploads.create!(
        creating_user: @creator,
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes), filename: "clip", content_type: "audio/wav"
        )
      )
      selection = DevModelLane.selection(workload: "transcription", account: @account)
      inference_request = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: @creator,
        workload: selection.workload
      )
      body = ContentBodies::Replace.call(
        owner: inference_request, role: InferenceRequests::Create::BODY_ROLE,
        entries: Nexus::InputEntries.for("a hint"),
        uploads: [upload], seal: true
      )
      raise "input body refused: #{body.refusal.inspect}" unless body.accepted?

      invocation = DevModelLane.create_invocation!(inference_request: inference_request, selection: selection)
      ContentBodies::CloneSealed.call(source: body.body, owner: invocation, role: "request")
      invocation
    end

    # A direct reply's invocation, hosted by the conversation the way
    # `Conversations::Inputs::ApplyNext#create_reply` hosts one.
    def conversation_invocation(conversation)
      selection = DevModelLane.selection(workload: "text_generation", account: @account)
      invocation = ModelInvocation.create!(
        conversation: conversation, creating_user: @creator,
        internal_creation_key: "conversation_reply:#{SecureRandom.uuid_v7}",
        **DevModelLane.invocation_attributes(selection)
      )
      body = ContentBodies::Replace.call(
        owner: invocation, role: "request",
        entries: Nexus::InputEntries.for("describe this"), seal: true
      )
      raise "request body refused: #{body.refusal.inspect}" unless body.accepted?

      invocation
    end

    def image_invocation(provider_id:, model_ref:, profile:, uploads: [])
      inference_request = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: @creator,
        workload: "image_generation"
      )
      body = ContentBodies::Replace.call(
        owner: inference_request, role: InferenceRequests::Create::BODY_ROLE,
        entries: Nexus::InputEntries.for_image("draw a tiny house", upload_public_ids: uploads.map(&:public_id)),
        uploads: uploads, seal: true
      )
      raise "input body refused: #{body.refusal.inspect}" unless body.accepted?

      invocation = ModelInvocation.create!(
        inference_request: inference_request,
        provider_id: provider_id,
        model_ref: model_ref,
        request_options: {},
        admission_deadline_seconds: profile.total_execution_deadline_seconds
      )
      ContentBodies::CloneSealed.call(source: body.body, owner: invocation, role: "request")

      invocation
    end

    # ONE FUNCTION TOOL in the shape the kernel merges onto a round's
    # request; every text wire carries it by default (owner 2026-09-16), and
    # the request validator refuses it only on a row that wrote
    # `tool_calls: false`.
    TOOL = {
      "type" => "function",
      "function" => { "name" => "bash", "description" => "Run a command.",
                      "parameters" => { "type" => "object", "properties" => {} } },
    }.freeze

    # A text invocation on ANY wire family with tools on the request. The
    # profile is composed the way the catalog composes one — a provider and
    # a model hash through the builder, `tool_calls` stated as a file would
    # state it (or a shipped row passed in whole) — so the lowering is read
    # on the real three layers and not on a hand-made profile. Build
    # compiles and never sends, so the lane's address is nominal.
    def tooled_invocation(api_format:, tool_calls: true, tools: true, credentials: "none",
                          provider: { "api_format" => api_format, "credentials" => credentials },
                          model: { "capabilities" => { "tool_calls" => tool_calls } }, model_ref: nil,
                          request_options: (tools ? { "tools" => [TOOL] } : {}))
      provider_id = "lane-#{api_format.tr("_", "-")}"
      profile = ModelCatalog::ProfileBuilder.call(
        model_ref: model_ref || "#{provider_id}/m", provider: provider, model: model
      )
      inference_request = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: @creator,
        workload: "text_generation"
      )
      body = ContentBodies::Replace.call(
        owner: inference_request, role: InferenceRequests::Create::BODY_ROLE,
        entries: Nexus::InputEntries.for("run the check"), seal: true
      )
      raise "input body refused: #{body.refusal.inspect}" unless body.accepted?

      invocation = ModelInvocation.create!(
        inference_request: inference_request,
        provider_id: provider_id,
        model_ref: "m",
        request_options: request_options,
        admission_deadline_seconds: profile.total_execution_deadline_seconds
      )
      ContentBodies::CloneSealed.call(source: body.body, owner: invocation, role: "request")
      [invocation, profile]
    end

    # A body of several messages in a known order, which is what an assembled
    # context will be and what no other case here exercises.
    def ordered_invocation(texts)
      selection = DevModelLane.selection(workload: "text_generation", account: @account)
      inference_request = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: @creator,
        workload: selection.workload
      )
      messages = texts.map do |text|
        Nexus::TextInputMessage.from_h(
          "role" => "user", "parts" => [{ "type" => "text", "text" => text }]
        )
      end
      body = ContentBodies::Replace.call(
        owner: inference_request, role: InferenceRequests::Create::BODY_ROLE,
        entries: Nexus::InputEntries.for(messages), uploads: [], seal: true
      )
      raise "input body refused: #{body.refusal.inspect}" unless body.accepted?

      invocation = DevModelLane.create_invocation!(inference_request: inference_request, selection: selection)
      ContentBodies::CloneSealed.call(source: body.body, owner: invocation, role: "request")
      invocation
    end

    def inference_request_invocation(with_image: false, input: "describe this")
      uploads = with_image ? [create_upload] : []
      parts = [{ "type" => "text", "text" => input }]
      uploads.each { |u| parts << { "type" => "upload", "upload_public_id" => u.public_id } }
      selection = DevModelLane.selection(workload: "text_generation", account: @account)
      inference_request = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: @creator,
        workload: selection.workload
      )
      body = ContentBodies::Replace.call(
        owner: inference_request, role: InferenceRequests::Create::BODY_ROLE,
        entries: Nexus::InputEntries.for(
          [Nexus::TextInputMessage.from_h("role" => "user", "parts" => parts)]
        ),
        uploads: uploads,
        seal: true
      )
      raise "input body refused: #{body.refusal.inspect}" unless body.accepted?

      invocation = DevModelLane.create_invocation!(inference_request: inference_request, selection: selection)
      ContentBodies::CloneSealed.call(source: body.body, owner: invocation, role: "request")
      invocation
    end

    def create_upload
      bytes = png_bytes
      @account.content_uploads.create!(
        creating_user: @creator,
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes), filename: "tiny", content_type: "image/png"
        )
      )
    end

    def png_bytes
      Base64.decode64(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
      )
    end
end
