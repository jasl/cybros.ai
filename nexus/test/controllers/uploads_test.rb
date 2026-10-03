require "test_helper"

# THE SESSION DOOR FOR BYTES: the signed-in Human's browser posts multipart to `POST /uploads` and
# reads back the same descriptor the member plane's `POST /agent_api/v1/uploads` answers. ONE ingest
# (`ContentUploads::Create`, the bytes decide the type) behind two authenticated doors — never the
# framework's anonymous direct-upload endpoints, which `draw_routes = false` keeps undrawn. What
# only this surface can be wrong about is pinned here: the plane (a cookie session, not a bearer),
# the creator the upload is staged under, and the statuses.
class UploadsTest < ActionDispatch::IntegrationTest
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  def uploaded(bytes = PNG, filename: "diagram.png", content_type: "application/octet-stream")
    tempfile = Tempfile.new(["session-ingest", File.extname(filename)], binmode: true)
    tempfile.write(bytes)
    tempfile.rewind
    Rack::Test::UploadedFile.new(tempfile.path, content_type, original_filename: filename)
  end

  test "a signed-in member stages bytes under their own creator id and reads the descriptor" do
    sign_in_as users(:member)

    assert_difference "ContentUpload.count", 1 do
      post uploads_path, params: { upload: { file: uploaded } }
    end

    assert_response :created
    body = response.parsed_body.fetch("upload")
    assert_equal "image/png", body.fetch("content_type"), "the bytes decide, not the part's declared type"
    assert_equal "diagram.png", body.fetch("filename")
    assert_equal PNG.bytesize, body.fetch("byte_size")
    upload = ContentUpload.find_by!(public_id: body.fetch("public_id"))
    assert_equal users(:member), upload.creating_user,
      "staged as the session's user: a later input of theirs resolves it creator-scoped"
    assert_equal accounts(:cybros), upload.account
    assert_equal %w[byte_size content_type created_at filename public_id], body.keys.sort,
      "the member door's descriptor, byte for byte"
  end

  test "no session stages nothing and is sent to sign in" do
    assert_no_difference ["ContentUpload.count", "ActiveStorage::Blob.count"] do
      post uploads_path, params: { upload: { file: uploaded } }
    end

    assert_redirected_to new_session_path
  end

  test "a part that is not a file is a 400 with the JSON envelope" do
    sign_in_as users(:member)

    assert_no_difference "ContentUpload.count" do
      post uploads_path, params: { upload: { file: "not bytes" } }
    end

    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")

    post uploads_path, params: { upload: {} }
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end

  test "an oversize upload is refused with the status that names the reason" do
    sign_in_as users(:member)
    huge = Tempfile.new("huge", binmode: true)
    huge.truncate(Nexus::SizeBounds.fetch(:upload_bound) + 1)

    assert_no_difference ["ContentUpload.count", "ActiveStorage::Blob.count"] do
      post uploads_path, params: { upload: { file: Rack::Test::UploadedFile.new(huge.path, "application/octet-stream") } }
    end

    assert_response :content_too_large
    assert_equal "content_too_large", response.parsed_body.dig("error", "code")
  end
end
