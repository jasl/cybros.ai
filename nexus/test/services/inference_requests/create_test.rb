require "test_helper"

# The one atomic create command. Its whole reason to exist is that acceptance is a single fact: a
# caller either has a durable InferenceRequest with its invocation, queue row, sealed input body, and
# receipt, or has nothing at all. Admission and authority races live in the companion admission
# test; this file pins the aggregate and the result algebra.
class InferenceRequests::CreateTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @creator = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @port = DevModelLane.port
  end

  def text_message(text, role: "user")
    { "role" => role, "parts" => [{ "type" => "text", "text" => text }] }
  end

  # One ordered closed part stream: text and each attachment OCCURRENCE keep their relative
  # positions.
  def mixed_message(text, upload_public_ids, role: "user")
    parts = [{ "type" => "text", "text" => text }]
    upload_public_ids.each do |id|
      parts << { "type" => "upload", "upload_public_id" => id }
    end
    { "role" => role, "parts" => parts }
  end

  def command(**overrides)
    InferenceRequests::Create::Command.new(
      **{
        workspace: @workspace, creating_user: @creator, workload: "text_generation",
        submitted: DevModelLane.submission_for("text_generation"),
        configuration: {}, input: [text_message("hello")], upload_public_ids: [],
        billing_subject: nil, idempotency_key: SecureRandom.uuid,
      }.merge(overrides)
    )
  end

  def create(**overrides)
    InferenceRequests::Create.call(command: command(**overrides), port: @port)
  end

  def upload(creating_user: @creator, bytes: "an image", media_type: "image/png")
    @account.content_uploads.create!(
      creating_user: creating_user,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(bytes), filename: "a.png", content_type: media_type
      )
    )
  end

  test "one accepted create commits the whole aggregate" do
    result = create

    assert_predicate result, :created?
    inference_request = InferenceRequest.find_by(public_id: result.accepted.fetch("inference_request_public_id"))
    assert_equal({ "inference_request_public_id" => inference_request.public_id, "workload" => "text_generation" },
      result.accepted)
    assert_equal @workspace, inference_request.workspace
    assert_equal @creator, inference_request.creating_user

    invocation = inference_request.model_invocation
    assert_equal "queued", invocation.status
    assert_equal ModelInvocation.internal_creation_key_for(inference_request: inference_request),
      invocation.internal_creation_key

    body = inference_request.content_bodies.sole
    assert_equal "input", body.role
    assert_predicate body, :sealed?
    assert_equal 1, body.content_body_entries.count

    request = invocation.content_bodies.find_by!(role: "request")
    assert_predicate request, :sealed?
    assert_equal body.content_body_entries.pluck(:content_fragment_id),
      request.content_body_entries.pluck(:content_fragment_id),
      "identity assembly reuses the source fragments without merging their authorities"
    assert_equal InferenceRequestCreateReceipt.find_by(inference_request: inference_request).result, result.accepted
  end

  # A continuation that resends its prefix must store only the new message, reusing unchanged
  # fragments.
  test "a second prompt over the same prefix stores only the message that changed" do
    prefix = [text_message("system rules"), text_message("first answer", role: "assistant")]
    create(input: prefix)

    before = ContentFragment.count
    second = create(input: prefix + [text_message("second question")])

    assert_predicate second, :created?
    assert_equal 1, ContentFragment.count - before,
      "the unchanged prefix must re-reference its fragments instead of storing a copy"
    body = InferenceRequest.find_by(public_id: second.accepted.fetch("inference_request_public_id")).content_bodies.sole
    assert_equal 3, body.content_body_entries.count
  end

  test "an exact replay returns the same accepted value and creates nothing new" do
    key = SecureRandom.uuid
    first = create(idempotency_key: key)

    counts = -> { [InferenceRequest.count, ModelInvocation.count, ContentBody.count, InferenceRequestCreateReceipt.count] }
    before = counts.call
    replay = create(idempotency_key: key)

    assert_predicate replay, :replayed?
    assert_equal first.accepted, replay.accepted
    assert_equal before, counts.call
  end

  test "nil and omitted upload references are one upload-free command" do
    key = SecureRandom.uuid

    first = create(idempotency_key: key, upload_public_ids: nil)
    replay = create(idempotency_key: key)

    assert_predicate first, :created?
    assert_predicate replay, :replayed?
    assert_equal first.accepted, replay.accepted
    body = InferenceRequest.find_by(public_id: first.accepted.fetch("inference_request_public_id")).content_bodies.sole
    assert_empty body.content_uploads
  end

  test "the same key with a different command is a mismatch that names no target" do
    key = SecureRandom.uuid
    create(idempotency_key: key)

    result = create(idempotency_key: key, input: [text_message("something else")])

    assert_equal :idempotency_mismatch, result.outcome
    assert_nil result.accepted
    assert_nil result.refusal
    assert_equal 1, InferenceRequest.count
  end

  # Allowlisting happens before the digest, so a member the grammar drops cannot turn a retry into a
  # different command — otherwise a client that added a harmless field would get a conflict instead
  # of its own answer back.
  test "a member the grammar drops does not make a second command" do
    key = SecureRandom.uuid
    first = create(idempotency_key: key)

    replay = create(
      idempotency_key: key,
      input: [{ "role" => "user", "name" => "noise",
                "parts" => [{ "type" => "text", "text" => "hello", "cache" => true }] }]
    )

    assert_predicate replay, :replayed?
    assert_equal first.accepted, replay.accepted
  end

  # Generation parameters are most of what a caller wants to say. The grammar
  # judges a symbol-keyed configuration and the digest can only carry String
  # keys, so the envelope has to project one into the other — otherwise the
  # only configuration this command can accept is no configuration at all.
  test "a configuration the grammar accepts reaches the Invocation request" do
    result = create(configuration: { temperature: 0.4 })

    assert_predicate result, :created?
    inference_request = InferenceRequest.find_by(public_id: result.accepted.fetch("inference_request_public_id"))
    assert_equal 0.4, inference_request.model_invocation.request_options.fetch("temperature")
  end

  test "the configuration is part of what makes a command that command" do
    key = SecureRandom.uuid
    create(idempotency_key: key, configuration: { temperature: 0.4 })

    assert_equal :idempotency_mismatch,
      create(idempotency_key: key, configuration: { temperature: 0.9 }).outcome
    assert_predicate create(idempotency_key: key, configuration: { temperature: 0.4 }), :replayed?
  end

  test "a structured configuration value is carried too" do
    result = create(configuration: { output_format: Nexus::OutputFormat.text })

    assert_predicate result, :created?
  end

  # The idempotency key is scoped to the caller in the workspace. The digest includes workload
  # along with every other payload dimension, so changing workload cannot create a second billable
  # request under the same key.
  test "the same key under another workload is a divergence" do
    key = SecureRandom.uuid
    create(idempotency_key: key)

    other = create(
      idempotency_key: key, workload: "embedding", input: "embed me",
      submitted: DevModelLane.submission_for("embedding")
    )

    assert_equal :idempotency_mismatch, other.outcome
  end

  test "an expired reservation is taken over by a new create" do
    key = SecureRandom.uuid
    first = create(idempotency_key: key)
    InferenceRequestCreateReceipt.update_all(created_at: 25.hours.ago)

    second = create(idempotency_key: key)

    assert_predicate second, :created?
    assert_not_equal first.accepted, second.accepted
    assert_nil InferenceRequestCreateReceipt.find_by(inference_request_id: InferenceRequest.find_by(
      public_id: first.accepted.fetch("inference_request_public_id")
    ).id), "the expired receipt stopped reserving the key"
  end

  # The counts are DELTAS: this file shares its worker's database with tests
  # that commit on their own connections (the row-lock race helpers), so an
  # absolute zero has read another test's rows under parallel workers; the
  # property is "a refusal writes nothing", which a delta states exactly.
  test "a refused command persists nothing and carries no target" do
    before = [InferenceRequest.count, ContentBody.count, InferenceRequestCreateReceipt.count]
    [
      { submitted: Nexus::SubmittedModelSelection.new(model: "dev/nope", reasoning_effort: nil) },
      { input: nil },
      { input: [{ "role" => "user" }] },
      { upload_public_ids: [SecureRandom.uuid_v7] },
      { upload_public_ids: ["not-a-uuid"] },
      # A billing subject no longer refuses by existing (C2-3 activated the
      # member); only one too long to store does.
      { billing_subject: "x" * (BillingSubject::KEY_MAX_LENGTH + 1) },
      # A number the canonical encoder cannot carry is an answer, not a fault:
      # the digest is taken before the grammar, so nothing else can refuse it.
      { configuration: { "temperature" => 1e-20 } },
      # And a string PostgreSQL cannot store. The grammar asks only whether a
      # string is present, so without this the value reaches the INSERT and
      # aborts the create with a database error.
      { input: [text_message("hi\u0000there")] },
    ].each do |overrides|
      result = create(**overrides)

      assert_equal :refused, result.outcome, "#{overrides.keys} must refuse"
      assert_not_nil result.refusal
      assert_nil result.accepted
    end

    assert_equal before, [InferenceRequest.count, ContentBody.count, InferenceRequestCreateReceipt.count],
      "a refusal writes nothing"
  end

  # Every other refusal is decided before the owner row exists. This one is
  # found after it, which is the only case where atomicity is doing real work
  # — and it must hold whether or not a caller wrapped the command in a
  # transaction of their own.
  test "a refusal found after the owner insert takes its own writes back" do
    oversized = [text_message("x" * 1_100_000)]
    before = [InferenceRequest.count, ContentBody.count, ContentFragment.count]

    result = create(input: oversized)

    assert_equal :refused, result.outcome
    assert_equal before, [InferenceRequest.count, ContentBody.count, ContentFragment.count],
      "the owner insert and everything under it were taken back"

    ApplicationRecord.transaction do
      assert_equal :refused, create(input: oversized).outcome
      assert_equal before.first, InferenceRequest.count
    end
    assert_equal before.first, InferenceRequest.count
  end

  test "every v1 workload can be created" do
    audio = upload(bytes: "some audio", media_type: "audio/wav")

    [
      ["text_generation", [text_message("hi")], []],
      ["image_generation", "draw a cat", []],
      ["speech_generation", "say this out loud", []],
      ["transcription", nil, [audio.public_id]],
      ["embedding", "embed me", []],
    ].each do |workload, input, upload_public_ids|
      result = create(
        workload: workload, input: input, upload_public_ids: upload_public_ids,
        submitted: DevModelLane.submission_for(workload)
      )

      assert_predicate result, :created?, "#{workload} must be creatable"
      assert_equal workload, result.accepted.fetch("workload")
    end
  end

  # A refusal must not reserve the key either — the caller can fix the command
  # and retry with the same one.
  test "a refusal leaves the key free for the corrected command" do
    key = SecureRandom.uuid
    create(idempotency_key: key, input: nil)

    assert_predicate create(idempotency_key: key), :created?
  end

  test "an upload the caller owns is bound to the body" do
    first = upload
    second = upload

    result = create(
      input: [mixed_message("look", [first.public_id])],
      upload_public_ids: [first.public_id]
    )

    assert_predicate result, :created?
    body = InferenceRequest.find_by(public_id: result.accepted.fetch("inference_request_public_id")).content_bodies.sole
    assert_equal [first], body.content_uploads
    assert_empty second.content_bodies
  end

  # THE BIND'S LOCK: the resolved rows are pinned `FOR KEY SHARE` inside the door's transaction, so
  # the orphan reaper cannot destroy one between the read and the join — the conversation door's
  # pin, on this door's own upload rows.
  test "the door pins the resolved uploads FOR KEY SHARE before it binds them" do
    picture = upload
    statements = []
    subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
      statements << payload[:sql].to_s unless payload[:cached] || payload[:name] == "SCHEMA"
    end

    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      create(input: [mixed_message("look", [picture.public_id])], upload_public_ids: [picture.public_id])
    end

    assert_predicate result, :created?
    pinned = statements.grep(/FROM "content_uploads"/).grep(/FOR KEY SHARE OF content_uploads\z/)
    assert_equal 1, pinned.length, "one locked read of the rows about to be bound"
    bind = statements.index { |sql| sql.start_with?('INSERT INTO "content_body_uploads"') }
    assert_operator statements.index(pinned.sole), :<, bind, "pinned before the join is written"
    workspace_lock = statements.index { |sql| sql.start_with?('SELECT "workspaces".*') && sql.end_with?("FOR UPDATE") }
    assert_operator workspace_lock, :<, statements.index(pinned.sole),
      "resolved inside the lock section, after the owner rows are held"
  end

  test "accepted UUID spellings normalize before digest and resolution" do
    image = upload
    key = SecureRandom.uuid
    canonical = image.public_id

    first = create(
      idempotency_key: key,
      input: [mixed_message("look", [canonical])],
      upload_public_ids: [canonical]
    )
    replay = create(
      idempotency_key: key,
      input: [mixed_message("look", [canonical.upcase])],
      upload_public_ids: ["{#{canonical}}"]
    )

    assert_predicate first, :created?
    assert_predicate replay, :replayed?
    assert_equal first.accepted, replay.accepted
  end

  test "the same upload at two text input positions creates one liveness join" do
    image = upload

    result = create(
      input: [mixed_message("before", [image.public_id]),
              mixed_message("after", [image.public_id])],
      upload_public_ids: [image.public_id, image.public_id]
    )

    assert_predicate result, :created?
    body = InferenceRequest.find_by(public_id: result.accepted.fetch("inference_request_public_id")).content_bodies.sole
    assert_equal [image.id], body.content_body_uploads.pluck(:content_upload_id)
  end

  # Transcription's whole input is its upload, so its body legitimately has no
  # entries at all — a shape the aggregate must accept rather than treat as
  # missing content.
  test "an upload-only workload seals a body with one upload and no entries" do
    audio = upload(bytes: "some audio", media_type: "audio/wav")

    result = create(
      workload: "transcription", input: nil,
      submitted: DevModelLane.submission_for("transcription"),
      upload_public_ids: [audio.public_id]
    )

    assert_predicate result, :created?
    body = InferenceRequest.find_by(public_id: result.accepted.fetch("inference_request_public_id")).content_bodies.sole
    assert_predicate body, :sealed?
    assert_equal 0, body.content_body_entries.count
    assert_equal audio, body.content_uploads.sole
  end

  # Production composes no port. A create that reached the database before
  # discovering it cannot select a model would leave rows behind.
  test "without a resolver the command refuses before touching anything" do
    result = InferenceRequests::Create.call(command: command)

    assert_equal :refused, result.outcome
    assert_equal 0, InferenceRequest.count
  end

  test "the caller's selection is resolved exactly once" do
    counting = Class.new do
      attr_reader :calls

      def initialize(port) = (@port = port; @calls = 0)

      def resolve(**arguments)
        @calls += 1
        @port.resolve(**arguments)
      end
    end.new(@port)

    key = SecureRandom.uuid
    InferenceRequests::Create.call(command: command(idempotency_key: key), port: counting)
    InferenceRequests::Create.call(command: command(idempotency_key: key), port: counting)

    assert_equal 1, counting.calls,
      "a replay answers from the receipt and must not re-ask the model plane"
  end
  # C2-3 addendum: the envelope member frozen at checkpoint 1 is now ACTIVE. A nonblank key is
  # normalized, digested, create-or-verified, and frozen on the accepted InferenceRequest before any provider
  # work; absent still digests the explicit null.
  test "a nonblank billing subject is verified and frozen on the accepted one shot" do
    result = create(billing_subject: "  team-alpha  ")

    assert_predicate result, :created?
    inference_request = InferenceRequest.sole
    subject = BillingSubject.sole
    assert_equal "team-alpha", inference_request.billing_subject_key
    assert_equal subject.public_id, inference_request.billing_subject_public_id
    assert_equal @creator.id, subject.owning_user_id
  end

  test "an absent billing subject freezes nothing and creates no subject" do
    assert_predicate create, :created?

    assert_nil InferenceRequest.sole.billing_subject_key
    assert_equal 0, BillingSubject.count
  end

  # The key belongs to the digested command, so two spellings of one key are
  # ONE request and a different key is a different one.
  test "the billing subject rides the request digest" do
    key = SecureRandom.uuid
    first = create(idempotency_key: key, billing_subject: "team-alpha")
    replay = create(idempotency_key: key, billing_subject: "  team-alpha  ")

    assert_predicate first, :created?
    assert_equal :replayed, replay.outcome

    assert_equal :idempotency_mismatch,
      create(idempotency_key: key, billing_subject: "team-beta").outcome
  end

  test "a key owned by somebody else is refused stably and writes nothing" do
    BillingSubject.create!(account: @account, owning_user: users(:owner), key: "team-alpha")

    result = create(billing_subject: "team-alpha")

    assert_equal :refused, result.outcome
    assert_equal InferenceRequests::Create::BILLING_SUBJECT_NOT_OWNED, result.refusal
    assert_equal 0, InferenceRequest.count
    assert_equal 1, BillingSubject.count
  end
end
