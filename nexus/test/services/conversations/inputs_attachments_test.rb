require "test_helper"

# THE DOOR: a person's message carries pictures beside its words as ONE parts entry, bound for
# liveness and pinned under the host lock; a picture alone is a message; a steer takes none; a
# ordinary files bind beside images; raw entries bind what they placed; PATCH keeps the
# binding unless told otherwise. Both hosts, the same rules.
class Conversations::InputsAttachmentsTest < ActiveSupport::TestCase
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  def upload(filename = "diagram.png", content_type: "image/png", creating_user: @user)
    @account.content_uploads.create!(
      creating_user: creating_user,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(PNG), filename: filename, content_type: content_type, identify: false
      )
    )
  end

  def command(**overrides)
    Conversations::Inputs::Create::Command.new(**{
      host: @conversation, acting_user: @user, kind: "message",
      role: "user", entries: [{ "text" => "look" }], visible_in_context: true,
      delivery_mode: "queue", context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides))
  end

  def create!(**overrides) = Conversations::Inputs::Create.call(command(**overrides))

  def update!(input, host: @conversation, **overrides)
    Conversations::Inputs::Update.call(Conversations::Inputs::Update::Command.new(**{
      host: host, input_public_id: input.public_id,
      acting_user: @user, expected_lock_version: nil, entries: nil,
      visible_in_context: nil, context_mode: nil, context_options: nil, provider_id: nil,
      model_ref: nil, reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
  end

  def payloads(body) = body.content_body_entries.map { |entry| entry.content_fragment.payload }

  test "text and attachments compose one parts entry, bound and projected as the words" do
    one = upload("one.png")
    two = upload("two.png")

    result = create!(attachments: [two.public_id, one.public_id])

    assert_predicate result, :accepted?, result.outcome.to_s
    body = result.value.content_body
    assert_equal [{
      "role" => "user",
      "parts" => [
        { "type" => "text", "text" => "look" },
        { "type" => "upload", "upload_public_id" => two.public_id },
        { "type" => "upload", "upload_public_id" => one.public_id },
      ],
    }], payloads(body), "words then pictures, in the order given"
    assert_equal [two, one].map(&:id), body.upload_parts.map(&:id)
    assert_equal "look", body.readable_text
    assert_equal "look", result.value.text
    assert_equal [two, one].map(&:id).sort, body.content_uploads.map(&:id).sort, "bound: the reaper cannot reach them"
  end

  test "a picture with no words is a message with no words" do
    alone = upload("alone.png")

    result = create!(entries: [], attachments: [alone.public_id])

    assert_predicate result, :accepted?, result.outcome.to_s
    body = result.value.content_body
    assert_equal [{ "role" => "user", "parts" => [{ "type" => "upload", "upload_public_id" => alone.public_id }] }],
      payloads(body)
    assert_equal "", body.readable_text
    assert_equal "", result.value.text, "never the canonical JSON"
    assert_equal [{ public_id: alone.public_id, filename: "alone.png", content_type: "image/png", byte_size: 70 }],
      AgentAPI::ConversationPresenter.input(result.value).fetch(:attachments)
  end

  test "an unknown id, another creator's id and a malformed one refuse as one, leaving no row" do
    stranger = upload("theirs.png", creating_user: users(:curator))

    [SecureRandom.uuid_v7, stranger.public_id, nil].each do |id|
      result = create!(attachments: [upload.public_id, id])
      assert_equal :unknown_input_upload, result.outcome, id.inspect
    end
    assert_equal 0, ConversationInput.count
    assert_equal 0, ContentBody.count
    assert_equal 0, ContentBodyUpload.count
  end

  test "a steer takes no attachments and ordinary files are accepted by the queued input door" do
    steered = create!(delivery_mode: "steer", attachments: [upload.public_id])
    assert_equal :attachments_not_steerable, steered.outcome

    pdf = upload("paper.pdf", content_type: "application/pdf")
    accepted = create!(attachments: [pdf.public_id])
    assert_predicate accepted, :accepted?
    assert_equal [pdf.id], accepted.value.content_body.content_uploads.pluck(:id)

    raw_steer = create!(delivery_mode: "steer", entries: [{
      "role" => "user", "parts" => [{ "type" => "upload", "upload_public_id" => upload.public_id }],
    }])
    assert_equal :attachments_not_steerable, raw_steer.outcome, "a raw steer placing a picture is the same refusal"
    assert_equal 1, ConversationInput.count
  end

  test "attachments never ride beside raw entries; raw entries bind what they placed" do
    picture = upload("raw.png")
    parts = [{ "role" => "user", "parts" => [
      { "type" => "text", "text" => "verbatim" },
      { "type" => "upload", "upload_public_id" => picture.public_id },
    ] }]

    assert_equal :attachments_with_entries, create!(entries: parts, attachments: [picture.public_id]).outcome

    raw = create!(entries: parts)
    assert_predicate raw, :accepted?, raw.outcome.to_s
    body = raw.value.content_body
    assert_equal parts, payloads(body), "the entries stand as written"
    assert_equal [picture.id], body.content_uploads.map(&:id), "bound: no reaper past ORPHAN_GRACE"
    assert_nil body.readable_text, "raw is never enriched: no projection"

    foreign = upload("theirs.png", creating_user: users(:curator))
    stolen = create!(entries: [{ "role" => "user", "parts" => [
      { "type" => "upload", "upload_public_id" => foreign.public_id },
    ] }])
    assert_equal :unknown_input_upload, stolen.outcome
  end

  # PATCH KEEPS THE BINDING (must-fix #3): the fix path for a blocked head
  # carries new words and no `attachments`; the picture must survive it.
  test "PATCH with text keeps the pictures; [] unbinds; a list rebinds; attachments alone keep the words" do
    one = upload("one.png")
    two = upload("two.png")
    input = create!(attachments: [one.public_id]).value

    kept = update!(input, entries: [{ "text" => "better words" }])
    assert_predicate kept, :accepted?, kept.outcome.to_s
    body = input.reload.content_body
    assert_equal "better words", body.readable_text
    assert_equal [one.id], body.upload_parts.map(&:id), "absent attachments keeps the binding"
    assert_equal "better words", payloads(body).sole.dig("parts", 0, "text")

    rebound = update!(input, attachments: [two.public_id])
    assert_predicate rebound, :accepted?, rebound.outcome.to_s
    body = input.reload.content_body
    assert_equal "better words", body.readable_text, "attachments alone keep the words"
    assert_equal [two.id], body.upload_parts.map(&:id)
    assert_equal [two.id], body.content_uploads.map(&:id)

    unbound = update!(input, attachments: [])
    assert_predicate unbound, :accepted?
    body = input.reload.content_body
    assert_equal [{ "text" => "better words" }], payloads(body), "no pictures: the plain text shape, today's bytes"
    assert_empty body.content_uploads
    assert_equal "better words", body.readable_text

    raw_flip = update!(input, entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "raw" }] }],
      attachments: [one.public_id])
    assert_equal :attachments_with_entries, raw_flip.outcome
  end

  test "the loop host admits attachments on its door and refuses them on a steer like the conversation's" do
    agent_loop = AgentLoop.create!(workspace: @workspace, creating_user: @user, approval_mode: "bypass",
      status: "running")
    picture = upload("loop.png")

    result = create!(host: agent_loop, visible_in_context: nil, attachments: [picture.public_id])
    assert_predicate result, :accepted?, result.outcome.to_s
    assert_equal [picture.id], result.value.content_body.upload_parts.map(&:id)

    steered = create!(host: agent_loop, visible_in_context: nil, delivery_mode: "steer",
      attachments: [picture.public_id])
    assert_equal :attachments_not_steerable, steered.outcome
  end

  test "a full participant can edit another author's words while keeping its bound pictures" do
    picture = upload("original.png")
    input = create!(attachments: [picture.public_id]).value
    editor = users(:curator)
    assert @conversation.writable_by?(editor)
    assert picture.readable_by?(editor)

    kept = update!(input, acting_user: editor, entries: [{ "text" => "corrected words" }])
    assert_predicate kept, :accepted?, kept.outcome.to_s
    body = input.reload.content_body
    assert_equal "corrected words", body.readable_text
    assert_equal [picture.id], body.upload_parts.map(&:id)
    assert_equal @user, input.authoring_user

    refused = update!(input, acting_user: editor, attachments: [picture.public_id])
    assert_equal :unknown_input_upload, refused.outcome, "explicit references still belong to the editor"
    assert_equal [picture.id], input.reload.content_body.upload_parts.map(&:id)

    replacement = upload("replacement.png", creating_user: editor)
    rebound = update!(input, acting_user: editor, attachments: [replacement.public_id])
    assert_predicate rebound, :accepted?, rebound.outcome.to_s
    assert_equal [replacement.id], input.reload.content_body.upload_parts.map(&:id)
  end

  # THE BIND'S LOCK: the resolved rows are pinned `FOR KEY SHARE` inside the door's transaction, so
  # the orphan reaper cannot destroy one between the read and the join — the fragment writer's own
  # primitive, on the upload rows alone.
  test "the door pins the resolved uploads FOR KEY SHARE before it binds them" do
    picture = upload("pinned.png")
    statements = []
    subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
      statements << payload[:sql].to_s unless payload[:cached] || payload[:name] == "SCHEMA"
    end

    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      create!(attachments: [picture.public_id])
    end

    assert_predicate result, :accepted?
    pinned = statements.grep(/FROM "content_uploads"/).grep(/FOR KEY SHARE OF content_uploads\z/)
    assert_equal 1, pinned.length, "one locked read of the rows about to be bound"
    bind = statements.index { |sql| sql.start_with?('INSERT INTO "content_body_uploads"') }
    assert_operator statements.index(pinned.sole), :<, bind, "pinned before the join is written"
  end
end
