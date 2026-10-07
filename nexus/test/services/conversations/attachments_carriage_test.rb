require "test_helper"

# THE CARRIAGE THROUGH THE KERNEL LANES: the reply lane seals exactly the placed set — the part and
# its join on a row that takes images, the index line and no join on one that cannot — the prompt
# clone carries the joins either way, a later turn's seed carries the picture, the loop-backed seed
# binds what it sends, a regenerate re-places under the re-ask's engine, and the estimate models the
# same placement.
class Conversations::AttachmentsCarriageTest < ActiveJob::TestCase
  include InvocationHarness

  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )
  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  def upload(filename = "diagram.png", bytes: PNG)
    @account.content_uploads.create!(
      creating_user: @user,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename, content_type: "image/png")
    )
  end

  def accept!(text: "look", attachments: nil, **overrides)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: @conversation, acting_user: @user, kind: "message",
      role: "user", entries: text ? [{ "text" => text }] : [], attachments: attachments, visible_in_context: true,
      delivery_mode: "queue", context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
    assert_predicate result, :accepted?, result.outcome.to_s
    result.value
  end

  def reply!(model_ref: "mock-text", **overrides)
    accept!(**{ kind: "direct_reply", provider_id: "dev", model_ref: model_ref }.merge(overrides))
  end

  def drain! = Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
  def last_variant = @conversation.conversation_turns.order(:position).last.active_variant
  def payloads(body) = body.content_body_entries.map { |entry| entry.content_fragment.payload }
  def sealed_request(variant) = variant.model_invocation.content_bodies.find_by!(role: "request")
  def part_types(payload) = Array(payload["parts"]).map { |part| part["type"] }

  def settle!(variant, answer: "seen")
    apply_via(admitted_attempt_for(@conversation), sse_success(answer))
    Conversations::Turns::Converge.call
    clear_enqueued_jobs
    variant.reload
  end

  def admitted_attempt_for(conversation)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.conversation_id == conversation.id
    end
    raise "not admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end

  test "ordinary attachments are indexed for tools and never passed as model media" do
    document = @account.content_uploads.create!(creating_user: @user,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new("ordinary words"), filename: "paper.txt",
        content_type: "text/plain", identify: false))
    reply!(attachments: [document.public_id])
    assert_equal 1, drain!
    variant = last_variant
    request = sealed_request(variant)
    assert_empty request.content_uploads
    assert_includes payloads(request).to_json, "nexus://uploads/#{document.public_id}"
    assert_includes payloads(request).to_json, "file content is available through attachment tools"
    assert_equal [document.id], variant.content_bodies.find_by!(role: "prompt").content_uploads.pluck(:id)
  end

  test "the reply lane seals the part and binds exactly the placed row; the prompt clone carries the join" do
    picture = upload
    input = reply!(attachments: [picture.public_id])
    prompt_fragments = input.content_body.content_body_entries.pluck(:content_fragment_id)

    assert_equal 1, drain!

    variant = last_variant
    request = sealed_request(variant)
    user_entry = payloads(request).last
    assert_equal %w[text upload], part_types(user_entry)
    assert_equal picture.public_id, user_entry.dig("parts", 1, "upload_public_id")
    assert_equal [picture.id], request.content_uploads.map(&:id), "the seal binds what it sends"

    prompt = variant.content_bodies.find_by!(role: "prompt")
    assert_equal prompt_fragments, prompt.content_body_entries.pluck(:content_fragment_id)
    assert_equal [picture.id], prompt.content_uploads.map(&:id), "the seed keeps the picture alive"
    assert_equal "look", prompt.readable_text

    built = ModelRequests::Build.call(
      invocation: variant.model_invocation, profile: DevModelLane.profile_for("dev/mock-text"),
      base_url: ModelCatalog.provider_base_url("dev"), host: "solid_queue"
    )
    assert_predicate built, :built?, built.refusal.inspect
    image = JSON.parse(built.request.payload).fetch("input").flat_map { |m| m.fetch("content") }
      .find { |part| part["type"] == "input_image" }
    assert image.fetch("image_url").start_with?("data:image/png;base64,"), "the bytes leave the process from the join"
  end

  test "on a text-only row the request seals the index line in position and binds nothing" do
    picture = upload("diagram.png")
    reply!(model_ref: "mock-text-only", attachments: [picture.public_id])

    assert_equal 1, drain!

    request = sealed_request(last_variant)
    user_entry = payloads(request).last
    assert_equal %w[text text], part_types(user_entry)
    assert_equal "[Attachment: diagram.png (image/png, 70 bytes) — image content omitted: this model does not support image input]",
      user_entry.dig("parts", 1, "text")
    assert_empty request.content_uploads, "nothing is sent, nothing is bound"
    assert_equal [picture.id], last_variant.content_bodies.find_by!(role: "prompt").content_uploads.map(&:id),
      "the seed still holds the picture for the next turn's engine to place"
  end

  test "shipped Codex models carry the conversation image through the sealed request to the wire" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    ModelProviders::EnableLane.call(account: @account, provider_id: "codex_subscription", expected_lock_version: nil)
    ModelProviders::InstallOAuthPair.call(
      account: @account, provider_id: "codex_subscription",
      access_token: "codex-image-test", refresh_token: "codex-image-refresh-test",
      provider_account_identity: "codex-image-account-test",
      lineage_id: SecureRandom.uuid_v7, expected_generation: nil, expires_at: 3.hours.from_now
    )
    source = PngFixture.bytes(width: 2304, height: 768)
    picture = upload(bytes: source)

    %w[gpt-6-astra gpt-6.1-sol gpt-6-luna].each do |model_id|
      @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
      reply!(provider_id: "codex_subscription", model_ref: model_id, attachments: [picture.public_id])
      applied = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
      assert_predicate applied, :accepted?, applied.outcome.to_s

      variant = last_variant
      request = sealed_request(variant)
      assert_equal %w[text upload], part_types(payloads(request).last), model_id
      assert_equal [picture.id], request.content_uploads.map(&:id), model_id

      profile = DevModelLane.profile_for("codex_subscription/#{model_id}")
      built = ModelRequests::Build.call(invocation: variant.model_invocation, profile: profile,
        base_url: "https://codex.example", host: "solid_queue")
      assert_predicate built, :built?, built.refusal.inspect
      assert_equal "/responses", built.request.path
      body = JSON.parse(built.request.payload)
      message = body.fetch("input").find { |entry| entry["role"] == "user" }
      image = message.fetch("content").find { |part| part["type"] == "input_image" }
      assert image.fetch("image_url").start_with?("data:image/png;base64,"), image.fetch("image_url").split(",", 2).first
      prepared = Base64.strict_decode64(image.fetch("image_url").split(",", 2).last)
      assert_equal [2048, 683], PngFixture.dimensions(prepared), "large images are resized, not refused"
      assert_equal source, picture.file.download, "the original attachment is retained"
      refute_includes message.to_json, "image content omitted"
    end
  end

  test "a picture-only input materializes, and a later turn's seed carries the picture native or as the line" do
    picture = upload("alone.png")
    accept!(text: nil, attachments: [picture.public_id])
    assert_equal 1, drain!
    message_turn = @conversation.conversation_turns.sole
    assert_equal "", message_turn.active_variant.content_bodies.sole.effective_text
    assert_equal [picture.id], message_turn.active_variant.content_bodies.sole.content_uploads.map(&:id)

    reply!(text: "what is it?")
    assert_equal 1, drain!
    request = sealed_request(last_variant)
    assert_equal [%w[upload text]], payloads(request).map { |payload| part_types(payload) },
      "the picture-only message turn and the prompt are adjacent user segments: the picture then the words"
    assert_equal [picture.id], request.content_uploads.map(&:id)
    settle!(last_variant)

    reply!(text: "and now?", model_ref: "mock-text-only")
    assert_equal 1, drain!
    entries = payloads(sealed_request(last_variant))
    assert_equal [%w[text text], %w[text], %w[text]], entries.map { |payload| part_types(payload) },
      "the message turn's line merged with the earlier seed, each its own part; its answer; the new prompt"
    assert_equal ["[Attachment: alone.png (image/png, 70 bytes) — image content omitted: this model does not support image input]",
                  "what is it?"],
      entries.first.fetch("parts").map { |part| part["text"] },
      "the line in the picture's position, ahead of the words that followed it"
    assert_empty sealed_request(last_variant).content_uploads
  end

  test "a loop-backed reply's seed binds the placed set and round one seals it again" do
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: @agent)
    outcome = Users::DeclareConfiguration.call(user: @agent,
      tool_definitions: [READ_TOOL], approval_mode: "bypass", approval_rules: nil,
      prompt_mechanism: nil, prompt_template: nil, compaction_policy: { "mode" => "kernel" }
    )
    assert_equal :declared, outcome.outcome
    picture = upload("loop.png")
    reply!(attachments: [picture.public_id])

    assert_equal 1, drain!
    agent_run = last_variant.agent_run
    seed = agent_run.agent_run_tasks.sole.content_bodies.find_by!(role: "input")
    assert_equal %w[text upload], part_types(payloads(seed).last)
    assert_equal [picture.id], seed.content_uploads.map(&:id), "the seed binds what round one will read"

    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    r1 = agent_run.agent_run_tasks.sole.reload
    assert_equal "running", r1.status
    request = ContentBody.find_by!(model_invocation_id: r1.selected_model_invocation_id, role: "request")
    assert_equal [picture.id], request.content_uploads.map(&:id), "round one's seal binds the placed row"
    assert_equal %w[text upload], part_types(payloads(request).last)
  end

  test "a regenerate on another engine re-places the window's pictures under that engine" do
    picture = upload("history.png")
    accept!(attachments: [picture.public_id])
    reply!(text: "describe it")
    assert_equal 2, drain!
    turn = @conversation.conversation_turns.order(:position).last
    settle!(turn.active_variant)
    assert_equal [picture.id], sealed_request(turn.reload.active_variant).content_uploads.map(&:id)

    result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id, acting_user: @user,
      provider_id: "dev", model_ref: "mock-text-only", reasoning_effort: nil, request_options: nil
    ))
    assert_predicate result, :accepted?, result.outcome.to_s

    request = result.value.model_invocation.content_bodies.find_by!(role: "request")
    assert_empty request.content_uploads, "a text-only engine is sent no picture"
    lines = payloads(request).flat_map { |payload| Array(payload["parts"]) }.select { |part| part["text"].to_s.include?("history.png") }
    assert_equal 1, lines.length, "the message turn's picture rides as the line"
    assert_equal "[Attachment: history.png (image/png, 70 bytes) — image content omitted: this model does not support image input]",
      lines.sole["text"], "the line is its own part, the words that followed it theirs"
  end

  %w[mock-priced mock-text-only].each do |model_ref|
    test "regenerate preserves the reply's own picture on #{model_ref}" do
      picture = upload("question.png")
      reply!(text: "describe this picture", attachments: [picture.public_id])
      assert_equal 1, drain!
      turn = @conversation.conversation_turns.sole
      settle!(turn.active_variant)

      result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
        conversation: @conversation, turn_public_id: turn.public_id, acting_user: @user,
        provider_id: "dev", model_ref: model_ref, reasoning_effort: nil, request_options: nil
      ))
      assert_predicate result, :accepted?, result.outcome.to_s
      request = sealed_request(result.value)
      parts = payloads(request).sole.fetch("parts")
      assert_equal "describe this picture", parts.first.fetch("text")
      if model_ref == "mock-priced"
        assert_equal picture.public_id, parts.last.fetch("upload_public_id")
        assert_equal [picture.id], request.content_uploads.map(&:id)
      else
        assert_includes parts.last.fetch("text"), "Attachment: question.png"
        assert_empty request.content_uploads
      end
    end
  end

  test "the estimate models the send's placement over history" do
    picture = upload("est.png")
    accept!(attachments: [picture.public_id])
    assert_equal 1, drain!

    estimate = Conversations::ContextEstimate.call(Conversations::ContextEstimate::Command.new(
      conversation: @conversation, acting_user: @user, provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: nil, request_options: nil, prompt: "so?", history_max_entries: nil,
      history_token_budget_share: nil, reasoning_replay_mode: nil, inline: nil
    ))
    assert_predicate estimate, :accepted?, estimate.outcome.to_s
    assert_equal 1, estimate.value.message_count, "the message turn and the prompt merge as on the send"

    text_only = Conversations::ContextEstimate.call(Conversations::ContextEstimate::Command.new(
      conversation: @conversation, acting_user: @user, provider_id: "dev", model_ref: "mock-text-only",
      reasoning_effort: nil, request_options: nil, prompt: "so?", history_max_entries: nil,
      history_token_budget_share: nil, reasoning_replay_mode: nil, inline: nil
    ))
    assert_predicate text_only, :accepted?, text_only.outcome.to_s
  end
end
