require "test_helper"

# POST /agent_api/v1/executor/uploads — the executor plane's door into the ONE ingest: the third
# door behind `UploadIngest`, differing from the member and session doors in the plane and the
# creator alone. What only this surface can be wrong about is pinned: the creator is THIS EXECUTOR
# (`creating_executor` set, `creating_user` null), the plane refuses a member credential, the size
# bound and the parameter refusal speak the shared door's statuses, and nothing on this plane reads
# a capture back.
class AgentAPI::V1::Executors::UploadsTest < ActionDispatch::IntegrationTest
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  def uploaded(bytes = PNG, filename: "shot.png", content_type: "application/octet-stream")
    tempfile = Tempfile.new(["capture", File.extname(filename)], binmode: true)
    tempfile.write(bytes)
    tempfile.rewind
    Rack::Test::UploadedFile.new(tempfile.path, content_type, original_filename: filename)
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

  def runner_bearer = bearer(suite_runner_connection.executor_access_secret)

  test "an executor stages a capture as its own creator and reads the shared descriptor" do
    assert_difference "ContentUpload.count", 1 do
      post agent_api_v1_executor_uploads_path, params: { upload: { file: uploaded } }, headers: runner_bearer
    end

    assert_response :created
    body = response.parsed_body.fetch("upload")
    assert_equal "image/png", body.fetch("content_type"), "the bytes decide, not the part's declared type"
    assert_equal "shot.png", body.fetch("filename")
    assert_equal PNG.bytesize, body.fetch("byte_size")
    assert_equal %w[byte_size content_type created_at filename public_id], body.keys.sort,
      "the member door's descriptor, byte for byte"
    upload = ContentUpload.find_by!(public_id: body.fetch("public_id"))
    assert_equal suite_runner, upload.creating_executor
    assert_nil upload.creating_user_id, "exactly one creator: the executor, never a member"
    assert_equal suite_runner.account, upload.account
  end

  test "nothing on this plane reads a capture back, and a member credential is not this plane's" do
    post agent_api_v1_executor_uploads_path, params: { upload: { file: uploaded } }, headers: runner_bearer
    public_id = response.parsed_body.dig("upload", "public_id")

    get "/agent_api/v1/executor/uploads/#{public_id}", headers: runner_bearer
    assert_response :not_found, "no `show` on the executor plane"

    member = create_access_token_fixture(user: users(:member), name: "M")
    assert_no_difference "ContentUpload.count" do
      post agent_api_v1_executor_uploads_path, params: { upload: { file: uploaded } }, headers: bearer(member.secret)
    end
    assert_response :unauthorized
  end

  test "the shared door's refusals: over the bound is 413, a non-file is 400" do
    huge = Tempfile.new("huge", binmode: true)
    huge.truncate(Nexus::SizeBounds.fetch(:upload_bound) + 1)
    assert_no_difference ["ContentUpload.count", "ActiveStorage::Blob.count"] do
      post agent_api_v1_executor_uploads_path,
        params: { upload: { file: Rack::Test::UploadedFile.new(huge.path, "application/octet-stream") } },
        headers: runner_bearer
    end
    assert_response :content_too_large
    assert_equal "content_too_large", response.parsed_body.dig("error", "code")

    assert_no_difference "ContentUpload.count" do
      post agent_api_v1_executor_uploads_path, params: { upload: { file: "not a file" } }, headers: runner_bearer
    end
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end
end
