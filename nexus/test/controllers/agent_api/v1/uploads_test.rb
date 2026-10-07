require "test_helper"

# THE PUBLIC BINARY-INGEST ENTRY POINT, at the boundary a caller actually
# meets. The command's own test owns detection and bounds; this one owns what
# only the HTTP surface can be wrong about — the plane it serves, the scope a
# read may see, and the status a refusal carries.
class AgentAPI::V1::UploadsTest < ActionDispatch::IntegrationTest
  def wav_bytes(rate: 8000)
    samples = "\x00\x00".b * rate
    "RIFF".b + [36 + samples.bytesize].pack("V") + "WAVE".b +
      "fmt ".b + [16, 1, 1, rate, rate * 2, 2, 16].pack("Vv v V V v v") +
      "data".b + [samples.bytesize].pack("V") + samples
  end

  def uploaded(bytes = wav_bytes, filename: "clip.mp3", content_type: "audio/mpeg")
    tempfile = Tempfile.new(["ingest", File.extname(filename)], binmode: true)
    tempfile.write(bytes)
    tempfile.rewind
    Rack::Test::UploadedFile.new(tempfile.path, content_type, original_filename: filename)
  end

  test "a member stages bytes and reads back what they turned out to be" do
    credential = create_access_token_fixture(user: users(:member), name: "M")

    post agent_api_v1_uploads_path,
      params: { upload: { file: uploaded } }, headers: bearer(credential.secret)

    assert_response :created
    body = response.parsed_body.fetch("upload")
    assert_equal "audio/wav", body.fetch("content_type"),
      "the caller declared audio/mpeg; the bytes are what the caller is told"
    assert_equal "clip.wav", body.fetch("filename")
    assert_operator body.fetch("byte_size"), :>, 0
    assert body.fetch("public_id").present?

    get agent_api_v1_upload_path(public_id: body.fetch("public_id")),
      headers: bearer(credential.secret)

    assert_response :success
    assert_equal body, response.parsed_body.fetch("upload")
  end

  # THE SCOPE IS THE ONE BINDING USES. `ContentUploads::ResolveReferences`
  # binds only the creator's own uploads, so a read that could see another
  # member's would be a boundary the bind path does not have.
  test "one member cannot read another's staged upload" do
    mine = create_access_token_fixture(user: users(:member), name: "M")
    theirs = create_access_token_fixture(user: users(:owner), name: "O")

    post agent_api_v1_uploads_path,
      params: { upload: { file: uploaded } }, headers: bearer(mine.secret)
    public_id = response.parsed_body.dig("upload", "public_id")

    get agent_api_v1_upload_path(public_id: public_id), headers: bearer(theirs.secret)

    assert_response :not_found
  end

  test "an unauthenticated caller stages nothing" do
    assert_no_difference "ContentUpload.count" do
      post agent_api_v1_uploads_path, params: { upload: { file: uploaded } }
    end

    assert_response :unauthorized
  end

  test "a parameter that is not a file is a request-shape refusal" do
    credential = create_access_token_fixture(user: users(:member), name: "M")

    assert_no_difference "ContentUpload.count" do
      post agent_api_v1_uploads_path,
        params: { upload: { file: "not a file" } }, headers: bearer(credential.secret)
    end

    # 400 is this family's frozen answer for a malformed parameter, not 422:
    # the caller sent something that is not a request, so nothing was judged.
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end

  # TWO WAYS TO SEND NOTHING, and they are not the same answer. The typed root
  # is required by `params.expect`, so a body without it never reaches the
  # controller's own file guard — the caller is told which half is missing
  # rather than being told their file was invalid when they sent no file at
  # all. The page documented only the second.
  def test_a_missing_root_and_a_missing_file_are_both_parameter_missing
    credential = create_access_token_fixture(user: users(:member), name: "M")

    post agent_api_v1_uploads_path, params: {}, headers: bearer(credential.secret)
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")

    post agent_api_v1_uploads_path, params: { upload: { nonesuch: 1 } },
      headers: bearer(credential.secret)
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end

  test "an oversize upload is refused with the status that names the reason" do
    credential = create_access_token_fixture(user: users(:member), name: "M")
    huge = Tempfile.new("huge", binmode: true)
    huge.truncate(Nexus::SizeBounds.fetch(:upload_bound) + 1)

    assert_no_difference ["ContentUpload.count", "ActiveStorage::Blob.count"] do
      post agent_api_v1_uploads_path,
        params: { upload: { file: Rack::Test::UploadedFile.new(huge.path, "application/octet-stream") } },
        headers: bearer(credential.secret)
    end

    assert_response :content_too_large
    assert_equal "content_too_large", response.parsed_body.dig("error", "code")
  end

  private

    def bearer(secret)
      { "Authorization" => "Bearer #{secret}" }
    end
end

# THE ONE BYTES READ: `GET /agent_api/v1/uploads/{id}/bytes`, streamed through
# `ActiveStorage::Streaming` — `Accept-Ranges` on a whole read, `206` and the slice under a `Range`
# header (THE chunked read, HTTP's own) — scoped by the upload's OWN rule: its creator, or a reader
# of a row that NAMES it, judged through that row's own funnel. Absent, foreign, fileless and
# unreadable answer 404 alike; an executor credential is not this plane's.
class AgentAPI::V1::UploadBytesTest < ActionDispatch::IntegrationTest
  include AgentMembershipTestHelper
  include RunAuthoringTestHelper

  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @member = create_access_token_fixture(user: users(:member), name: "M")
    @owner = create_access_token_fixture(user: users(:owner), name: "O")
    @curator = create_access_token_fixture(user: users(:curator), name: "C")
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

  def read_bytes(public_id, secret, range: nil)
    headers = bearer(secret)
    headers["Range"] = range if range
    get agent_api_v1_upload_bytes_path(upload_public_id: public_id), headers: headers
  end

  def staged(**creator)
    @account.content_uploads.create!(
      **creator,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PNG), filename: "diagram.png",
        content_type: "image/png")
    )
  end

  test "the creator streams a staged upload whole, and a Range answers the slice" do
    upload = staged(creating_user: users(:member))

    read_bytes(upload.public_id, @member.secret)
    assert_response :success
    assert_equal PNG.b, response.body.b
    assert_equal "image/png", response.media_type, "the detected type, never the part's"
    assert_equal "bytes", response.headers["Accept-Ranges"]
    assert_equal PNG.bytesize.to_s, response.headers["Content-Length"]
    assert_match(/attachment/, response.headers["Content-Disposition"])

    read_bytes(upload.public_id, @member.secret, range: "bytes=0-7")
    assert_response :partial_content
    assert_equal PNG.b[0, 8], response.body.b
    assert_equal "bytes 0-7/#{PNG.bytesize}", response.headers["Content-Range"]

    read_bytes(upload.public_id, @member.secret, range: "bytes=#{PNG.bytesize - 4}-")
    assert_response :partial_content
    assert_equal PNG.b[-4..], response.body.b, "the tail: the chunked read is HTTP's own"
  end

  test "absent, foreign, fileless and an executor's unnamed capture answer 404 alike; an executor credential 401" do
    mine = staged(creating_user: users(:member))
    read_bytes(mine.public_id, @owner.secret)
    assert_response :not_found, "another member's staged row is absence"

    read_bytes(SecureRandom.uuid_v7, @member.secret)
    assert_response :not_found

    fileless = @account.content_uploads.create!(creating_user: users(:member))
    read_bytes(fileless.public_id, @member.secret)
    assert_response :not_found

    capture = staged(creating_executor: suite_runner)
    read_bytes(capture.public_id, @owner.secret)
    assert_response :not_found, "uploaded, never committed: the creator has no member read and nothing names it"

    read_bytes(mine.public_id, suite_runner_connection.executor_access_secret)
    assert_response :unauthorized, "the executor plane's credential is not this plane's"
  end

  # THE SAME READ serves a conversation's attachment to that conversation's
  # reader through the funnel, and 404s the member the ACL narrows to
  # `none` — the ledger's "no byte route back out" closes here.
  test "a conversation attachment is served to the conversation's reader and concealed from none" do
    poster = users(:owner)
    conversation = Conversation.create!(workspace: @workspace, creating_user: poster, access_default: "none")
    conversation.conversation_access_entries.create!(user: users(:curator), level: "read")
    picture = staged(creating_user: poster)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: conversation, acting_user: poster, kind: "message", role: "user",
      entries: [{ "text" => "look" }], attachments: [picture.public_id],
      visible_in_context: true, delivery_mode: "queue",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil
    ))
    assert_predicate result, :accepted?, result.inspect

    read_bytes(picture.public_id, @curator.secret)
    assert_response :success, "a `read` entry reads the attachment of a row it can read"
    assert_equal PNG.b, response.body.b

    read_bytes(picture.public_id, @member.secret)
    assert_response :not_found, "`none` conceals the row and, with it, its attachment"
  end

  # A tool result's CAPTURE, named by the commit and bound by the body:
  # the loop's reader fetches it; a stranger to the workspace meets 404.
  test "a result's capture is served to the loop's reader once its commit names it" do
    curator = users(:curator)
    capture = staged(creating_executor: suite_runner)
    agent_run = seed(tool("alpha", "read_file", "input" => { "path" => "x" }),
      workspace: workspaces(:personal), creating_user: curator)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: curator))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: "alpha", executor: suite_runner
    ))
    assert_predicate claimed, :accepted?
    committed = Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: agent_run, task_key: "alpha", executor: suite_runner, claim_token: claimed.value.claim_token,
      content: [{ "type" => "text", "text" => "saved" },
                { "type" => "resource_link", "uri" => "nexus://uploads/#{capture.public_id}", "name" => "shot.png" }],
      structured_content: nil, result_type: nil, outcome: "completed", is_error: false, title: nil, metadata: nil
    ))
    assert_predicate committed, :applied?

    read_bytes(capture.public_id, @curator.secret)
    assert_response :success
    assert_equal PNG.b, response.body.b
    assert_equal "image/png", response.media_type

    read_bytes(capture.public_id, @member.secret)
    assert_response :not_found, "a stranger to the private workspace"
  end
end
